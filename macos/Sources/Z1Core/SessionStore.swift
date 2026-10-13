import Foundation

/// One completed walk, as recorded by the app.
///
/// Every finished walk that meets the local duration/distance floor lands
/// here so "Today" reflects what you actually walked.
public struct WalkSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    /// Seconds the belt was actually moving (excludes pauses inside the walk).
    public let activeDurationS: Int
    public let distanceM: Int
    public let steps: Int
    public let caloriesKcal: Double
    /// True only for workouts already exported by the older Health path.
    public let exportedToHealth: Bool
    /// Raw pad counter when available. Legacy records have no verified raw count.
    public let rawPadSteps: Int?
    /// Model provenance for estimated counts; `legacy` marks imported history.
    public let stepModelVersion: String?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        activeDurationS: Int,
        distanceM: Int,
        steps: Int,
        caloriesKcal: Double,
        exportedToHealth: Bool,
        rawPadSteps: Int? = nil,
        stepModelVersion: String? = "gait-v1"
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationS = activeDurationS
        self.distanceM = distanceM
        self.steps = steps
        self.caloriesKcal = caloriesKcal
        self.exportedToHealth = exportedToHealth
        self.rawPadSteps = rawPadSteps
        self.stepModelVersion = rawPadSteps == nil ? stepModelVersion : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, activeDurationS, distanceM, steps
        case caloriesKcal, exportedToHealth, rawPadSteps, stepModelVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decode(Date.self, forKey: .endedAt)
        activeDurationS = try values.decode(Int.self, forKey: .activeDurationS)
        distanceM = try values.decode(Int.self, forKey: .distanceM)
        steps = try values.decode(Int.self, forKey: .steps)
        caloriesKcal = try values.decode(Double.self, forKey: .caloriesKcal)
        exportedToHealth = try values.decode(Bool.self, forKey: .exportedToHealth)
        rawPadSteps = try values.decodeIfPresent(Int.self, forKey: .rawPadSteps)
        stepModelVersion = try values.decodeIfPresent(String.self, forKey: .stepModelVersion)
            ?? (rawPadSteps == nil ? "legacy" : nil)
    }

    public var avgSpeedKmh: Double {
        guard activeDurationS > 0 else { return 0 }
        return Double(distanceM) / Double(activeDurationS) * 3.6
    }
}

/// Aggregate for one calendar day.
public struct DayTotals: Equatable, Sendable, Identifiable {
    public let day: Date
    public var walks = 0
    public var activeDurationS = 0
    public var distanceM = 0
    public var steps = 0
    public var caloriesKcal = 0.0

    public init(day: Date) { self.day = day }

    public var id: Date { day }
    public var isEmpty: Bool { walks == 0 }

    public mutating func add(_ session: WalkSession, calendar: Calendar = .current) {
        let from = calendar.startOfDay(for: day)
        guard let through = calendar.date(byAdding: .day, value: 1, to: from) else { return }
        let wall = max(1, session.endedAt.timeIntervalSince(session.startedAt))
        let lower = min(1, max(0, from.timeIntervalSince(session.startedAt) / wall))
        let upper = min(1, max(0, through.timeIntervalSince(session.startedAt) / wall))
        guard upper > lower else { return }
        // Records do not retain pause timestamps. Split across midnight in
        // proportion to wall time; cumulative rounding preserves exact totals.
        func portion(_ value: Int) -> Int {
            Int((Double(value) * upper).rounded()) - Int((Double(value) * lower).rounded())
        }
        walks += 1
        activeDurationS += portion(session.activeDurationS)
        distanceM += portion(session.distanceM)
        steps += portion(session.steps)
        caloriesKcal += session.caloriesKcal * (upper - lower)
    }
}

/// Durable walk history on disk.
///
/// A plain JSON array in Application Support — small enough to keep in memory
/// (a year of walking is a few hundred entries), and readable by hand when
/// something looks wrong. Read failures degrade to an empty history rather
/// than throwing: losing the log must never block walking.
public final class SessionStore: @unchecked Sendable {
    /// Maximum gap when deriving a Health workout from distinct belt segments.
    public static let mergeGap: TimeInterval = 10 * 60

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Z1 WalkingPad", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    /// Oldest first.
    public private(set) var sessions: [WalkSession] = []

