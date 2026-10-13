import Foundation

/// A walk the tracker has finished with, handed to the app's own history.
public struct CompletedWalk: Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let activeDurationS: Int
    public let distanceM: Int
    public let steps: Int
    public let rawPadSteps: Int?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        activeDurationS: Int,
        distanceM: Int,
        steps: Int,
        rawPadSteps: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationS = activeDurationS
        self.distanceM = distanceM
        self.steps = steps
        self.rawPadSteps = rawPadSteps
    }

    public var avgSpeedKmh: Double {
        guard activeDurationS > 0 else { return 0 }
        return Double(distanceM) / Double(activeDurationS) * 3.6
    }
}

/// Turns belt telemetry into individual belt-run segments. A brief pause or
/// connection drop can resume the same segment; a longer gap starts a new ID.
public struct RemoteSessionTracker: Codable, Sendable {
    public static let stopGraceSeconds: TimeInterval = 2 * 60

    public struct Observation: Sendable {
        /// Finished walks awaiting a history entry (all of them, short ones
        /// included) — drain with `acknowledgeLog(sessionID:)`.
        public let completed: [CompletedWalk]
        public let finalizationDeadline: Date?
    }

    /// Walks below this are treated as noise (a nudge of the belt, a test
    /// press) and never reach the history.
    public static let minLoggedDurationS = 60
    public static let minLoggedDistanceM = 20

    private struct Counters: Codable, Sendable {
        var elapsedS: Int
        var distanceM: Int
        var steps: Int
        var padSteps: Int?

        init(_ status: Z1Treadmill.Status) {
            elapsedS = max(0, status.elapsedS)
            distanceM = max(0, status.distanceM)
            steps = max(0, status.steps)
            padSteps = status.padSteps.map { max(0, $0) }
        }

        init(elapsedS: Int, distanceM: Int, steps: Int, padSteps: Int? = nil) {
            self.elapsedS = elapsedS
            self.distanceM = distanceM
            self.steps = steps
            self.padSteps = padSteps
        }
    }

    private struct Session: Codable, Sendable {
        var id: String
        var startedAt: Date
        var activeDurationS: Int
        var distanceM: Int
        var steps: Int
        var rawPadSteps: Int?
        var lastCounters: Counters
        var wasRunning: Bool
        var stoppedAt: Date?
        /// Persisted recovery timestamp; older records decode this as nil.
        var lastObservedAt: Date?
        /// Steps from earlier counter runs, minus any idle baseline. Optional
        /// so saved state from older builds still decodes without migration.
        var modelledStepOffset: Int?
    }

