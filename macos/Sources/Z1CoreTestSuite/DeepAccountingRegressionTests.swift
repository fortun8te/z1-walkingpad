import Foundation
import Z1Core

public func deepAccountingRegressionTests(_ t: TestRunner) {
    let base = Date(timeIntervalSince1970: 2_000_000_000)
    func frame(_ elapsed: Int, _ distance: Int, _ steps: Int, running: Bool = true) -> Z1Treadmill.Status {
        var value = Z1Treadmill.Status()
        value.phase = .ready
        value.hasTelemetry = true
        value.beltRunning = running
        value.speedKmh = running ? 3 : 0
        value.elapsedS = elapsed
        value.distanceM = distance
        value.steps = steps
        return value
    }
    t.suite("offline and late stop counters are accounted once") { t in
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(frame(600, 500, 800), at: base, newSessionID: { "offline" })
        tracker.markConnectionDrop(at: base)
        _ = tracker.observe(frame(660, 550, 880, running: false), at: base.addingTimeInterval(90))
        t.expectEqual(tracker.openWalkTotals?.activeDurationS, 660, "stopped reconnect retains offline active time")
        t.expectEqual(tracker.openWalkTotals?.distanceM, 550, "stopped reconnect retains offline distance")
        t.expectEqual(tracker.openWalkTotals?.steps, 880, "stopped reconnect retains offline steps")
        t.check((tracker.openWalkTotals?.endedAt ?? .distantPast) >= base.addingTimeInterval(60), "recovered end covers recovered active duration")
        // Idle reset and stale counter snapshots must not replay old progress.
        _ = tracker.observe(frame(0, 0, 0, running: false), at: base.addingTimeInterval(91))
        _ = tracker.observe(frame(660, 550, 880, running: false), at: base.addingTimeInterval(92))
        t.expectEqual(tracker.openWalkTotals?.activeDurationS, 660, "idle counter reset cannot replay elapsed time")
        t.expectEqual(tracker.openWalkTotals?.distanceM, 550, "idle counter reset cannot replay distance")
        let deadline = tracker.finalizationDeadline!
        let done = tracker.finalizeIfDue(at: deadline).completed
        t.expectEqual(done.count, 1, "late counters still finalize a single walk")
        t.expectEqual(tracker.finalizeIfDue(at: deadline).completed, done, "pending log remains stable until acknowledgement")
        tracker.acknowledgeLog(sessionID: "offline")
        t.check(tracker.finalizeIfDue(at: deadline).completed.isEmpty, "acknowledgement drains exactly once")
    }
    t.suite("short resumed segments retain their steps") { t in
        for firstDistance in 1...20 {
            var tracker = RemoteSessionTracker()
            _ = tracker.observe(frame(60, firstDistance, firstDistance * 2), at: base)
            _ = tracker.observe(frame(60, firstDistance, firstDistance * 2, running: false), at: base.addingTimeInterval(1))
            _ = tracker.observe(frame(1, 1, 2), at: base.addingTimeInterval(2))
            _ = tracker.observe(frame(600, 400, 700), at: base.addingTimeInterval(601))
            t.expectEqual(tracker.openWalkTotals?.steps, firstDistance * 2 + 700, "resuming after \(firstDistance) metres retains earlier steps")
            t.expectEqual(tracker.openWalkTotals?.distanceM, firstDistance + 400, "resumed distance conserves both runs")
            do {
                tracker = try JSONDecoder().decode(RemoteSessionTracker.self, from: JSONEncoder().encode(tracker))
                _ = tracker.observe(frame(601, 401, 650), at: base.addingTimeInterval(602))
                t.expectEqual(tracker.openWalkTotals?.steps, firstDistance * 2 + 650, "restored model offset allows speed correction without losing prior run")
            } catch { t.check(false, "counter-offset round trip: \(error)") }
        }
    }
    t.suite("late reconnect conserves lifetime progress across midnight") { t in
        var tracker = RemoteSessionTracker()
        let midnight = Date(timeIntervalSince1970: 2_000_073_600)
        _ = tracker.observe(frame(600, 500, 800), at: midnight.addingTimeInterval(-60), newSessionID: { "before" })
        tracker.markConnectionDrop(at: midnight.addingTimeInterval(-60))
        _ = tracker.observe(frame(900, 750, 1200), at: midnight.addingTimeInterval(240), newSessionID: { "after" })
        let closed = tracker.pendingCompletedWalks
        t.expectEqual(closed.count, 1, "reconnect after grace keeps the old segment pending")
        t.expectEqual(closed.first?.activeDurationS, 600, "old segment keeps its last observed duration")
        t.expectEqual((closed.first?.activeDurationS ?? 0) + (tracker.openWalkTotals?.activeDurationS ?? 0), 900, "new segment credits only unseen elapsed time")
        t.expectEqual((closed.first?.distanceM ?? 0) + (tracker.openWalkTotals?.distanceM ?? 0), 750, "reconnect does not double-count cumulative distance")
        t.expectEqual((closed.first?.steps ?? 0) + (tracker.openWalkTotals?.steps ?? 0), 1200, "reconnect does not double-count cumulative steps")
        t.check((closed.first?.endedAt ?? .distantFuture) <= (tracker.openWalkTotals?.startedAt ?? .distantPast), "split segments never overlap")
    }
    t.suite("ambiguous raw step register never replaces conserved model totals") { t in
        var tracker = RemoteSessionTracker()
        var initial = frame(60, 15, 25)
        initial.padSteps = 25
        _ = tracker.observe(initial, at: base)
        var stop = initial
        stop.beltRunning = false
        stop.speedKmh = 0
        _ = tracker.observe(stop, at: base.addingTimeInterval(1))
        var resumed = frame(30, 15, 25)
        resumed.padSteps = 25
        _ = tracker.observe(resumed, at: base.addingTimeInterval(31))
        t.expectEqual(tracker.openWalkTotals?.distanceM, 30, "equal counters after elapsed reset are a new distance run")
        t.expectEqual(tracker.openWalkTotals?.steps, 50, "model includes both runs when raw register reset is ambiguous")
        t.expectNil(tracker.openWalkTotals?.rawPadSteps, "unverified raw register is not labelled measured")
    }
    t.suite("malformed restored metrics remain finite") { t in
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            let restored = CounterRestorePlan.make(savedElapsed: 600, savedDistance: 500,
                                                   savedKcal: invalid, currentElapsed: 660, currentDistance: 550)
            t.expectEqual(restored.totalKcal, 0, "invalid saved calories are discarded")
            t.expectEqual(restored.gapElapsed, 60, "valid counter progress survives invalid calorie recovery")
            var calories = CalorieTracker(weightKg: invalid)
            calories.addSample(speedKmh: 3, elapsedS: 60)
            t.expectEqual(calories.totalKcal, 0, "invalid weight cannot poison the calorie accumulator")
        }
        let malformed = CounterRestorePlan.make(savedElapsed: Int.min, savedDistance: 0,
                                                 savedKcal: 1, currentElapsed: Int.max, currentDistance: 20)
        t.expectEqual(malformed.gapElapsed, 0, "invalid saved counters are rejected before subtraction")
        var calories = CalorieTracker()
        calories.addSample(speedKmh: 3, elapsedS: 60)
        let prior = calories.totalKcal
        for invalid in [Double.nan, .infinity, -.infinity] {
            calories.addSample(speedKmh: invalid, elapsedS: 60)
            calories.addSample(speedKmh: 3, elapsedS: invalid)
        }
        t.expectEqual(calories.totalKcal, prior, "non-finite samples cannot poison later normal walking")
        t.expectEqual(GaitModel.steps(distanceM: Int.max, speedKmh: 1), Int.max, "extreme restored distance saturates instead of trapping")
        t.check(GaitModel.stepLengthM(speedKmh: .nan).isFinite, "invalid speed retains finite step length")
        var steps = StepCounter()
        steps.strideM = .nan
        steps.ingest(reportedSteps: 10, distanceM: 10)
        steps.ingest(reportedSteps: 11, distanceM: 11)
        t.check(steps.steps.isFinite && steps.steps > 10, "invalid stride uses a finite fallback")
    }
    t.suite("pending duplicate requires durable repaired history") { t in
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("z1-duplicate-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.json")
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(frame(600, 300, 500), at: base, newSessionID: { "retained" })
        _ = tracker.observe(frame(600, 300, 500, running: false), at: base.addingTimeInterval(1))
        guard let walk = tracker.finalizeIfDue(at: base.addingTimeInterval(121)).completed.first else {
            t.check(false, "fixture retains completed walk"); return
        }
        let store = SessionStore(url: url)
        t.check(store.append(WalkSession(id: walk.id, startedAt: walk.startedAt, endedAt: walk.endedAt,
                                        activeDurationS: walk.activeDurationS, distanceM: walk.distanceM,
                                        steps: walk.steps, caloriesKcal: 30, exportedToHealth: false)), "fixture persists history")
        do {
            try FileManager.default.removeItem(at: url)
            // A directory at the file path makes atomic history writes fail.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            store.reload()
            t.check(store.contains(id: walk.id), "damaged reload retains known session in memory")
            t.check(!store.record(walk, weightKg: 75, tracker: &tracker), "memory-only duplicate cannot acknowledge failed history repair")
            t.check(tracker.hasPendingLogs, "failed duplicate repair preserves durable pending tracker copy")
            try FileManager.default.removeItem(at: url)
            t.check(store.record(walk, weightKg: 75, tracker: &tracker), "duplicate can be acknowledged after repair succeeds")
            t.check(!tracker.hasPendingLogs, "successful repair drains pending copy")
            t.expectEqual(SessionStore(url: url).sessions.map(\.id), [walk.id], "repaired primary survives a new process")
        } catch { t.check(false, "duplicate repair fixture: \(error)") }
    }
    t.suite("partial history corruption recovers missing backup IDs") { t in
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("z1-partial-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.json")
        func saved(_ id: String, distance: Int) -> WalkSession {
            WalkSession(id: id, startedAt: base, endedAt: base.addingTimeInterval(600), activeDurationS: 600,
                        distanceM: distance, steps: distance * 2, caloriesKcal: 30, exportedToHealth: false)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let backupBytes = try encoder.encode([saved("readable", distance: 200), saved("recoverable", distance: 300)])
            let backup = folder.appendingPathComponent("sessions.json.bak")
            try backupBytes.write(to: backup)
            let primaryRow = try JSONSerialization.jsonObject(with: encoder.encode(saved("readable", distance: 250)))
            let damaged = try JSONSerialization.data(withJSONObject: [primaryRow, ["id": "recoverable", "unknown_schema": true]])
            try damaged.write(to: url)
            let store = SessionStore(url: url)
            t.expectEqual(Set(store.sessions.map(\.id)), Set(["readable", "recoverable"]), "partial corruption recovers the unreadable ID from backup")
            t.expectEqual(store.sessions.first { $0.id == "readable" }?.distanceM, 250, "readable primary data wins over older backup")
            t.expectEqual(store.unreadableEntryCount, 1, "recovered history still reports damaged original record")
            t.check(store.append(saved("new", distance: 400)), "recovered history remains writable")
            t.expectEqual(try Data(contentsOf: backup), backupBytes, "immutable original backup remains byte-identical")
            let rescues = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("sessions.unreadable-") }
            t.check(try rescues.contains { try Data(contentsOf: $0) == damaged }, "unknown primary bytes survive in rescue copy")
            t.expectEqual(SessionStore(url: url).sessions.count, 3, "all recovered and new sessions survive reopening")
        } catch { t.check(false, "partial recovery fixture: \(error)") }
    }
    t.suite("daily calories remain finite for malformed history") { t in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: base)
        var totals = DayTotals(day: day)
        func walk(_ calories: Double) -> WalkSession {
            WalkSession(id: "numeric-fixture", startedAt: day, endedAt: day.addingTimeInterval(600),
                        activeDurationS: 600, distanceM: 300, steps: 500, caloriesKcal: calories, exportedToHealth: false)
        }
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            totals.add(walk(invalid), calendar: calendar)
        }
        t.expectEqual(totals.caloriesKcal, 0, "invalid calories do not poison otherwise readable day totals")
        totals.add(walk(.greatestFiniteMagnitude), calendar: calendar)
        totals.add(walk(.greatestFiniteMagnitude), calendar: calendar)
        t.expectEqual(totals.caloriesKcal, Double.greatestFiniteMagnitude, "overflowing finite calories saturate instead of becoming infinity")
    }
}