    private let url: URL
    private var healthQueue: HealthQueue?
    private var healthCutover: Date?
    private var healthCheck: DispatchWorkItem?
    private var openWalkStartedAt: Date?
    private var hasPendingHistoryLogs = false
    /// Timer-driven rechecks in a row since something last changed. Drives the
    /// backoff so a batch the phone never collects costs less and less.
    private var healthRetryAttempt = 0
    /// Entries in `sessions.json` that could not be read. They are not in
    /// `sessions`, so the next save would erase them; `save()` first copies
    /// the unreadable file aside.
    public private(set) var unreadableEntryCount = 0
    private var unreadableFileNeedsRescue = false

    public func setPendingHistoryLogs(_ pending: Bool) {
        let changed = hasPendingHistoryLogs != pending
        hasPendingHistoryLogs = pending
        if changed, !pending { checkHealthQueue() }
    }

    public func setOpenWalkStartedAt(_ date: Date?) { openWalkStartedAt = date }

    public init(
        url: URL = SessionStore.defaultURL(), openWalkStartedAt: Date? = nil,
        hasPendingHistoryLogs: Bool = false,
        healthQueue: HealthQueue? = nil, healthCutover: Date? = nil,
        healthQueueURL: URL? = nil
    ) {
        self.url = url
        self.openWalkStartedAt = openWalkStartedAt
        self.hasPendingHistoryLogs = hasPendingHistoryLogs
        _ = load()
        if let healthQueue, let healthCutover {
            self.healthQueue = healthQueue
            self.healthCutover = healthCutover
            checkHealthQueue()
        } else if let healthQueueURL {
            configureHealthQueue(HealthQueue(url: healthQueueURL))
        } else if url.standardizedFileURL == Self.defaultURL().standardizedFileURL {
            configureHealthQueue(HealthQueue())
        }
    }

    /// Pick up what is on disk. A clean file is trusted completely, so a walk
    /// deleted by hand disappears. A file that could not be read cleanly (or
    /// that fell back to an older backup) is not: this app is the only
    /// writer, so a history that suddenly shrinks means a failed read, and
    /// replacing memory with it would make the next save erase real walks.
    public func reload() {
        let held = sessions
        if !load() {
            let known = Set(sessions.map(\.id))
            let forgotten = held.filter { !known.contains($0.id) }
            if !forgotten.isEmpty {
                sessions = (sessions + forgotten).sorted { $0.startedAt < $1.startedAt }
            }
        }
        checkHealthQueue()
    }

    public func contains(id: String) -> Bool {
        sessions.contains { $0.id == id }
    }

    /// Append unless this walk is already recorded. Returns false on a duplicate.
    @discardableResult
    public func append(_ session: WalkSession) -> Bool {
        guard !contains(id: session.id) else { return false }
        let previous = sessions
        // Keep each belt segment and its stable ID. Health may group nearby
        // segments separately without changing history or duplicate detection.
        if let idx = sessions.firstIndex(where: { $0.startedAt > session.startedAt }) {
            sessions.insert(session, at: idx)
        } else {
            sessions.append(session)
        }
        if save() {
            checkHealthQueue()
            return true
        }
        sessions = previous
        return false
    }

    /// Drain a tracker entry only after durable history contains it. A failed
    /// write leaves the tracker entry intact so the caller can retry later.
    @discardableResult
    public func record(_ walk: CompletedWalk, weightKg: Double, tracker: inout RemoteSessionTracker) -> Bool {
        setPendingHistoryLogs(tracker.hasPendingLogs)
        guard walk.activeDurationS >= 120 else {
            tracker.acknowledgeLog(sessionID: walk.id)
            setPendingHistoryLogs(tracker.hasPendingLogs)
            return true
        }
        let kcal = Z1Metrics.kcalPerMinute(walk.avgSpeedKmh, weightKg: weightKg)
            * Double(walk.activeDurationS) / 60
        let session = WalkSession(
            id: walk.id, startedAt: walk.startedAt, endedAt: walk.endedAt,
            activeDurationS: walk.activeDurationS, distanceM: walk.distanceM,
            steps: walk.steps, caloriesKcal: (kcal * 10).rounded() / 10,
            exportedToHealth: false, rawPadSteps: walk.rawPadSteps,
            stepModelVersion: walk.rawPadSteps == nil ? "gait-v1" : nil
        )
        guard append(session) || contains(id: walk.id) else { return false }
        tracker.acknowledgeLog(sessionID: walk.id)
        setPendingHistoryLogs(tracker.hasPendingLogs)
        return true
    }

    public func totals(on day: Date = Date(), calendar: Calendar = .current) -> DayTotals {
        let start = calendar.startOfDay(for: day)
        var totals = DayTotals(day: start)
        for session in sessions { totals.add(session, calendar: calendar) }
        return totals
    }

