import Foundation
import Z1Core

private func regressionWalk(
    _ id: String,
    start: Date,
    minutes: Int = 15,
    meters: Int = 750,
    steps: Int = 1_111,
    exported: Bool = false
) -> WalkSession {
    WalkSession(
        id: id,
        startedAt: start,
        endedAt: start.addingTimeInterval(Double(minutes * 60)),
        activeDurationS: minutes * 60,
        distanceM: meters,
        steps: steps,
        caloriesKcal: 45.25,
        exportedToHealth: exported
    )
}

/// Reads and writes only a unique temporary directory. This fixture is never
/// pointed at the installed app's history or the iCloud Shortcuts queue.
public func sessionMigrationRegressionTests(_ t: TestRunner) {
    t.suite("session migration") { t in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-migration-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("sessions.json")
        let previousBackup = directory.appendingPathComponent("sessions.json.bak")
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let old = [
            regressionWalk("legacy-exported", start: base, exported: true),
            regressionWalk("legacy-pending", start: base.addingTimeInterval(3_600), steps: 2_222),
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let iso = ISO8601DateFormatter()
            let bytes = Data("""
                [{"id":"legacy-exported","startedAt":"\(iso.string(from: old[0].startedAt))",\
                "endedAt":"\(iso.string(from: old[0].endedAt))","activeDurationS":900,\
                "distanceM":750,"steps":1111,"caloriesKcal":45.25,"exportedToHealth":true},\
                {"id":"legacy-pending","startedAt":"\(iso.string(from: old[1].startedAt))",\
                "endedAt":"\(iso.string(from: old[1].endedAt))","activeDurationS":900,\
                "distanceM":750,"steps":2222,"caloriesKcal":45.25,"exportedToHealth":false}]
                """.utf8)
            try bytes.write(to: source)
            let existingBackup = Data("prior backup must remain byte-for-byte".utf8)
            try existingBackup.write(to: previousBackup)

            let reopened = SessionStore(url: source)
            t.expectEqual(reopened.sessions.map(\.id), old.map(\.id), "legacy IDs survive load")
            t.expectEqual(reopened.sessions.map(\.steps), [1_111, 2_222], "stored step values survive load")
            t.expectEqual(reopened.sessions.map(\.exportedToHealth), [true, false], "export flags survive load")
            t.expectEqual(reopened.sessions.map(\.stepModelVersion), ["legacy", "legacy"], "old step values are labelled estimates")
            t.expectEqual(try Data(contentsOf: source), bytes, "opening history does not rewrite its bytes")

            let added = regressionWalk("new-session", start: base.addingTimeInterval(7_200))
            t.check(reopened.append(added), "new walk appends")
            let backup = directory.appendingPathComponent("sessions.legacy.json")
            t.check(FileManager.default.fileExists(atPath: backup.path), "first write copies original to legacy backup")
            if let copied = try? Data(contentsOf: backup) {
                t.expectEqual(copied, bytes, "legacy backup is an exact copy")
            }
            t.expectEqual(try Data(contentsOf: previousBackup), existingBackup, "migration keeps an existing backup")
            let after = SessionStore(url: source)
            t.expectEqual(after.sessions.count, 3, "all old walks plus new walk survive reload")
            t.expectEqual(after.sessions.first?.id, "legacy-exported", "first legacy ID stays stable")
        } catch {
            t.check(false, "temporary migration fixture: \(error)")
        }
    }
}

