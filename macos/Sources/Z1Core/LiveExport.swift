import Foundation

/// Publishes a small, read-only snapshot for Superapp and other local readers.
/// The caller supplies today's completed and open-walk totals so this file does
/// not have to infer them from the pad's resettable counters.
///
/// Write policy. Readers watch the file and treat it as live while it is
/// younger than 15 s (Superapp) or 90 s (the MCP), and they show minutes and
/// metres, not seconds. So:
///   - a change of state (connected, belt started or stopped, a new day) is
///     written at once, and so is any change while nothing is streaming,
///     because after a Stop the pad stops sending frames and no later one would
///     ever correct the file;
///   - a change of speed is written, but at most once a second;
///   - plain progress (the clock, distance, steps) is written every
///     `heartbeatInterval`, which keeps the file fresh without a disk write for
///     every telemetry frame.
@MainActor
public final class LiveExport {
    public nonisolated static func defaultURL() -> URL {
        SessionStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("live.json")
    }

    /// Longest gap between writes while connected and the belt is moving.
    public nonisolated static let heartbeatInterval: TimeInterval = 5
    /// Shortest gap between two writes that are not state changes.
    public nonisolated static let minimumInterval: TimeInterval = 1

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
    // Formatters are expensive to build and this runs while walking.
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private let stampFormatter = ISO8601DateFormatter()

    public init(url: URL = LiveExport.defaultURL()) {
        self.url = url
    }

    /// Returns true only when a file was written.
    @discardableResult
    public func publish(
        status: Z1Treadmill.Status,
        today: DayTotals,
        goalProgress: Double,
        at now: Date = Date()
    ) throws -> Bool {
        let connected = status.phase == .ready
        let snapshot = Snapshot(
            schema: 1,
            updatedAt: stampFormatter.string(from: now),
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
        if !shouldWrite(snapshot, at: now) { return false }
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

    private func shouldWrite(_ snapshot: Snapshot, at now: Date) -> Bool {
        guard let last = lastSnapshot, let lastAt = lastPublishedAt else { return true }
        // A clock set backwards must not freeze the file until it catches up
        // with the last write: the file would stay stale for as long as the
        // clock was set back.
        let age = now.timeIntervalSince(lastAt)
        if age < 0 { return true }

        // Identical data is never rewritten while disconnected (the state is
        // event-driven there), and not at all while connected and idle either,
        // apart from the heartbeat that keeps readers' freshness check happy.
        var unchanged = last
        unchanged.updatedAt = snapshot.updatedAt
        if unchanged == snapshot {
            return snapshot.connected && snapshot.beltRunning && age >= Self.heartbeatInterval
        }

        // State changes go out immediately.
        if snapshot.connected != last.connected
            || snapshot.beltRunning != last.beltRunning
            || snapshot.todayDate != last.todayDate
        {
            return true
        }
        // Nothing is streaming while disconnected or while the belt is idle,
        // so a change here (a finished walk adding to today, a new goal) is a
        // rare event and no later frame would carry it. Publish it.
        if !snapshot.connected || !snapshot.beltRunning { return true }
        // Belt moving: frames arrive about once a second, so a speed change is
        // worth a prompt write and plain progress only a heartbeat.
        if (snapshot.speedKmh * 10).rounded() != (last.speedKmh * 10).rounded() {
            return age >= Self.minimumInterval
        }
        return age >= Self.heartbeatInterval
    }
}
