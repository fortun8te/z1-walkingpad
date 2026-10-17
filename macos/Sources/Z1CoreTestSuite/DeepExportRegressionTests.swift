import Foundation
import Z1Core

/// Synthetic files only; never loads installed history or the phone queue.
public func deepExportRegressionTests(_ t: TestRunner) async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("z1-deep-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = Date(timeIntervalSince1970: 2_000_000_000)
    func walk(_ id: String, start: Date, duration: Int = 900, distance: Int = 450, steps: Int = 900) -> WalkSession {
        WalkSession(id: id, startedAt: start, endedAt: start.addingTimeInterval(900),
                    activeDurationS: duration, distanceM: distance, steps: steps,
                    caloriesKcal: 40, exportedToHealth: false)
    }

    t.suite("duplicate history IDs preserve one segment and original bytes") { t in
        let folder = directory.appendingPathComponent("duplicates")
        let url = folder.appendingPathComponent("sessions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = walk("one", start: base)
            let bytes = try encoder.encode([first, first])
            try bytes.write(to: url)
            let store = SessionStore(url: url)
            t.expectEqual(store.sessions.count, 1, "a repeated ID is counted once")
            t.expectEqual(store.unreadableEntryCount, 1, "duplicate requires rescue before replacing history")
            t.expectEqual(store.totals(on: base).distanceM, 450, "duplicate cannot inflate daily distance")
            t.check(store.append(walk("two", start: base.addingTimeInterval(3600))), "new walk remains saveable")
            let rescues = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("sessions.unreadable-") }
            t.expectEqual(rescues.count, 1, "duplicate source is rescued")
            if let rescue = rescues.first { t.expectEqual(try Data(contentsOf: rescue), bytes, "rescue retains exact source bytes") }
            t.expectEqual(SessionStore(url: url).sessions.map(\.id), ["one", "two"], "deduplicated history survives restart")
        } catch { t.check(false, "duplicate fixture: \(error)") }
    }

    t.suite("oversized saved counters cannot crash daily totals") { t in
        var totals = DayTotals(day: Calendar.current.startOfDay(for: base))
        totals.add(walk("oversized", start: base, duration: Int.max, distance: Int.max, steps: Int.max))
        t.expectEqual(totals.steps, Int.max, "unrepresentable Double rounding remains bounded")
        totals.add(walk("next", start: base.addingTimeInterval(1200)))
        t.expectEqual(totals.steps, Int.max, "aggregate overflow remains bounded")
        t.expectEqual(totals.activeDurationS, Int.max, "oversized duration cannot overflow")
        t.expectEqual(totals.distanceM, Int.max, "oversized distance cannot overflow")
        let before = totals
        totals.add(walk("negative", start: base, distance: -1))
        t.expectEqual(totals, before, "negative corrupt counters cannot subtract from totals")
    }

    t.suite("Health grouping safely rejects corrupt counters") { t in
        do {
            let valid = walk("valid", start: base.addingTimeInterval(1200))
            for (name, invalid) in [
                ("duration", walk("bad", start: base, duration: Int.max)),
                ("distance", walk("bad", start: base, distance: Int.max)),
                ("steps", walk("bad", start: base, steps: Int.max)),
                ("negative", walk("bad", start: base, distance: -1))
            ] {
                let url = directory.appendingPathComponent(name).appendingPathComponent("queue.json")
                let queue = HealthQueue(url: url)
                t.expectEqual(try queue.enqueueReadyGroups(sessions: [invalid, valid], now: base.addingTimeInterval(3600), notBefore: base), 0,
                              "\(name) cannot crash or contaminate a group")
                t.check(!FileManager.default.fileExists(atPath: url.path), "\(name) does not publish a partial group")
                t.expectEqual(try queue.enqueueReadyGroups(sessions: [valid], now: base.addingTimeInterval(3600), notBefore: base), 1,
                              "\(name) does not consume a valid segment receipt")
            }
        } catch { t.check(false, "corrupt group fixture: \(error)") }
    }

    t.suite("Health grouping cannot hide an invalid constituent") { t in
        let first = walk("first", start: base)
        func segment(_ id: String, end: TimeInterval, duration: Int, distance: Int) -> WalkSession {
            WalkSession(id: id, startedAt: base.addingTimeInterval(1200), endedAt: base.addingTimeInterval(end),
                        activeDurationS: duration, distanceM: distance, steps: 200, caloriesKcal: 10, exportedToHealth: false)
        }
        let invalid = [
            segment("", end: 1500, duration: 300, distance: 150),
            segment("reversed", end: 1100, duration: 60, distance: 20),
            segment("duration", end: 1500, duration: 400, distance: 100),
            segment("pace", end: 1320, duration: 120, distance: 400)
        ]
        do {
            for (index, item) in invalid.enumerated() {
                let url = directory.appendingPathComponent("segment-\(index)/queue.json")
                let queue = HealthQueue(url: url)
                t.expectEqual(try queue.enqueueReadyGroups(sessions: [first, item], now: base.addingTimeInterval(3000), notBefore: base), 0,
                              "invalid constituent \(index) cannot hide inside valid combined totals")
                t.check(!FileManager.default.fileExists(atPath: url.path), "invalid constituent \(index) leaves no published batch")
                t.expectEqual(try queue.enqueueReadyGroups(sessions: [first], now: base.addingTimeInterval(3000), notBefore: base), 1,
                              "invalid constituent \(index) does not consume neighboring valid receipt")
            }
        } catch { t.check(false, "constituent fixture: \(error)") }
    }

    t.suite("workout and step sample share the same serialized window") { t in
        let url = directory.appendingPathComponent("fractional-window/queue.json")
        let session = WalkSession(id: "fractional", startedAt: base.addingTimeInterval(0.9),
                                  endedAt: base.addingTimeInterval(901.1), activeDurationS: 900,
                                  distanceM: 450, steps: 900, caloriesKcal: 40, exportedToHealth: false)
        do {
            t.check(try HealthQueue(url: url).enqueue(session), "fractional timestamps publish")
            let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let item = (fields?["workouts"] as? [[String: Any]])?.first
            let format = ISO8601DateFormatter()
            guard let start = (item?["started_at"] as? String).flatMap(format.date(from:)),
                  let end = (item?["ended_at"] as? String).flatMap(format.date(from:)),
                  let minutes = item?["wall_duration_min"] as? Double else {
                t.check(false, "serialized workout window is readable")
                return
            }
            t.expectEqual(item?["wall_duration_s"] as? Int, Int(end.timeIntervalSince(start)), "seconds match serialized dates")
            t.expectEqual(start.addingTimeInterval(minutes * 60).timeIntervalSince(end), 0, accuracy: 0.000001,
                          "Shortcut workout duration reaches exactly the step sample end")
        } catch { t.check(false, "fractional window fixture: \(error)") }
    }

    t.suite("malformed Health schema versions remain untouched") { t in
        do {
            let folder = directory.appendingPathComponent("versions")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("queue.json")
            let receipts = folder.appendingPathComponent("receipts.json")
            let fractional = Data(#"{"schema_version":2.5,"workouts":[]}"#.utf8)
            try fractional.write(to: url)
            let queue = HealthQueue(url: url, receiptsURL: receipts)
            do { _ = try queue.queuedSessionIDs(); t.check(false, "fractional queue schema must fail") }
            catch { t.check(true, "fractional queue schema fails") }
            t.expectEqual(try Data(contentsOf: url), fractional, "unknown queue schema stays untouched")
            try FileManager.default.removeItem(at: url)
            for version in ["true", "1.5"] {
                let bytes = Data("{\"schema_version\":\(version),\"queued_session_ids\":[]}".utf8)
                try bytes.write(to: receipts)
                do { _ = try queue.enqueue(walk("valid", start: base)); t.check(false, "receipt version \(version) must fail") }
                catch { t.check(true, "receipt version \(version) fails") }
                t.expectEqual(try Data(contentsOf: receipts), bytes, "malformed receipts remain untouched")
                t.check(!FileManager.default.fileExists(atPath: url.path), "bad receipts prevent publication")
            }
        } catch { t.check(false, "schema fixture: \(error)") }
    }

    let liveChecks: [(Bool, String)] = await MainActor.run {
        let url = directory.appendingPathComponent("live.json")
        let writer = LiveExport(url: url)
        var checks: [(Bool, String)] = []
        var status = Z1Treadmill.Status()
        status.phase = .ready
        status.beltRunning = true
        status.speedKmh = .infinity
        let today = DayTotals(day: base)
        do {
            checks.append((try writer.publish(status: status, today: today, goalProgress: 0, at: base), "invalid speed does not block live publication"))
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            checks.append((json?["speedKmh"] as? Double == 0, "invalid speed is normalized"))
            status.speedKmh = 3
            checks.append((try writer.publish(status: status, today: today, goalProgress: 0, at: base.addingTimeInterval(-3600)), "backward clock publishes immediately"))
            checks.append((try !writer.publish(status: status, today: today, goalProgress: 0, at: base.addingTimeInterval(-3599)), "new clock still respects heartbeat"))
            checks.append((try writer.publish(status: status, today: today, goalProgress: 0, at: base.addingTimeInterval(-3595)), "heartbeat resumes from corrected clock"))
        } catch { checks.append((false, "live export fixture: \(error)")) }
        return checks
    }
    t.suite("live export survives invalid speed and wall-clock reversal") { t in
        for (passed, description) in liveChecks { t.check(passed, description) }
    }
}