/// Opt-in check of the nine historical walks. The source is only read; every
/// load and append happens against a temporary copy.
public func realHistoryCopyRegressionTests(_ t: TestRunner) {
    guard let path = ProcessInfo.processInfo.environment["Z1_LEGACY_SESSIONS_SOURCE"], !path.isEmpty else {
        return
    }
    t.suite("nine-session copy migration") { t in
        let original = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-real-history-copy-\(UUID().uuidString)", isDirectory: true)
        let copiedURL = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let before = try Data(contentsOf: original)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: copiedURL)
            let store = SessionStore(url: copiedURL)
            let ids = store.sessions.map(\.id)
            t.expectEqual(store.sessions.count, 9, "all nine historical sessions decode")
            t.expectEqual(Set(ids).count, 9, "all historical IDs are unique")
            t.expectEqual(store.sessions.filter(\.exportedToHealth).count, 3, "three imported Health flags survive")
            t.expectEqual(try Data(contentsOf: copiedURL), before, "loading does not rewrite copied history")

            let future = (store.sessions.map(\.endedAt).max() ?? Date()).addingTimeInterval(86_400)
            t.check(store.append(regressionWalk("synthetic-copy-only", start: future)), "synthetic session appends to copy")
            let after = SessionStore(url: copiedURL)
            t.expectEqual(after.sessions.count, 10, "copy contains all nine plus synthetic session")
            t.expectEqual(Set(after.sessions.map(\.id)).subtracting(["synthetic-copy-only"]), Set(ids), "all IDs retained")
            t.expectEqual(try Data(contentsOf: directory.appendingPathComponent("sessions.legacy.json")), before, "migration backup copies original bytes")
            t.expectEqual(try Data(contentsOf: original), before, "source history remains byte-for-byte unchanged")
        } catch {
            t.check(false, "copy-only historical migration: \(error)")
        }
    }
}

public func beltSegmentRegressionTests(_ t: TestRunner) {
    t.suite("belt segment boundaries") { t in
        func status(running: Bool, elapsed: Int, distance: Int) -> Z1Treadmill.Status {
            var value = Z1Treadmill.Status()
            value.phase = .ready
            value.hasTelemetry = true
            value.beltRunning = running
            value.speedKmh = running ? 3.0 : 0
            value.elapsedS = elapsed
            value.distanceM = distance
            value.steps = distance * 2
            return value
        }

        let base = Date(timeIntervalSince1970: 2_100_000_000)
        let grace = RemoteSessionTracker.stopGraceSeconds
        t.expectEqual(grace, 120, "belt run splits after about two minutes stopped")
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(status(running: false, elapsed: 0, distance: 0), at: base)
        _ = tracker.observe(
            status(running: true, elapsed: 1, distance: 1),
            at: base.addingTimeInterval(1),
            newSessionID: { "segment-one" }
        )
        _ = tracker.observe(
            status(running: true, elapsed: 600, distance: 500),
            at: base.addingTimeInterval(600)
        )
        let stoppedAt = base.addingTimeInterval(601)
        _ = tracker.observe(status(running: false, elapsed: 600, distance: 500), at: stoppedAt)
        t.check(
            tracker.finalizeIfDue(at: stoppedAt.addingTimeInterval(grace - 1)).completed.isEmpty,
            "119-second pause stays in one segment"
        )
        let finished = tracker.finalizeIfDue(at: stoppedAt.addingTimeInterval(grace))
        t.expectEqual(finished.completed.first?.id, "segment-one", "first belt run gets its own ID")
        if let first = finished.completed.first { tracker.acknowledgeLog(sessionID: first.id) }
        _ = tracker.observe(
            status(running: true, elapsed: 1, distance: 1),
            at: stoppedAt.addingTimeInterval(grace + 1),
            newSessionID: { "segment-two" }
        )
        t.expectEqual(tracker.openWalkTotals?.id, "segment-two", "restart after gap begins a new segment")

        let first = regressionWalk("health-one", start: base, minutes: 15)
        let tenMinuteGap = regressionWalk(
            "health-two", start: first.endedAt.addingTimeInterval(600), minutes: 15
        )
        let elevenMinuteGap = regressionWalk(
            "health-three", start: first.endedAt.addingTimeInterval(601), minutes: 15
        )
        t.check(SessionStore.shouldMerge(first, tenMinuteGap), "Health grouping includes a ten-minute gap")
        t.check(!SessionStore.shouldMerge(first, elevenMinuteGap), "Health grouping excludes a longer gap")
    }
}

