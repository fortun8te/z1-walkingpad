import Foundation

/// The single file read by the Z1 Import Health iPhone Shortcut.
///
/// Queueing is not proof that Health received a workout. In particular, callers
/// must not set `WalkSession.exportedToHealth` after this writer succeeds.
public final class HealthQueue {
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/z1-walkingpad", isDirectory: true)
            .appendingPathComponent("health-queue.json")
    }

    public static func defaultReceiptsURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Z1 WalkingPad/health-queue-receipts.json")
    }

    private let url: URL
    private let receiptsURL: URL
    private let lock = NSLock()
    /// Another batch is waiting for the existing Shortcut batch to disappear.
    /// SessionStore retries it from durable history; deferred IDs are not receipts.
    public private(set) var hasDeferredWork = false

    /// Inject both paths in tests. A custom queue path without a receipt path
    /// puts its receipts next to that queue, never in real Application Support.
    public init(url: URL = HealthQueue.defaultURL(), receiptsURL: URL? = nil) {
        self.url = url
        self.receiptsURL = receiptsURL ?? (
            url.standardizedFileURL == Self.defaultURL().standardizedFileURL
                ? Self.defaultReceiptsURL()
                : url.deletingLastPathComponent().appendingPathComponent("health-queue-receipts.json")
        )
    }

    /// Add a workout to an injected test or manual queue. The production queue
    /// refuses this direct path because callers may pass a belt-run segment
    /// before its 10-minute Health grouping window has closed. Production
    /// writes must use `enqueueReadyGroups`.
    @discardableResult
    public func enqueue(_ session: WalkSession) throws -> Bool {
        guard url.standardizedFileURL != Self.defaultURL().standardizedFileURL else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try read()
        var receipts = try readReceipts()
        receipts.formUnion(Self.ids(in: envelope.workouts))
        try writeReceipts(receipts)
        let knownIDs = Self.ids(in: envelope.workouts).union(receipts)
        guard let workout = Self.workout(for: session), !knownIDs.contains(session.id) else {
            return false
        }
        // The phone deletes the whole file after importing its snapshot. Never
        // append behind that snapshot or the phone could erase an unseen walk.
        guard envelope.workouts.isEmpty else { return false }
        envelope.workouts.append(workout)
        try write(envelope)
        receipts.insert(session.id)
        try writeReceipts(receipts)
        return true
    }

    /// Compare the existing queue with stored sessions on startup without
    /// rewriting either. Returns the number of stored session IDs already in
    /// the queue. Historical backfill requires an explicit grouped export
    /// after the older queue is checked on the phone.
    @discardableResult
    public func reconcile(sessions: [WalkSession]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let queuedIDs = Self.ids(in: try read().workouts)
        return sessions.reduce(0) { $0 + (queuedIDs.contains($1.id) ? 1 : 0) }
    }

    /// Derive complete Health workouts from distinct belt-run segments.
    /// Segments separated by at most 10 minutes share one workout. The last
    /// segment must also be at least 10 minutes old, so a resume cannot alter
    /// an already queued workout. `notBefore` excludes the uncertain legacy
    /// history until its old iCloud queue has been checked on the phone.
    @discardableResult
    public func enqueueReadyGroups(
        sessions: [WalkSession],
        now: Date = Date(),
        notBefore: Date,
        openWalkStartedAt: Date? = nil,
        hasPendingHistoryLogs: Bool = false
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try read()
        var receipts = try readReceipts()
        receipts.formUnion(Self.ids(in: envelope.workouts))
        // Check local receipt storage before publishing. Also repair receipts
        // from any published batch that is still available locally.
        try writeReceipts(receipts)
        var knownIDs = Self.ids(in: envelope.workouts).union(receipts)
        hasDeferredWork = hasPendingHistoryLogs
        // An unsaved segment can change a grouping that appears complete in
        // history. Wait for all pending log writes before publishing any group.
        guard !hasPendingHistoryLogs else { return 0 }
        // Keep each published batch immutable until the existing Shortcut
        // consumes it. This preserves the v2 path and phone workflow.
        let batchAlreadyPublished = !envelope.workouts.isEmpty
        let sorted = sessions.sorted { $0.startedAt < $1.startedAt }
        var groups: [[WalkSession]] = []
        for session in sorted where session.startedAt >= notBefore {
            if let last = groups.last?.last,
               session.startedAt.timeIntervalSince(last.endedAt) >= 0,
               session.startedAt.timeIntervalSince(last.endedAt) <= 600 {
                groups[groups.count - 1].append(session)
            } else {
                groups.append([session])
            }
        }
        var added = 0
        for group in groups {
            guard let first = group.first, let last = group.last,
                  now.timeIntervalSince(last.endedAt) >= 600,
                  !group.contains(where: \.exportedToHealth),
                  !knownIDs.contains(first.id) else { continue }
            // A resumed belt run may still be active and therefore absent
            // from history. Wait rather than publish a partial grouped walk.
            if let openWalkStartedAt,
               openWalkStartedAt >= last.endedAt,
               openWalkStartedAt.timeIntervalSince(last.endedAt) <= 600 {
                hasDeferredWork = true
                continue
            }
            let combined = WalkSession(
                id: first.id,
                startedAt: first.startedAt,
                endedAt: last.endedAt,
                activeDurationS: group.reduce(0) { $0 + $1.activeDurationS },
                distanceM: group.reduce(0) { $0 + $1.distanceM },
                steps: group.reduce(0) { $0 + $1.steps },
                caloriesKcal: group.reduce(0) { $0 + $1.caloriesKcal },
                exportedToHealth: false
            )
            guard let workout = Self.workout(for: combined) else { continue }
            if batchAlreadyPublished {
                hasDeferredWork = true
                continue
            }
            envelope.workouts.append(workout)
            knownIDs.insert(first.id)
            receipts.insert(first.id)
            added += 1
        }
        if added > 0 {
            try write(envelope)
            try writeReceipts(receipts)
        }
        return added
    }

    public func queuedSessionIDs() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Self.ids(in: try read().workouts)
    }

    private struct Envelope {
        var fields: [String: Any]
        var workouts: [[String: Any]]
    }

    private func read() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Envelope(fields: [:], workouts: [])
        }
        let data = try Data(contentsOf: url)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = fields["schema_version"] as? NSNumber,
              version.intValue == 2,
              let workouts = fields["workouts"] as? [[String: Any]] else {
            throw HealthQueueError.invalidExistingQueue
        }
        return Envelope(fields: fields, workouts: workouts)
    }

    private func write(_ envelope: Envelope) throws {
        var fields = envelope.fields
        fields["schema_version"] = 2
        fields["workouts"] = envelope.workouts
        let data = try JSONSerialization.data(
            withJSONObject: fields,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func readReceipts() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: receiptsURL.path) else { return [] }
        let data = try Data(contentsOf: receiptsURL)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = fields["schema_version"] as? NSNumber, version.intValue == 1,
              let ids = fields["queued_session_ids"] as? [String] else {
            throw HealthQueueError.invalidReceipts
        }
        return Set(ids)
    }

    private func writeReceipts(_ ids: Set<String>) throws {
        let fields: [String: Any] = [
            "schema_version": 1,
            "queued_session_ids": ids.sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: receiptsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: receiptsURL, options: .atomic)
    }

    private static func ids(in workouts: [[String: Any]]) -> Set<String> {
        Set(workouts.compactMap { $0["session_id"] as? String })
    }

    private static func workout(for session: WalkSession) -> [String: Any]? {
        let wallDuration = session.endedAt.timeIntervalSince(session.startedAt)
        let activeDuration = session.activeDurationS
        guard !session.exportedToHealth,
              !session.id.isEmpty,
              activeDuration >= 600, activeDuration <= 86_400,
              session.distanceM >= 100, session.distanceM <= 200_000,
              session.steps >= 0,
              wallDuration.isFinite, wallDuration > 0, wallDuration <= 86_400,
              Double(activeDuration) <= wallDuration + 5,
              Double(session.distanceM) / Double(activeDuration) * 3.6 <= 7 else {
            return nil
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = TimeZone(secondsFromGMT: 0)
        return [
            "schema_version": 1,
            "session_id": session.id,
            "source": "z1-walkingpad",
            "started_at": format.string(from: session.startedAt),
            "ended_at": format.string(from: session.endedAt),
            "duration_s": activeDuration,
            "wall_duration_s": Int(wallDuration),
            "wall_duration_min": (wallDuration / 60 * 1_000).rounded() / 1_000,
            "distance_m": session.distanceM,
            "steps": session.steps,
        ]
    }
}

public enum HealthQueueError: Error {
    case invalidExistingQueue
    case invalidReceipts
}
