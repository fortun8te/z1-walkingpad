import Foundation
import Z1Core

/// Regression scenarios from the independent review. No production paths or BLE.
public func adversarialPersistenceTests(_ t: TestRunner) {
    t.suite("adversarial persistence and midnight") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("z1-adversarial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func frame(running: Bool, elapsed: Int, distance: Int, steps: Int) -> Z1Treadmill.Status {
            var s = Z1Treadmill.Status()
            s.phase = .ready; s.hasTelemetry = true
            s.beltRunning = running; s.speedKmh = running ? 3 : 0
            s.elapsedS = elapsed; s.distanceM = distance; s.steps = steps
            return s
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var tracker = RemoteSessionTracker()
            _ = tracker.observe(frame(running: true, elapsed: 900, distance: 750, steps: 1200), at: base, newSessionID: { "durable" })
            _ = tracker.observe(frame(running: false, elapsed: 900, distance: 750, steps: 1200), at: base.addingTimeInterval(1))
            let finished = tracker.finalizeIfDue(at: base.addingTimeInterval(121))
            guard let walk = finished.completed.first else {
                t.check(false, "failed-save fixture has a completed walk"); return
            }
            let blockedDirectory = root.appendingPathComponent("blocked")
            try Data("blocks directory".utf8).write(to: blockedDirectory)
            let store = SessionStore(url: blockedDirectory.appendingPathComponent("sessions.json"))
            t.check(!store.record(walk, weightKg: 75, tracker: &tracker), "failed disk write is reported")
            t.check(tracker.hasPendingLogs, "failed disk write retains the pending tracker log")
            t.expectEqual(store.sessions.count, 0, "failed write does not leave fake saved history")
            // Simulate process recreation from persisted pending tracker state.
            tracker = try JSONDecoder().decode(RemoteSessionTracker.self, from: JSONEncoder().encode(tracker))
            try FileManager.default.removeItem(at: blockedDirectory)
            t.check(store.record(walk, weightKg: 75, tracker: &tracker), "recovered storage records the retained walk")
            t.check(!tracker.hasPendingLogs, "successful disk write acknowledges the tracker")
            t.expectEqual(SessionStore(url: blockedDirectory.appendingPathComponent("sessions.json")).sessions.count, 1, "walk survives reopening history")
            t.check(store.record(walk, weightKg: 75, tracker: &tracker), "repeated acknowledgement succeeds")
            t.expectEqual(store.sessions.count, 1, "repeated recording does not duplicate history")

            var beforeQuit = RemoteSessionTracker()
            _ = beforeQuit.observe(frame(running: true, elapsed: 900, distance: 750, steps: 1200), at: base, newSessionID: { "yesterday" })
            var restored = try JSONDecoder().decode(RemoteSessionTracker.self, from: JSONEncoder().encode(beforeQuit))
            restored.markConnectionDrop(at: base.addingTimeInterval(86400))
            let restarted = restored.observe(frame(running: true, elapsed: 10, distance: 6, steps: 10), at: base.addingTimeInterval(86410), newSessionID: { "today" })
            t.expectEqual(restarted.completed.first?.id, "yesterday", "startup closes an old restored walk at its old timestamp")
            t.expectEqual(restarted.completed.first?.endedAt, base, "reopening does not move yesterday's stop into today")
            t.expectEqual(restored.openWalkTotals?.id, "today", "fresh pad counters get a fresh walk ID")
            t.expectEqual(restored.openWalkTotals?.activeDurationS, 10, "old duration does not leak into new walk")

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let midnight = calendar.startOfDay(for: base)
            let cross = CompletedWalk(id: "midnight", startedAt: midnight.addingTimeInterval(-600), endedAt: midnight.addingTimeInterval(600), activeDurationS: 1200, distanceM: 1000, steps: 1601, offeredToHealth: false)
            let midnightStore = SessionStore(url: root.appendingPathComponent("midnight/sessions.json"))
            var emptyTracker = RemoteSessionTracker()
            t.check(midnightStore.record(cross, weightKg: 75, tracker: &emptyTracker), "cross-midnight walk is saved")
            let today = midnightStore.totals(on: midnight, calendar: calendar)
            let yesterday = midnightStore.totals(on: midnight.addingTimeInterval(-1), calendar: calendar)
            t.expectEqual(today.activeDurationS, 600, "today gets its half of a midnight walk")
            t.expectEqual(yesterday.activeDurationS, 600, "yesterday gets its half of a midnight walk")
            t.expectEqual(today.steps + yesterday.steps, 1601, "cross-midnight rounding conserves all steps")
            t.expectEqual(today.distanceM + yesterday.distanceM, 1000, "cross-midnight totals conserve distance")
            let days = midnightStore.days(from: midnight.addingTimeInterval(-86400), through: midnight, calendar: calendar)
            t.expectEqual(days.map(\.activeDurationS), [600, 600], "calendar series agrees with day totals")
            let hourly = midnightStore.hourlyKcal(on: midnight, calendar: calendar)
            t.expectEqual(hourly.reduce(0, +), today.caloriesKcal, accuracy: 0.001, "hourly chart agrees with today's split")
            let records = HighScoreComputer.compute(from: midnightStore.sessions, calendar: calendar)
            t.expectEqual(records.longestDayTime?.activeDurationS, 600, "daily records use the same midnight allocation")
            t.expectEqual(records.bestStreakDays, 2, "both active sides of midnight reach daily record aggregation")
            t.expectEqual(records.totalSteps, 1601, "daily splitting does not change lifetime steps")

            let queueURL = root.appendingPathComponent("queue/health-queue.json")
            let receiptBlocker = root.appendingPathComponent("receipt-blocker")
            try Data("blocks receipt storage".utf8).write(to: receiptBlocker)
            let receiptsURL = receiptBlocker.appendingPathComponent("receipts.json")
            let queue = HealthQueue(url: queueURL, receiptsURL: receiptsURL)
            let eligible = WalkSession(id: "queue-retry", startedAt: base, endedAt: base.addingTimeInterval(900), activeDurationS: 900, distanceM: 750, steps: 1200, caloriesKcal: 50, exportedToHealth: false)
            do {
                _ = try queue.enqueueReadyGroups(sessions: [eligible], now: base.addingTimeInterval(2000), notBefore: base)
                t.check(false, "receipt failure propagates before publication")
            } catch { t.check(true, "receipt failure propagates before publication") }
            t.check(!FileManager.default.fileExists(atPath: queueURL.path), "known receipt failure publishes no batch")
            try FileManager.default.removeItem(at: receiptBlocker)
            t.expectEqual(try queue.enqueueReadyGroups(sessions: [eligible], now: base.addingTimeInterval(2001), notBefore: base), 1, "receipt recovery publishes once")
            // Simulate a legacy/crash window: the queue exists but its receipt is missing.
            try FileManager.default.removeItem(at: receiptsURL)
            t.expectEqual(try queue.enqueueReadyGroups(sessions: [eligible], now: base.addingTimeInterval(2002), notBefore: base), 0, "existing batch repairs its receipt without republishing")
            t.check(FileManager.default.fileExists(atPath: receiptsURL.path), "receipt is repaired durably")
            try FileManager.default.removeItem(at: queueURL)
            t.expectEqual(try queue.enqueueReadyGroups(sessions: [eligible], now: base.addingTimeInterval(2003), notBefore: base), 0, "consumed repaired batch stays consumed")

            // A failed history continuation must block the older segment's
            // export before startup's first queue check, and after recovery.
            let recentBase = Date().addingTimeInterval(-5000)
            let historyDirectory = root.appendingPathComponent("pending-history")
            let historyURL = historyDirectory.appendingPathComponent("sessions.json")
            let first = WalkSession(id: "first-half", startedAt: recentBase, endedAt: recentBase.addingTimeInterval(900), activeDurationS: 900, distanceM: 750, steps: 1200, caloriesKcal: 50, exportedToHealth: false)
            t.check(SessionStore(url: historyURL).append(first), "pending-group fixture stores its first half")
            var pendingTracker = RemoteSessionTracker()
            _ = pendingTracker.observe(frame(running: true, elapsed: 900, distance: 750, steps: 1200), at: recentBase.addingTimeInterval(1900), newSessionID: { "second-half" })
            _ = pendingTracker.observe(frame(running: false, elapsed: 900, distance: 750, steps: 1200), at: recentBase.addingTimeInterval(1901))
            let pending = pendingTracker.finalizeIfDue(at: recentBase.addingTimeInterval(2021))
            guard let second = pending.completed.first else { t.check(false, "pending continuation exists"); return }
            let pendingQueueURL = root.appendingPathComponent("pending-queue/health-queue.json")
            let pendingQueue = HealthQueue(url: pendingQueueURL)
            let pendingStore = SessionStore(url: historyURL, hasPendingHistoryLogs: pendingTracker.hasPendingLogs, healthQueue: pendingQueue, healthCutover: recentBase.addingTimeInterval(-1))
            t.check(!FileManager.default.fileExists(atPath: pendingQueueURL.path), "startup holds export while a restored history log is pending")
            let movedHistory = root.appendingPathComponent("pending-history-backup")
            try FileManager.default.moveItem(at: historyDirectory, to: movedHistory)
            try Data("blocks history retry".utf8).write(to: historyDirectory)
            t.check(!pendingStore.record(second, weightKg: 75, tracker: &pendingTracker), "continuation fails to save in the fixture")
            t.check(!FileManager.default.fileExists(atPath: pendingQueueURL.path), "failed continuation cannot export a partial group")
            try FileManager.default.removeItem(at: historyDirectory)
            try FileManager.default.moveItem(at: movedHistory, to: historyDirectory)
            t.check(pendingStore.record(second, weightKg: 75, tracker: &pendingTracker), "continuation saves after recovery")
            let groupedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: pendingQueueURL)) as? [String: Any]
            let grouped = groupedJSON?["workouts"] as? [[String: Any]]
            t.expectEqual(grouped?.count, 1, "recovered group publishes once")
            t.expectEqual(grouped?.first?["duration_s"] as? Int, 1800, "recovered publication contains both halves")
            try FileManager.default.removeItem(at: pendingQueueURL)
            pendingStore.reload()
            t.check(!FileManager.default.fileExists(atPath: pendingQueueURL.path), "consumption cannot drop or requeue the recovered continuation")
        } catch { t.check(false, "isolated adversarial fixture: \(error)") }
    }
}