/// The state the queue is in after it has been backed up and reset: the file
/// exists with an empty batch and the receipts remember older walks.
public func healthQueueResetFileTests(_ t: TestRunner) {
    t.suite("Health queue reset file") { t in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-health-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("health-queue.json")
        let receiptsURL = directory.appendingPathComponent("health-queue-receipts.json")
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let older = regressionWalk("older-queued-walk", start: base)
        let fresh = regressionWalk("fresh-walk", start: base.addingTimeInterval(86_400))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"schema_version":2,"workouts":[]}"#.utf8).write(to: queueURL)
            try Data(#"{"schema_version":1,"queued_session_ids":["older-queued-walk"]}"#.utf8).write(to: receiptsURL)

            let queue = HealthQueue(url: queueURL, receiptsURL: receiptsURL)
            let added = try queue.enqueueReadyGroups(
                sessions: [older, fresh], now: fresh.endedAt.addingTimeInterval(601), notBefore: base
            )
            t.expectEqual(added, 1, "the next walk is appended to the emptied file")
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any]
            t.expectEqual(root?["schema_version"] as? Int, 2, "the file stays schema 2")
            let workouts = root?["workouts"] as? [[String: Any]] ?? []
            t.expectEqual(workouts.compactMap { $0["session_id"] as? String }, ["fresh-walk"], "only the new walk, not the receipted one")

            // The keys the Z1 Import Health Shortcut reads.
            for key in ["started_at", "ended_at", "wall_duration_min", "distance_m", "steps"] {
                t.check(workouts.first?[key] != nil, "workout carries \(key)")
            }
            let receipts = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptsURL)) as? [String: Any]
            t.expectEqual(
                Set(receipts?["queued_session_ids"] as? [String] ?? []),
                Set(["older-queued-walk", "fresh-walk"]),
                "receipts keep the old walk and add the new one"
            )
            t.expectEqual(
                try queue.enqueueReadyGroups(
                    sessions: [older, fresh], now: fresh.endedAt.addingTimeInterval(700), notBefore: base
                ),
                0,
                "a second pass queues nothing while the batch waits"
            )
        } catch { t.check(false, "reset-file fixture: \(error)") }
    }
}

