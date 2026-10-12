import Foundation
import Z1Core

public func pendingWalkDisplayTests(_ t: TestRunner) async {
    await t.suite("pending completed walk display") { t in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("z1-display-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let start = day.addingTimeInterval(3600)
        func frame(_ running: Bool, elapsed: Int = 900, distance: Int = 750, steps: Int = 1200) -> Z1Treadmill.Status {
            var value = Z1Treadmill.Status()
            value.phase = .ready; value.hasTelemetry = true
            value.beltRunning = running; value.speedKmh = running ? 3 : 0
            value.elapsedS = elapsed; value.distanceM = distance; value.steps = steps
            return value
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let blocked = root.appendingPathComponent("blocked")
            try Data("unwritable directory".utf8).write(to: blocked)
            let store = SessionStore(url: blocked.appendingPathComponent("sessions.json"))
            var tracker = RemoteSessionTracker()
            _ = tracker.observe(frame(true), at: start, newSessionID: { "pending-display" })
            _ = tracker.observe(frame(false), at: start.addingTimeInterval(1))
            func displayed(_ tracker: RemoteSessionTracker, on date: Date = day) -> DayTotals {
                WalkDisplayTotals.addingTrackedWalks(to: store.totals(on: date, calendar: calendar), savedSessionIDs: Set(store.sessions.map(\.id)), tracker: tracker, weightKg: 75, calendar: calendar)
            }
            func awaiting(_ tracker: RemoteSessionTracker, on date: Date = day) -> Bool {
                WalkDisplayTotals.hasPendingSave(on: date, savedSessionIDs: Set(store.sessions.map(\.id)), tracker: tracker, calendar: calendar)
            }
            var justOpened = RemoteSessionTracker()
            _ = justOpened.observe(frame(true, elapsed: 0, distance: 0, steps: 0), at: start, newSessionID: { "zero-open" })
            t.expectEqual(displayed(justOpened).walks, 0, "zero-duration open frame preserves existing walk count")
            let grace = displayed(tracker)
            t.check(!awaiting(tracker), "grace window does not claim a failed save")
            let result = tracker.finalizeIfDue(at: start.addingTimeInterval(121))
            guard let walk = result.completed.first else { t.check(false, "fixture completes at fake grace deadline"); return }
            t.expectNil(tracker.openWalkTotals, "completed pending walk leaves open tracker")
            t.check(!store.record(walk, weightKg: 75, tracker: &tracker), "fixture actually fails its history save")
            let pending = displayed(tracker)
            t.check(awaiting(tracker), "failed save shows awaiting-save hint")
            t.check(!awaiting(tracker, on: day.addingTimeInterval(-86400)), "hint belongs only to the pending walk's day")
            t.expectEqual(pending, grace, "Today retains all totals and goal progress after failed save")
            t.expectEqual(pending.walks, 1, "History counts the pending walk once")
            tracker = try JSONDecoder().decode(RemoteSessionTracker.self, from: JSONEncoder().encode(tracker))
            t.expectEqual(displayed(tracker), grace, "restored durable pending logs still appear")
            let exportURL = root.appendingPathComponent("live.json")
            let writer = await MainActor.run { LiveExport(url: exportURL) }
            _ = try await writer.publish(status: frame(false), today: pending, goalProgress: Double(pending.activeDurationS) / 7200, at: start.addingTimeInterval(122))
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
            t.expectEqual(json?["todayMinutes"] as? Double, 15, "live JSON retains completed pending minutes")
            t.expectEqual(json?["todayDistanceM"] as? Int, 750, "live JSON retains completed pending distance")
            t.expectEqual(json?["goalProgress"] as? Double, 0.125, "live JSON retains goal progress")
            _ = tracker.observe(frame(true, elapsed: 120, distance: 100, steps: 160), at: start.addingTimeInterval(130), newSessionID: { "next-open" })
            t.expectEqual(displayed(tracker).activeDurationS, 1020, "new open walk adds to pending completed walk")
            t.expectEqual(displayed(tracker).walks, 2, "open and pending walks each count once")
            try FileManager.default.removeItem(at: blocked)
            t.check(store.record(walk, weightKg: 75, tracker: &tracker), "storage recovery saves the completed walk")
            let saved = displayed(tracker)
            t.check(!awaiting(tracker), "successful retry clears awaiting-save hint")
            t.expectEqual(saved.activeDurationS, 1020, "retry keeps saved plus open totals stable")
            t.expectEqual(saved.walks, 2, "retry does not count completed walk twice")
            // Simulate a crash after the history write but before acknowledgement.
            var duplicatePending = try JSONDecoder().decode(RemoteSessionTracker.self, from: JSONEncoder().encode(RemoteSessionTracker()))
            _ = duplicatePending.observe(frame(true), at: start, newSessionID: { walk.id })
            _ = duplicatePending.observe(frame(false), at: start.addingTimeInterval(1))
            _ = duplicatePending.finalizeIfDue(at: start.addingTimeInterval(121))
            t.expectEqual(displayed(duplicatePending).activeDurationS, 900, "saved and pending stable ID is counted once")
            t.check(!awaiting(duplicatePending), "saved ID suppresses stale pending-save hint")
            t.check(store.record(walk, weightKg: 75, tracker: &tracker), "repeat retry succeeds")
            t.expectEqual(displayed(tracker), saved, "repeat retry preserves all displayed totals")
            // A pending cross-midnight walk uses the same day allocation as saved history.
            var midnight = RemoteSessionTracker()
            let boundary = day.addingTimeInterval(86400)
            _ = midnight.observe(frame(true, elapsed: 0, distance: 0, steps: 0), at: boundary.addingTimeInterval(-600), newSessionID: { "midnight-pending" })
            _ = midnight.observe(frame(true, elapsed: 1200, distance: 1000, steps: 1601), at: boundary.addingTimeInterval(600))
            _ = midnight.observe(frame(false, elapsed: 1200, distance: 1000, steps: 1601), at: boundary.addingTimeInterval(601))
            _ = midnight.finalizeIfDue(at: boundary.addingTimeInterval(721))
            let beforeMidnight = displayed(midnight)
            let afterMidnight = displayed(midnight, on: boundary)
            t.expectEqual(beforeMidnight.activeDurationS + afterMidnight.activeDurationS, 2100, "pending midnight allocation conserves time plus saved history")
            t.expectEqual(beforeMidnight.steps + afterMidnight.steps, 2801, "pending midnight allocation conserves steps plus saved history")
            t.check(awaiting(midnight) && awaiting(midnight, on: boundary), "pending midnight hint appears on both affected days")
        } catch { t.check(false, "isolated pending display fixture: \(error)") }
    }
}
