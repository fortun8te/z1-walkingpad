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

    public var stepsAreEstimated: Bool { rawPadSteps == nil }
    public var effectiveStepModelVersion: String? {
        rawPadSteps == nil ? stepModelVersion : nil
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

    /// Fold a still-open walk into today's history card without replacing
    /// its live step estimate with a second calculation.
    public mutating func addOpenWalk(_ walk: CompletedWalk, weightKg: Double) {
        let priorWalks = walks
        add(WalkSession(
            id: walk.id, startedAt: walk.startedAt, endedAt: walk.endedAt,
            activeDurationS: walk.activeDurationS, distanceM: walk.distanceM,
            steps: walk.steps,
            caloriesKcal: Z1Metrics.kcalPerMinute(walk.avgSpeedKmh, weightKg: weightKg)
                * Double(walk.activeDurationS) / 60,
            exportedToHealth: false
        ))
        walks = priorWalks
    }

    public mutating func addDay(_ other: DayTotals) {
        walks += other.walks
        activeDurationS += other.activeDurationS
        distanceM += other.distanceM
        steps += other.steps
        caloriesKcal += other.caloriesKcal
    }
}

/// Durable walk history on disk.
///
/// A plain JSON array in Application Support — small enough to keep in memory
/// (a year of walking is a few hundred entries), and readable by hand when
/// something looks wrong. Read failures degrade to an empty history rather
/// than throwing: losing the log must never block walking.
public final class SessionStore: @unchecked Sendable {
    /// Historical compatibility constant. History is no longer silently pruned.
    public static let maxSessions = 2_000
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

    public func setPendingHistoryLogs(_ pending: Bool) {
        let changed = hasPendingHistoryLogs != pending
        hasPendingHistoryLogs = pending
        if changed, !pending { checkHealthQueue() }
    }

    public func setOpenWalkStartedAt(_ date: Date?) { openWalkStartedAt = date }

    public init(
        url: URL = SessionStore.defaultURL(), openWalkStartedAt: Date? = nil,
        hasPendingHistoryLogs: Bool = false,
        healthQueue: HealthQueue? = nil, healthCutover: Date? = nil
    ) {
        self.url = url
        self.openWalkStartedAt = openWalkStartedAt
        self.hasPendingHistoryLogs = hasPendingHistoryLogs
        load()
        if let healthQueue, let healthCutover {
            self.healthQueue = healthQueue
            self.healthCutover = healthCutover
            checkHealthQueue()
        } else {
            configureHealthQueue()
        }
    }