public func healthQueueRegressionTests(_ t: TestRunner) {
    t.suite("Health queue") { t in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-health-\(UUID().uuidString)", isDirectory: true)
        let queueURL = directory.appendingPathComponent("health-queue.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let pending = regressionWalk("queue-pending", start: base)
        let imported = regressionWalk("queue-imported", start: base.addingTimeInterval(3_600), exported: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let queue = HealthQueue(url: queueURL)
            t.check(try queue.enqueue(pending), "new eligible walk is queued")
            t.check(try !queue.enqueue(pending), "same ID is not queued twice")
            t.check(try !queue.enqueue(imported), "already-exported walk is not queued")

            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any]
            t.expectEqual(root?["schema_version"] as? Int, 2, "single queue file uses schema version 2")
            let workouts = root?["workouts"] as? [[String: Any]] ?? []
            t.expectEqual(workouts.count, 1, "one workout in the single file")
            t.expectEqual(workouts.first?["schema_version"] as? Int, 1, "workout schema version 1")
            t.expectEqual(workouts.first?["session_id"] as? String, pending.id, "stable session ID")
            t.expectEqual(workouts.first?["source"] as? String, "z1-walkingpad", "Shortcuts source identifier")
            t.expectEqual(workouts.first?["duration_s"] as? Int, pending.activeDurationS, "active duration field")
            t.expectEqual(workouts.first?["distance_m"] as? Int, pending.distanceM, "distance field")
            t.expectEqual(workouts.first?["steps"] as? Int, pending.steps, "step field")
            t.check((workouts.first?["started_at"] as? String)?.hasSuffix("Z") == true, "UTC timestamp")

            let reopened = HealthQueue(url: queueURL)
            t.check(try !reopened.enqueue(pending), "dedupe survives reload")
            let later = regressionWalk("queue-later", start: base.addingTimeInterval(7_200))
            let phoneSnapshot = try Data(contentsOf: queueURL)
            t.check(try !reopened.enqueue(later), "new walk waits while phone may be reading the batch")
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any]
            let ids = (after?["workouts"] as? [[String: Any]] ?? []).compactMap { $0["session_id"] as? String }
            t.expectEqual(ids, [pending.id], "published batch stays immutable")
            t.expectEqual(try Data(contentsOf: queueURL), phoneSnapshot, "phone snapshot cannot miss a newly appended walk")
            t.expectEqual(try reopened.enqueueReadyGroups(
                sessions: [pending, later], now: later.endedAt.addingTimeInterval(601), notBefore: base
            ), 0, "production grouping also defers behind existing batch")
            t.check(reopened.hasDeferredWork, "store is told to retry deferred sessions")
            // Model the phone deleting the file it read before the new walk.
            try FileManager.default.removeItem(at: queueURL)
            t.expectEqual(try reopened.enqueueReadyGroups(
                sessions: [pending, later], now: later.endedAt.addingTimeInterval(601), notBefore: base
            ), 1, "deferred walk survives phone deletion and is queued next")
            t.expectEqual(try reopened.queuedSessionIDs(), Set([later.id]), "next batch contains only the unseen walk")
            t.check(!reopened.hasDeferredWork, "successful next batch clears retry state")
            try FileManager.default.removeItem(at: queueURL)

            let firstSegment = regressionWalk(
                "group-first", start: base.addingTimeInterval(20_000), minutes: 6, meters: 300
            )
            let secondSegment = regressionWalk(
                "group-second", start: firstSegment.endedAt.addingTimeInterval(5 * 60), minutes: 6, meters: 300
            )
            t.expectEqual(
                try reopened.enqueueReadyGroups(
                    sessions: [firstSegment, secondSegment],
                    now: secondSegment.endedAt.addingTimeInterval(599),
                    notBefore: base
                ),
                0,
                "group waits for ten minutes after last belt run"
            )
            t.expectEqual(
                try reopened.enqueueReadyGroups(
                    sessions: [firstSegment, secondSegment],
                    now: secondSegment.endedAt.addingTimeInterval(600),
                    notBefore: base
                ),
                1,
                "two short segments form one eligible workout"
            )
            let grouped = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any]
            let groupRecord = (grouped?["workouts"] as? [[String: Any]] ?? [])
                .first { $0["session_id"] as? String == firstSegment.id }
            t.expectEqual(groupRecord?["duration_s"] as? Int, 720, "group active time excludes the pause")
            t.expectEqual(groupRecord?["distance_m"] as? Int, 600, "group distance sums segments")
            t.check(
                (grouped?["workouts"] as? [[String: Any]] ?? [])
                    .allSatisfy { $0["session_id"] as? String != secondSegment.id },
                "group retains first segment's stable ID"
            )

            try FileManager.default.removeItem(at: queueURL)
            t.check(try !reopened.enqueue(pending), "receipt prevents re-export after Shortcut consumes queue")
            let resumedFirst = regressionWalk("resumed-first", start: base.addingTimeInterval(40_000))
            let resumedSecond = regressionWalk("resumed-second", start: resumedFirst.endedAt.addingTimeInterval(300), minutes: 30)
            let restartedQueue = HealthQueue(url: queueURL)
            t.expectEqual(try restartedQueue.enqueueReadyGroups(
                sessions: [resumedFirst], now: resumedFirst.endedAt.addingTimeInterval(601), notBefore: base,
                openWalkStartedAt: resumedSecond.startedAt
            ), 0, "active resumed run prevents premature partial export after restart")
            t.check(restartedQueue.hasDeferredWork, "active run schedules later queue retry")
            t.expectEqual(try restartedQueue.enqueueReadyGroups(
                sessions: [resumedFirst, resumedSecond], now: resumedSecond.endedAt.addingTimeInterval(601), notBefore: base
            ), 1, "completed resumed run joins first run in one workout")
            let resumedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any]
            let resumedWorkouts = resumedJSON?["workouts"] as? [[String: Any]]
            t.expectEqual(resumedWorkouts?.first?["duration_s"] as? Int, 2700, "neither resumed segment is lost")

        } catch {
            t.check(false, "temporary Health queue fixture: \(error)")
        }
    }
}

