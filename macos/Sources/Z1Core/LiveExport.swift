import Foundation

/// Publishes a small, read-only snapshot for Superapp and other local readers.
/// The caller supplies today's completed and open-walk totals so this file does
/// not have to infer them from the pad's resettable counters.
@MainActor
public final class LiveExport {
    public nonisolated static func defaultURL() -> URL {
        SessionStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("live.json")
    }

    private struct Snapshot: Codable, Equatable {
        let schema: Int
        var updatedAt: String
        let connected: Bool
        let beltRunning: Bool
        let speedKmh: Double
        let elapsedSec: Int
        let distanceM: Int
        let steps: Int
        let caloriesKcal: Double
        let todayDate: String
        let todayDistanceM: Int
        let todayMinutes: Double
        let todaySteps: Int
        let todayKcal: Double
        let goalProgress: Double
    }

    private let url: URL
    private var lastPublishedAt: Date?
    private var lastSnapshot: Snapshot?

    public init(url: URL = LiveExport.defaultURL()) {
        self.url = url
    }

    /// Returns true only when a file was written. Connected frames are capped
    /// at one write per second; a disconnect clears stale live state at once.
    @discardableResult
    public func publish(
        status: Z1Treadmill.Status,
        today: DayTotals,
        goalProgress: Double,
        at now: Date = Date()
    ) throws -> Bool {
        let connected = status.phase == .ready
        if let lastPublishedAt, connected, lastSnapshot?.connected == true,
           now.timeIntervalSince(lastPublishedAt) < 1 { return false }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let snapshot = Snapshot(
            schema: 1,
            updatedAt: ISO8601DateFormatter().string(from: now),
            connected: connected,
            beltRunning: connected && status.beltRunning,
            speedKmh: connected ? max(0, status.speedKmh) : 0,
            elapsedSec: max(0, status.elapsedS),
            distanceM: max(0, status.distanceM),
            steps: max(0, status.steps),
            caloriesKcal: status.caloriesKcal.isFinite ? max(0, status.caloriesKcal) : 0,
            todayDate: dayFormatter.string(from: today.day),
            todayDistanceM: max(0, today.distanceM),
            todayMinutes: Double(max(0, today.activeDurationS)) / 60,
            todaySteps: max(0, today.steps),
            todayKcal: today.caloriesKcal.isFinite ? max(0, today.caloriesKcal) : 0,
            goalProgress: goalProgress.isFinite ? min(1, max(0, goalProgress)) : 0
        )
        // Disconnected state is event-driven. Suppress identical data without
        // suppressing later totals, goal changes, or the next calendar day.
        if !connected, var previous = lastSnapshot {
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot { return false }
        }
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        lastPublishedAt = now
        lastSnapshot = snapshot
        return true
    }
}
