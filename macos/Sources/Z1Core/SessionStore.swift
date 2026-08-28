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

    public func contains(id: String) -> Bool {
        sessions.contains { $0.id == id }
    }

    /// Append unless this walk is already recorded. Returns false on a duplicate.
    @discardableResult
    public func append(_ session: WalkSession) -> Bool {
        guard !contains(id: session.id) else { return false }
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

    public func mostRecent(_ count: Int) -> [WalkSession] {
        Array(sessions.suffix(count).reversed())
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
        guard let data = try? Data(contentsOf: url),
              let decoded = try? Self.makeDecoder().decode([WalkSession].self, from: data)
        else { return }
        sessions = decoded.sorted { $0.startedAt < $1.startedAt }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // retain data on update: keep .bak of previous file so a crash mid-write never loses history
            if FileManager.default.fileExists(atPath: url.path) {
                let bak = url.deletingLastPathComponent().appendingPathComponent("sessions.json.bak")
                try? FileManager.default.copyItem(at: url, to: bak)
                // keep only one backup, remove stale if needed
                if let attrs = try? FileManager.default.attributesOfItem(atPath: bak.path),
                   let size = attrs[.size] as? Int, size == 0 {
                    try? FileManager.default.removeItem(at: bak)
                }
            }
            try Self.makeEncoder().encode(sessions).write(to: url, options: .atomic)
            writeAgentExportIfNeeded()
        } catch {
            NSLog("Z1: could not save walk history: \(error.localizedDescription)")
        }
    }
}