    private var session: Session?
    private var idleCounters: Counters?
    private var pendingLogs: [Session] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case session, idleCounters, pendingLogs
    }

    /// Hand-written so that state saved by an older build — which had no
    /// `pendingLogs` — still decodes instead of resetting the tracker and
    /// dropping a walk that is mid-flight.
    ///
    /// A tracker is only ever decoded by a new process, and that process has
    /// no link to the pad yet. A walk that was still "running" when the old
    /// process died or quit (a crash, an update, Quit mid-walk, "Stop pad and
    /// quit" before the pad's Stop reached the tracker) is therefore treated
    /// as dropped at the last moment it was seen. Left open, nothing would
    /// ever close it while the pad stays idle, it would sit in "Today" and the
    /// Health queue's hold-back for good, and the next walk — possibly days
    /// later — would be folded into it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decodeIfPresent(Session.self, forKey: .session)
        idleCounters = try values.decodeIfPresent(Counters.self, forKey: .idleCounters)
        pendingLogs = try values.decodeIfPresent([Session].self, forKey: .pendingLogs) ?? []
        if session?.stoppedAt == nil {
            markConnectionDrop(at: .distantFuture)
        }
    }

    public var finalizationDeadline: Date? {
        session?.stoppedAt?.addingTimeInterval(Self.stopGraceSeconds)
    }

    public var hasPendingLogs: Bool { !pendingLogs.isEmpty }

    /// Finished walks retained until their history save succeeds. Reading this
    /// never finalizes or acknowledges a session.
    public var pendingCompletedWalks: [CompletedWalk] { pendingCompleted }

    /// Totals of the walk currently being tracked (running or inside its
    /// stop-grace window), nil when no walk is open. This — not the pad's
    /// live counters — is what "Today" should add to the stored history:
    /// it is persisted every tick, so it survives an app kill, and it does
    /// not dip to zero while a walk is paused.
    public var openWalkTotals: CompletedWalk? {
        guard let session else { return nil }
        return Self.completedWalk(from: session)
    }

    /// Observe a decoded telemetry snapshot. Non-telemetry connection updates
    /// are ignored so a Bluetooth drop cannot be mistaken for a remote Stop.
    public mutating func observe(
        _ status: Z1Treadmill.Status,
        at now: Date = Date(),
        newSessionID: () -> String = { UUID().uuidString.lowercased() }
    ) -> Observation {
        finalizeDueSession(at: now)

        guard status.hasTelemetry else {
            return Observation(
                completed: pendingCompleted,
                finalizationDeadline: finalizationDeadline
            )
        }

        var counters = Counters(status)
        // Speed still on the belt means the walk is not over, even if FTMS
        // dropped `beltRunning` for a packet. Disconnect is handled separately.
        let running = status.speedKmh > 0.3 || status.beltRunning
        if var current = session {
            // Stop packets can clear registers before a final counter packet
            // arrives. Retain the stopped run's high-water counters so that
            // a later stale snapshot cannot credit the same walk twice.
            if !running, counters.elapsedS < current.lastCounters.elapsedS
                || counters.distanceM < current.lastCounters.distanceM {
                counters.elapsedS = max(counters.elapsedS, current.lastCounters.elapsedS)
                counters.distanceM = max(counters.distanceM, current.lastCounters.distanceM)
                counters.steps = max(counters.steps, current.lastCounters.steps)
                if let prior = current.lastCounters.padSteps, let latest = counters.padSteps {
                    counters.padSteps = max(prior, latest)
                }
            }
            // A pad session reset drops elapsed (Stop + Start). A 1–3 step
            // dip is the UI interpolator snapping back to the packet total —
            // treating that as a reset added the whole counter onto Today.
            let padReset = running && counters.elapsedS < current.lastCounters.elapsedS
            let elapsedDelta = Self.counterDelta(
                previous: current.lastCounters.elapsedS,
                current: counters.elapsedS,
                allowReset: padReset
            )
            current.activeDurationS += elapsedDelta
            current.distanceM += padReset ? counters.distanceM : Self.counterDelta(
                previous: current.lastCounters.distanceM,
                current: counters.distanceM,
                allowReset: padReset
            )
            // Track the offset explicitly. Inferring a continuous run
            // from nearby distance totals loses steps after short runs,
            // and accumulating only positive deltas inflates estimates
            // when a speed change recalculates the current run's stride.
            let stepOffset = padReset ? current.steps : (current.modelledStepOffset
                ?? current.steps - current.lastCounters.steps)
            current.modelledStepOffset = stepOffset
            current.steps = max(0, stepOffset + counters.steps)
            if let prior = current.lastCounters.padSteps,
               let latest = counters.padSteps,
               let accumulated = current.rawPadSteps
            {
                // The raw register sometimes survives a belt restart. If it
                // did not fall with elapsed, we cannot establish which run
                // it belongs to; use the model rather than double-count it.
                if padReset, latest >= prior {
                    current.rawPadSteps = nil
                } else {
                    current.rawPadSteps = accumulated + Self.counterDelta(
                        previous: prior,
                        current: latest,
                        allowReset: padReset
                    )
                }
            } else {
                current.rawPadSteps = nil
            }
            current.lastCounters = counters
            current.lastObservedAt = now
            if running {
                current.wasRunning = true
                current.stoppedAt = nil
            } else {
                // A stopped reconnect may contain real progress made while
                // offline. Credit it and move the end to this final sample;
                // duplicate idle packets still never extend the grace period.
                if current.wasRunning || elapsedDelta > 0 { current.stoppedAt = now }
                current.wasRunning = false
            }
            session = current
        } else if running {
            let seed = Self.seedCounters(current: counters, idle: idleCounters)
            session = Session(
                id: newSessionID(),
                startedAt: now.addingTimeInterval(-Double(seed.elapsedS)),
                activeDurationS: seed.elapsedS,
                distanceM: seed.distanceM,
                steps: seed.steps,
                rawPadSteps: seed.padSteps,
                lastCounters: counters,
                wasRunning: true,
                stoppedAt: nil,
                lastObservedAt: now,
                modelledStepOffset: seed.steps - counters.steps
            )
            idleCounters = nil
        } else {
            idleCounters = counters
        }

        return Observation(
            completed: pendingCompleted,
            finalizationDeadline: finalizationDeadline
        )
    }

    /// A lost link might hide a Stop. Close at the last known moving time if
    /// telemetry has not resumed within the short segment grace period.
    public mutating func markConnectionDrop(at now: Date = Date()) {
        guard session != nil else { return }
        if let current = session, current.stoppedAt == nil {
            // An app reopening must not move yesterday's last activity to now.
            let lastSeen = current.lastObservedAt
                ?? current.startedAt.addingTimeInterval(Double(current.activeDurationS))
            session?.stoppedAt = min(now, lastSeen)
        }
        session?.wasRunning = false
    }

    /// Called by the app's deadline task and again on launch. Repeated
    /// calls are idempotent because a finalized session is removed here.
    public mutating func finalizeIfDue(at now: Date = Date()) -> Observation {
        finalizeDueSession(at: now)
        return Observation(
            completed: pendingCompleted,
            finalizationDeadline: finalizationDeadline
        )
    }

    /// Remove a walk only once it is safely in the history file.
    public mutating func acknowledgeLog(sessionID: String) {
        pendingLogs.removeAll { $0.id == sessionID }
    }

    private var pendingCompleted: [CompletedWalk] {
        pendingLogs.map(Self.completedWalk(from:))
    }

    private mutating func finalizeDueSession(at now: Date) {
        guard let current = session,
              let endedAt = current.stoppedAt,
              now >= endedAt.addingTimeInterval(Self.stopGraceSeconds)
        else { return }

        session = nil
        idleCounters = current.lastCounters
        if current.activeDurationS >= Self.minLoggedDurationS,
           current.distanceM >= Self.minLoggedDistanceM
        {
            pendingLogs.append(current)
        }
    }

    private static func completedWalk(from current: Session) -> CompletedWalk {
        // The pad's own step register is only trusted when it agrees with the
        // belt: a register that did not reset with the walk (or one that
        // wrapped) turns up as an absurd stride and is left out in favour of
        // the modelled count.
        let raw = plausibleRawSteps(current.rawPadSteps, distanceM: current.distanceM)
        return CompletedWalk(
            id: current.id,
            startedAt: current.startedAt,
            endedAt: current.stoppedAt ?? current.lastObservedAt
                ?? current.startedAt.addingTimeInterval(Double(current.activeDurationS)),
            activeDurationS: current.activeDurationS,
            distanceM: current.distanceM,
            steps: raw ?? current.steps,
            rawPadSteps: raw
        )
    }

    /// Stride bounds for a believable pad step count, in metres per step.
    static let plausibleStrideM: ClosedRange<Double> = 0.30...1.50

    static func plausibleRawSteps(_ raw: Int?, distanceM: Int) -> Int? {
        guard let raw else { return nil }
        // Too short a walk to judge a stride from.
        guard distanceM >= 20 else { return raw }
        guard raw > 0, plausibleStrideM.contains(Double(distanceM) / Double(raw)) else { return nil }
        return raw
    }

    private static func counterDelta(previous: Int, current: Int, allowReset: Bool) -> Int {
        if current >= previous { return current - previous }
        return allowReset ? current : 0
    }

    private static func seedCounters(current: Counters, idle: Counters?) -> Counters {
        guard let idle else { return current }
        // Elapsed identifies a new counter run even when its first distance
        // packet already equals or exceeds the previous short run's distance.
        if current.elapsedS < idle.elapsedS { return current }
        return Counters(
            elapsedS: counterDelta(previous: idle.elapsedS, current: current.elapsedS, allowReset: true),
            distanceM: counterDelta(previous: idle.distanceM, current: current.distanceM, allowReset: true),
            steps: counterDelta(previous: idle.steps, current: current.steps, allowReset: true),
            padSteps: {
                guard let previous = idle.padSteps, let latest = current.padSteps else { return nil }
                return counterDelta(previous: previous, current: latest, allowReset: true)
            }()
        )
    }
}