public func liveExportRegressionTests(_ t: TestRunner) async {
    await t.suite("Superapp live export") { t in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-live-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("live.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var status = Z1Treadmill.Status()
        status.phase = .ready
        status.beltRunning = true
        status.speedKmh = 3.2
        status.elapsedS = 300
        status.distanceM = 267
        status.steps = 418
        status.caloriesKcal = 19.25
        var today = DayTotals(day: Date(timeIntervalSince1970: 2_000_000_000))
        today.activeDurationS = 1_800
        today.distanceM = 1_600
        today.steps = 2_400
        today.caloriesKcal = 87.5
        let exporter = await MainActor.run { LiveExport(url: url) }
        let first = Date(timeIntervalSince1970: 2_000_000_000)
        do {
            t.check(
                try await exporter.publish(status: status, today: today, goalProgress: 0.25, at: first),
                "first connected snapshot writes"
            )
            let original = try Data(contentsOf: url)
            t.check(
                !(try await exporter.publish(status: status, today: today, goalProgress: 0.3, at: first.addingTimeInterval(0.5))),
                "connected frames are capped at one per second"
            )
            t.expectEqual(try Data(contentsOf: url), original, "throttled frame leaves bytes untouched")
            let live = try JSONSerialization.jsonObject(with: original) as? [String: Any]
            t.expectEqual(live?["schema"] as? Int, 1, "Superapp schema version")
            t.expectEqual(live?["caloriesKcal"] as? Double ?? -1, 19.25, accuracy: 0.001, "live kcal is distinct from day kcal")
            t.expectEqual(live?["connected"] as? Bool, true, "connected flag")
            t.expectEqual(live?["speedKmh"] as? Double ?? -1, 3.2, accuracy: 0.0001, "live speed")
            t.expectEqual(live?["todayDistanceM"] as? Int, 1_600, "today includes completed and open totals")
            t.expectEqual(live?["todayMinutes"] as? Double ?? -1, 30, accuracy: 0.0001, "today minutes")
            t.expectEqual(live?["goalProgress"] as? Double ?? -1, 0.25, accuracy: 0.0001, "goal progress")

            status.phase = .disconnected
            t.check(
                try await exporter.publish(status: status, today: today, goalProgress: 0.25, at: first.addingTimeInterval(0.6)),
                "disconnect immediately clears stale live state"
            )
            let cleared = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            t.expectEqual(cleared?["connected"] as? Bool, false, "disconnect flag")
            t.expectEqual(cleared?["beltRunning"] as? Bool, false, "disconnect clears moving flag")
            t.expectEqual(cleared?["speedKmh"] as? Double ?? -1, 0, accuracy: 0.0001, "disconnect clears speed")
            t.expectEqual(cleared?["todayDistanceM"] as? Int, 1_600, "day totals remain after disconnect")
            t.check(!(try await exporter.publish(status: status, today: today, goalProgress: 0.25, at: first.addingTimeInterval(2))), "unchanged disconnected snapshot does not rewrite")
            today.steps = 2_500
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0.5, at: first.addingTimeInterval(3)), "disconnected totals and goal changes publish")
            let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            t.expectEqual(updated?["todaySteps"] as? Int, 2_500, "updated disconnected totals reach readers")
            t.expectEqual(updated?["goalProgress"] as? Double ?? -1, 0.5, accuracy: 0.001, "updated disconnected goal reaches readers")
            var nextDay = DayTotals(day: today.day.addingTimeInterval(86_400))
            nextDay.steps = today.steps
            nextDay.distanceM = today.distanceM
            nextDay.activeDurationS = today.activeDurationS
            nextDay.caloriesKcal = today.caloriesKcal
            t.check(try await exporter.publish(status: status, today: nextDay, goalProgress: 0.5, at: first.addingTimeInterval(86_400)), "same totals on another date still publish")
        } catch {
            t.check(false, "temporary live export fixture: \(error)")
        }
    }
}