    /// Inclusive calendar days from `start` through `end`.
    public func days(
        from start: Date,
        through end: Date,
        calendar: Calendar = .current
    ) -> [DayTotals] {
        let from = calendar.startOfDay(for: start)
        let to = calendar.startOfDay(for: end)
        guard to >= from else { return [] }
        var byDay: [Date: DayTotals] = [:]
        var cursor = from
        while cursor <= to {
            byDay[cursor] = DayTotals(day: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let through = calendar.date(byAdding: .day, value: 1, to: to) ?? to
        for session in sessions {
            // Visit only the days this walk overlaps. History redraws should
            // not scan every saved walk once for every day in the range.
            let end = max(session.endedAt, session.startedAt.addingTimeInterval(1))
            guard end > from, session.startedAt < through else { continue }
            var day = max(from, calendar.startOfDay(for: session.startedAt))
            while day <= to, day < end {
                byDay[day]?.add(session, calendar: calendar)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The cutover is the moment the Health queue was first switched on. Only
    /// walks that started after it are ever queued: the history before it may
    /// already be in Health (or in an old queue the Mac cannot inspect).
    private func configureHealthQueue(_ queue: HealthQueue) {
        let cutoverURL = url.deletingLastPathComponent().appendingPathComponent("health-queue-cutover.json")
        do {
            let cutoff: Date
            if FileManager.default.fileExists(atPath: cutoverURL.path),
               let data = try? Data(contentsOf: cutoverURL),
               let saved = try? Self.makeDecoder().decode(Date.self, from: data)
            {
                cutoff = saved
            } else {
                // First run, or a cutover file that cannot be read. Either way
                // start from now: never exporting old history is safe, never
                // exporting anything again (the previous behaviour for a
                // damaged file) is not.
                cutoff = Date()
                try FileManager.default.createDirectory(at: cutoverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.makeEncoder().encode(cutoff).write(to: cutoverURL, options: .atomic)
            }
            healthCutover = cutoff
            healthQueue = queue
            checkHealthQueue()
        } catch {
            NSLog("Z1: Health queue disabled; could not retain migration cutoff: \(error.localizedDescription)")
        }
    }

    /// How long to wait before looking at a blocked Health batch again.
    /// `attempt` counts consecutive timer-driven rechecks: one minute, then
    /// doubling to a quarter of an hour. The phone owns consumption of the
    /// batch and a deletion takes minutes to sync, so a faster poll finds
    /// nothing; and a phone that never collects must not keep the Mac waking
    /// every minute forever.
    public static func healthRetryDelay(attempt: Int) -> TimeInterval {
        min(15 * 60, 60 * pow(2, Double(max(0, min(attempt, 10)))))
    }

    /// Recheck when a 10-minute grouping window closes. A fresh segment
    /// cancels the old check and extends the window without changing IDs.
    private func checkHealthQueue(fromTimer: Bool = false) {
        guard let healthQueue, let healthCutover else { return }
        healthCheck?.cancel()
        healthCheck = nil
        if !fromTimer { healthRetryAttempt = 0 }
        var retryNeeded = false
        do {
            _ = try healthQueue.enqueueReadyGroups(sessions: sessions, now: Date(), notBefore: healthCutover, openWalkStartedAt: openWalkStartedAt, hasPendingHistoryLogs: hasPendingHistoryLogs)
        } catch {
            retryNeeded = true
            NSLog("Z1: Health queue write failed: \(error.localizedDescription)")
        }
        guard let last = sessions.last, last.startedAt >= healthCutover else { return }
        let deadline = last.endedAt.addingTimeInterval(Self.mergeGap + 1)
        let delay: TimeInterval
        if deadline > Date() {
            delay = deadline.timeIntervalSinceNow
        } else if healthQueue.hasDeferredWork || retryNeeded {
            delay = Self.healthRetryDelay(attempt: healthRetryAttempt)
            healthRetryAttempt += 1
        } else {
            healthRetryAttempt = 0
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.checkHealthQueue(fromTimer: true) }
        healthCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, delay), execute: work)
    }

    // MARK: - persistence

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private struct Loaded {
        var walks: [WalkSession] = []
        /// Entries present in the file that could not be decoded.
        var unreadable = 0
        /// The file could not be read as a walk list at all.
        var wholeFileUnreadable = false
    }

    /// Returns whether the main file was read cleanly.
    @discardableResult
    private func load() -> Bool {
        let primary = decodeWalks(from: url)
        let existed = FileManager.default.fileExists(atPath: url.path)
        let primaryIsClean = existed && primary.unreadable == 0 && !primary.wholeFileUnreadable
        var loaded = primary.walks
        // A valid empty array is authoritative too. Restoring an old backup
        // here would resurrect intentionally removed history on every launch.
        if loaded.isEmpty, !primaryIsClean {
            let bak = url.deletingLastPathComponent().appendingPathComponent("sessions.json.bak")
            loaded = decodeWalks(from: bak).walks
        }
        if loaded.isEmpty, !primaryIsClean {
            loaded = decodeWalksFromAgentExport(
                url.deletingLastPathComponent().appendingPathComponent("agent-data.json")
            )
        }
        sessions = loaded.sorted { $0.startedAt < $1.startedAt }
        unreadableEntryCount = primary.unreadable
        unreadableFileNeedsRescue = primary.unreadable > 0 || primary.wholeFileUnreadable
        // Loading history must never mutate it: old records were already
        // merged and their original pad counts cannot be reconstructed.
        // A missing file is not an explicit empty history. During reload,
        // keep walks already held in memory until a clean replacement exists.
        return primaryIsClean
    }

    /// One bad entry must not hide the rest of the history. Entries that do
    /// decode are kept; the count of those that do not is reported.
    private struct Lossy: Decodable {
        let walk: WalkSession?
        init(from decoder: Decoder) throws { walk = try? WalkSession(from: decoder) }
    }

    private func decodeWalks(from file: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: file.path) else { return Loaded() }
        guard let data = try? Data(contentsOf: file) else {
            return Loaded(wholeFileUnreadable: true)
        }
        let decoder = Self.makeDecoder()
        if let walks = try? decoder.decode([WalkSession].self, from: data) {
            return Loaded(walks: walks)
        }
        if let entries = try? decoder.decode([Lossy].self, from: data) {
            let walks = entries.compactMap(\.walk)
            return Loaded(walks: walks, unreadable: entries.count - walks.count)
        }
        // Some older builds stored the export envelope at the history path.
        // Preserve its unreadable-entry count just as for a plain walk list,
        // otherwise the next save silently discards records it cannot decode.
        struct Envelope: Decodable { var sessions: [Lossy] }
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            let walks = envelope.sessions.compactMap(\.walk)
            return Loaded(walks: walks, unreadable: envelope.sessions.count - walks.count)
        }
        return Loaded(wholeFileUnreadable: true)
    }

    private func decodeWalksFromAgentExport(_ file: URL) -> [WalkSession] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        struct Envelope: Decodable { var sessions: [Lossy] }
        return (try? Self.makeDecoder().decode(Envelope.self, from: data))?.sessions.compactMap(\.walk) ?? []
    }

    public static func shouldMerge(_ a: WalkSession, _ b: WalkSession) -> Bool {
        let gap = b.startedAt.timeIntervalSince(a.endedAt)
        return gap >= 0 && gap <= mergeGap
    }

    /// Writes the history atomically, keeping the first-upgrade copies and a rescue copy of anything unreadable.
    @discardableResult
    private func save() -> Bool {
        if sessions.isEmpty, FileManager.default.fileExists(atPath: url.path) {
            NSLog("Z1: refused to overwrite walk history with an empty list")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // The first write after upgrading keeps an immutable copy of the
            // exact legacy bytes. This happens before any new schema is saved.
            let legacy = url.deletingLastPathComponent().appendingPathComponent("sessions.legacy.json")
            if !FileManager.default.fileExists(atPath: legacy.path) {
                let source: URL
                if FileManager.default.fileExists(atPath: url.path) {
                    source = url
                } else {
                    source = url.deletingLastPathComponent().appendingPathComponent("sessions.json.bak")
                }
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: legacy)
                }
            }
            let bak = url.deletingLastPathComponent().appendingPathComponent("sessions.json.bak")
            if FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.fileExists(atPath: bak.path) {
                try FileManager.default.copyItem(at: url, to: bak)
            }
            // The file holds entries this build could not read (or is not a
            // walk list at all). Saving writes only what was understood, so
            // keep the original aside first rather than erasing it.
            if unreadableFileNeedsRescue, FileManager.default.fileExists(atPath: url.path) {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                let rescue = url.deletingLastPathComponent()
                    .appendingPathComponent("sessions.unreadable-\(stamp)-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: rescue)
                unreadableFileNeedsRescue = false
            }
            try Self.makeEncoder().encode(sessions).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Z1: could not save walk history: \(error.localizedDescription)")
            return false
        }
    }
}
