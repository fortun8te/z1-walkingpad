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
    /// Unused; kept so existing `sessions.json` files still decode.
    public let exportedToHealth: Bool

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        activeDurationS: Int,
        distanceM: Int,
        steps: Int,
        caloriesKcal: Double,
        exportedToHealth: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationS = activeDurationS
        self.distanceM = distanceM
        self.steps = steps
        self.caloriesKcal = caloriesKcal
        self.exportedToHealth = exportedToHealth
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

    public mutating func add(_ session: WalkSession) {
        walks += 1
        activeDurationS += session.activeDurationS
        distanceM += session.distanceM
        steps += session.steps
        caloriesKcal += session.caloriesKcal
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
public final class SessionStore {
    /// Keep the file bounded; ~5 years of daily walks.
    public static let maxSessions = 2_000
    /// BLE drop / rebuild gap. Two records closer than this are one walk.
    public static let mergeGap: TimeInterval = 3 * 60 * 60

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

    public init(url: URL = SessionStore.defaultURL()) {
        self.url = url
        load()
    }

    public func reload() {
        load()
    }

    public func contains(id: String) -> Bool {
        sessions.contains { $0.id == id }
    }

    /// Append unless this walk is already recorded. Returns false on a duplicate.
    @discardableResult
    public func append(_ session: WalkSession) -> Bool {
        var session = session
        let repaired = GaitModel.steps(
            distanceM: session.distanceM,
            durationS: session.activeDurationS
        )
        if repaired != session.steps {
            session = WalkSession(
                id: session.id,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                activeDurationS: session.activeDurationS,
                distanceM: session.distanceM,
                steps: repaired,
                caloriesKcal: session.caloriesKcal,
                exportedToHealth: session.exportedToHealth
            )
        }
        guard !contains(id: session.id) else { return false }
        if let last = sessions.last, Self.shouldMerge(last, session) {
            sessions[sessions.count - 1] = Self.merged(last, session)
            save()
            return true
        }
        // insertion keep sorted — O(n) not O(n log n), faster for 2k
        if let idx = sessions.firstIndex(where: { $0.startedAt > session.startedAt }) {
            sessions.insert(session, at: idx)
        } else {
            sessions.append(session)
        }
        if sessions.count > Self.maxSessions {
            sessions.removeFirst(sessions.count - Self.maxSessions)
        }
        save()
        return true
    }

    public func totals(on day: Date = Date(), calendar: Calendar = .current) -> DayTotals {
        let start = calendar.startOfDay(for: day)
        var totals = DayTotals(day: start)
        for session in sessions where calendar.startOfDay(for: session.startedAt) == start {
            totals.add(session)
        }
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
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            guard byDay[day] != nil else { continue }
            byDay[day]?.add(session)
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
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            guard byDay[day] != nil else { continue }
            byDay[day]?.add(session)
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
        var walks = sessions.filter { $0.startedAt >= start && $0.startedAt < end }
        if let extra, extra.startedAt >= start, extra.startedAt < end {
            walks.append(extra)
        }
        for walk in walks {
            let minutes = max(1, walk.activeDurationS / 60)
            let perMin = walk.caloriesKcal / Double(minutes)
            for m in 0..<minutes {
                let t = walk.startedAt.addingTimeInterval(Double(m) * 60)
                let hour = calendar.component(.hour, from: t)
                if (0..<24).contains(hour) { bins[hour] += perMin }
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

    /// Agent-readable export: sessions + daily aggregates + highscores + achievements.
    /// Written alongside sessions.json for MCP/Python agents.
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
        // also mirror to ~/.z1-walkingpad/agent-data.json for Python agents
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            let alt = home.appendingPathComponent(".z1-walkingpad/agent-data.json")
            try? FileManager.default.createDirectory(at: alt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: alt, options: .atomic)
        }
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
        let coalesced = coalesceAdjacent()
        let sanitized = sanitizeImpossibleSteps()
        if coalesced || sanitized { save() }
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
        return gap >= 0 && gap < mergeGap
    }

    public static func merged(_ a: WalkSession, _ b: WalkSession) -> WalkSession {
        WalkSession(
            id: a.id,
            startedAt: a.startedAt,
            endedAt: max(a.endedAt, b.endedAt),
            activeDurationS: a.activeDurationS + b.activeDurationS,
            distanceM: a.distanceM + b.distanceM,
            steps: GaitModel.steps(
                distanceM: a.distanceM + b.distanceM,
                durationS: a.activeDurationS + b.activeDurationS
            ),
            caloriesKcal: a.caloriesKcal + b.caloriesKcal,
            exportedToHealth: a.exportedToHealth && b.exportedToHealth
        )
    }

    @discardableResult
    private func coalesceAdjacent() -> Bool {
        guard sessions.count >= 2 else { return false }
        var out: [WalkSession] = []
        var dirty = false
        for session in sessions {
            if let last = out.last, Self.shouldMerge(last, session) {
                out[out.count - 1] = Self.merged(last, session)
                dirty = true
            } else {
                out.append(session)
            }
        }
        if dirty { sessions = out }
        return dirty
    }

    /// Rewrite stored steps from belt distance and average speed.
    @discardableResult
    private func sanitizeImpossibleSteps() -> Bool {
        var dirty = false
        sessions = sessions.map { session in
            guard session.distanceM >= 20 else { return session }
            let repaired = GaitModel.steps(
                distanceM: session.distanceM,
                durationS: session.activeDurationS
            )
            guard repaired != session.steps else { return session }
            dirty = true
            return WalkSession(
                id: session.id,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                activeDurationS: session.activeDurationS,
                distanceM: session.distanceM,
                steps: repaired,
                caloriesKcal: session.caloriesKcal,
                exportedToHealth: session.exportedToHealth
            )
        }
        return dirty
    }

    /// Save atomically; called from background — safe to run while swift build holds lock.
    private func save() {
        if sessions.isEmpty, FileManager.default.fileExists(atPath: url.path) {
            NSLog("Z1: refused to overwrite walk history with an empty list")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bak = url.deletingLastPathComponent().appendingPathComponent("sessions.json.bak")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: url, to: bak)
            }
            try Self.makeEncoder().encode(sessions).write(to: url, options: .atomic)
            writeAgentExportIfNeeded()
        } catch {
            NSLog("Z1: could not save walk history: \(error.localizedDescription)")
        }
    }
}
