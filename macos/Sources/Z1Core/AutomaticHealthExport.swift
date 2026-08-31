import Foundation

/// A walk the tracker has finished with, handed to the app's own history.
public struct CompletedWalk: Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let activeDurationS: Int
    public let distanceM: Int
    public let steps: Int
    /// Kept for Codable compatibility of WalkSession; always false.
    public let offeredToHealth: Bool

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        activeDurationS: Int,
        distanceM: Int,
        steps: Int,
        offeredToHealth: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationS = activeDurationS
        self.distanceM = distanceM
        self.steps = steps
        self.offeredToHealth = offeredToHealth
    }

    public var avgSpeedKmh: Double {
        guard activeDurationS > 0 else { return 0 }
        return Double(distanceM) / Double(activeDurationS) * 3.6
    }
}

/// Turns belt telemetry into one pause-aware workout. A physical-remote Stop
/// starts a ten-minute grace period; movement within that grace resumes the
/// same workout instead of creating another one.
public struct RemoteSessionTracker: Codable, Sendable {
    public static let stopGraceSeconds: TimeInterval = 10 * 60

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

        init(_ status: Z1Treadmill.Status) {
            elapsedS = max(0, status.elapsedS)
            distanceM = max(0, status.distanceM)
            steps = max(0, status.steps)
        }

        init(elapsedS: Int, distanceM: Int, steps: Int) {
            self.elapsedS = elapsedS
            self.distanceM = distanceM
            self.steps = steps
        }
    }

    private struct Session: Codable, Sendable {
        var id: String
        var startedAt: Date
        var activeDurationS: Int
        var distanceM: Int
        var steps: Int
        var lastCounters: Counters
        var wasRunning: Bool
        var stoppedAt: Date?
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
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decodeIfPresent(Session.self, forKey: .session)
        idleCounters = try values.decodeIfPresent(Counters.self, forKey: .idleCounters)
        pendingLogs = try values.decodeIfPresent([Session].self, forKey: .pendingLogs) ?? []
    }

    public var finalizationDeadline: Date? {
        session?.stoppedAt?.addingTimeInterval(Self.stopGraceSeconds)
    }

    public var hasPendingLogs: Bool { !pendingLogs.isEmpty }

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

        let counters = Counters(status)
        let running = status.beltRunning && status.speedKmh > 0
        if var current = session {
            let includeDeltas = current.wasRunning || running
            // A pad session reset drops elapsed (Stop + Start). A 1–3 step
            // dip is the UI interpolator snapping back to the packet total —
            // treating that as a reset added the whole counter onto Today.
            let padReset = running && counters.elapsedS < current.lastCounters.elapsedS
            if includeDeltas {
                current.activeDurationS += Self.counterDelta(
                    previous: current.lastCounters.elapsedS,
                    current: counters.elapsedS,
                    allowReset: padReset
                )
                current.distanceM += Self.counterDelta(
                    previous: current.lastCounters.distanceM,
                    current: counters.distanceM,
                    allowReset: padReset
                )
                current.steps += Self.counterDelta(
                    previous: current.lastCounters.steps,
                    current: counters.steps,
                    allowReset: padReset
                )
                // Interpolator can sit 1–3 steps ahead of the packet. When
                // the display snaps back, drop those ticks instead of
                // treating the dip as a new pad session.
                if !padReset,
                   counters.steps < current.lastCounters.steps,
                   current.lastCounters.steps - counters.steps <= 5
                {
                    current.steps = max(0, current.steps - (current.lastCounters.steps - counters.steps))
                }
            }
            // Heal a tracker that already swallowed interpolation snaps:
            // live pad steps cannot be a fraction of the accumulated total
            // while distance is still this same walk.
            if counters.steps > 0,
               current.steps > counters.steps * 2 + 20,
               current.distanceM <= counters.distanceM + 20
            {
                current.steps = counters.steps
            }
            current.lastCounters = counters
            if running {
                current.wasRunning = true
                current.stoppedAt = nil
            } else {
                if current.wasRunning { current.stoppedAt = now }
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
                lastCounters: counters,
                wasRunning: true,
                stoppedAt: nil
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

    /// Called by the menu app's deadline task and again on launch. Repeated
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
        CompletedWalk(
            id: current.id,
            startedAt: current.startedAt,
            endedAt: current.stoppedAt ?? current.startedAt,
            activeDurationS: current.activeDurationS,
            distanceM: current.distanceM,
            steps: current.steps,
            offeredToHealth: false
        )
    }

    private static func counterDelta(previous: Int, current: Int, allowReset: Bool) -> Int {
        if current >= previous { return current - previous }
        return allowReset ? current : 0
    }

    private static func seedCounters(current: Counters, idle: Counters?) -> Counters {
        guard let idle else { return current }
        return Counters(
            elapsedS: counterDelta(previous: idle.elapsedS, current: current.elapsedS, allowReset: true),
            distanceM: counterDelta(previous: idle.distanceM, current: current.distanceM, allowReset: true),
            steps: counterDelta(previous: idle.steps, current: current.steps, allowReset: true)
        )
    }
}