    public func reload() {
        load()
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

    /// `count` days ending on (and including) `endingOn`, oldest first.
    public func recentDays(
        _ count: Int,
        endingOn: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayTotals] {
        guard count > 0 else { return [] }
        let today = calendar.startOfDay(for: endingOn)
        var byDay: [Date: DayTotals] = [:]
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            byDay[day] = DayTotals(day: day)
        }
        for day in Array(byDay.keys) {
            for session in sessions { byDay[day]?.add(session, calendar: calendar) }
        }
        return byDay.values.sorted { $0.day < $1.day }
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
        for day in Array(byDay.keys) {
            for session in sessions { byDay[day]?.add(session, calendar: calendar) }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    public func mostRecent(_ count: Int) -> [WalkSession] {
        Array(sessions.suffix(count).reversed())
    }

    /// 24 hourly kcal buckets for a calendar day, from stored walks.
    public func hourlyKcal(on day: Date, extra: WalkSession? = nil, calendar: Calendar = .current) -> [Double] {
        var bins = Array(repeating: 0.0, count: 24)
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return bins }
        var walks = sessions
        if let extra { walks.append(extra) }
        for walk in walks {
            let wall = max(1, walk.endedAt.timeIntervalSince(walk.startedAt))
            var hourStart = start
            while hourStart < end {
                guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
                let overlap = max(0, min(hourEnd, walk.endedAt).timeIntervalSince(max(hourStart, walk.startedAt)))
                let hour = calendar.component(.hour, from: hourStart)
                bins[hour] += walk.caloriesKcal * overlap / wall
                hourStart = hourEnd
            }
        }
        return bins
    }

    // MARK: - highscores (derived, not stored — retains data on update)
    public var highScores: HighScores { HighScoreComputer.compute(from: sessions) }
    public var achievements: [Achievement] {
        let hs = highScores
        return HighScoreComputer.achievements(from: sessions, highScores: hs)
    }

    /// Compatibility export for callers that explicitly request the old format.
    public func exportForAgents() -> Data? {
        struct Export: Codable {
            var schemaVersion: Int
            var generatedAt: Date
            var sessionsCount: Int
            var sessions: [WalkSession]
            var highScores: HighScores
            var achievements: [Achievement]
            var dailyAggregates: [DayTotalsCodable]
        }
        let daily = recentDays(30).map(DayTotalsCodable.init)
        let hs = highScores
        let ach = achievements
        let exp = Export(schemaVersion: 1, generatedAt: Date(), sessionsCount: sessions.count, sessions: sessions, highScores: hs, achievements: ach, dailyAggregates: daily)
        let enc = Self.makeEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(exp)
    }

    public func writeAgentExportIfNeeded() {
        guard let data = exportForAgents() else { return }
        let url = url.deletingLastPathComponent().appendingPathComponent("agent-data.json")
        try? data.write(to: url, options: .atomic)
    }

    private func configureHealthQueue() {
        guard url.standardizedFileURL == Self.defaultURL().standardizedFileURL else { return }
        let cutoverURL = url.deletingLastPathComponent().appendingPathComponent("health-queue-cutover.json")
        do {
            let cutoff: Date
            if FileManager.default.fileExists(atPath: cutoverURL.path) {
                let data = try Data(contentsOf: cutoverURL)
                cutoff = try Self.makeDecoder().decode(Date.self, from: data)
            } else {
                cutoff = Date()
                try FileManager.default.createDirectory(at: cutoverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.makeEncoder().encode(cutoff).write(to: cutoverURL, options: .atomic)
            }
            healthCutover = cutoff
            healthQueue = HealthQueue()
            checkHealthQueue()
        } catch {
            NSLog("Z1: Health queue disabled; could not retain migration cutoff: \(error.localizedDescription)")
        }
    }

    /// Recheck when a 10-minute grouping window closes. A fresh segment
    /// cancels the old check and extends the window without changing IDs.
    private func checkHealthQueue() {
        guard let healthQueue, let healthCutover else { return }
        healthCheck?.cancel()
        healthCheck = nil
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
            // The phone owns consumption of the immutable current batch.
            // Rebuild the next batch from history once deletion reaches Mac.
            delay = 60
        } else {
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.checkHealthQueue() }
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

    private func load() {
        var loaded = decodeWalks(from: url)
        if loaded.isEmpty {
            let bak = url.deletingLastPathComponent().appendingPathComponent("sessions.json.bak")
            loaded = decodeWalks(from: bak)
        }
        if loaded.isEmpty {
            loaded = decodeWalksFromAgentExport(
                url.deletingLastPathComponent().appendingPathComponent("agent-data.json")
            )
        }
        sessions = loaded.sorted { $0.startedAt < $1.startedAt }
        // Loading history must never mutate it: old records were already
        // merged and their original pad counts cannot be reconstructed.
    }

    private func decodeWalks(from file: URL) -> [WalkSession] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let walks = try? Self.makeDecoder().decode([WalkSession].self, from: data) {
            return walks
        }
        return decodeWalksFromAgentExport(file)
    }

    private func decodeWalksFromAgentExport(_ file: URL) -> [WalkSession] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        struct Envelope: Codable { var sessions: [WalkSession] }
        return (try? Self.makeDecoder().decode(Envelope.self, from: data))?.sessions ?? []
    }

    public static func shouldMerge(_ a: WalkSession, _ b: WalkSession) -> Bool {
        let gap = b.startedAt.timeIntervalSince(a.endedAt)
        return gap >= 0 && gap <= mergeGap
    }

    public static func merged(_ a: WalkSession, _ b: WalkSession) -> WalkSession {
        WalkSession(
            id: a.id,
            startedAt: a.startedAt,
            endedAt: max(a.endedAt, b.endedAt),
            activeDurationS: a.activeDurationS + b.activeDurationS,
            distanceM: a.distanceM + b.distanceM,
            steps: a.steps + b.steps,
            caloriesKcal: a.caloriesKcal + b.caloriesKcal,
            exportedToHealth: a.exportedToHealth && b.exportedToHealth,
            rawPadSteps: (a.rawPadSteps != nil && b.rawPadSteps != nil)
                ? a.rawPadSteps! + b.rawPadSteps! : nil,
            stepModelVersion: a.effectiveStepModelVersion == b.effectiveStepModelVersion
                ? a.effectiveStepModelVersion : "mixed"
        )
    }

    /// Save atomically; called from background — safe to run while swift build holds lock.
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
            try Self.makeEncoder().encode(sessions).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Z1: could not save walk history: \(error.localizedDescription)")
            return false
        }
    }
}
