import Foundation
import Z1Core

/// Synthetic paths only: never inspect installed history or the iCloud queue.
public func persistenceRegressionTests(_ t: TestRunner) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("z1-persistence-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = Date(timeIntervalSince1970: 2_000_000_000)
    func walk(_ id: String, start: Date, duration: Int = 900) -> WalkSession {
        WalkSession(id: id, startedAt: start, endedAt: start.addingTimeInterval(Double(duration)),
                    activeDurationS: duration, distanceM: duration / 2, steps: duration,
                    caloriesKcal: 40, exportedToHealth: false)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    t.suite("empty history is authoritative") { t in
        let folder = directory.appendingPathComponent("empty")
        let url = folder.appendingPathComponent("sessions.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let old = try encoder.encode([walk("removed", start: base)])
            try old.write(to: url)
            try old.write(to: folder.appendingPathComponent("sessions.json.bak"))
            let store = SessionStore(url: url)
            try Data("[]".utf8).write(to: url)
            store.reload()
            t.check(store.sessions.isEmpty, "empty readable history clears in-memory walks")
            t.check(SessionStore(url: url).sessions.isEmpty, "empty history does not resurrect backup on restart")
            t.check(store.append(walk("new", start: base.addingTimeInterval(3600))), "new walk saves after intentional clear")
            t.expectEqual(SessionStore(url: url).sessions.map(\.id), ["new"], "only the new walk is retained")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.removeItem(at: folder.appendingPathComponent("sessions.json.bak"))
            store.reload()
            t.expectEqual(store.sessions.map(\.id), ["new"], "missing file does not erase history held in memory")
        } catch { t.check(false, "empty history fixture: \(error)") }
    }

    t.suite("legacy envelope preserves unreadable records") { t in
        let folder = directory.appendingPathComponent("envelope")
        let url = folder.appendingPathComponent("sessions.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let valid = try JSONSerialization.jsonObject(with: encoder.encode(walk("readable", start: base)))
            let bytes = try JSONSerialization.data(withJSONObject: ["sessions": [valid, ["future_record": true]]])
            try bytes.write(to: url)
            let store = SessionStore(url: url)
            t.expectEqual(store.unreadableEntryCount, 1, "envelope reports unreadable records")
            t.check(store.append(walk("next", start: base.addingTimeInterval(3600))), "readable records remain appendable")
            let rescues = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("sessions.unreadable-") }
            t.expectEqual(rescues.count, 1, "unreadable envelope is rescued before replacement")
            if let rescue = rescues.first {
                t.expectEqual(try Data(contentsOf: rescue), bytes, "rescue preserves exact unknown record bytes")
            }
            // Repeated damage/recovery must not collide with a prior rescue,
            // even if both repairs fall inside the same timestamp second.
            try bytes.write(to: url)
            store.reload()
            t.check(store.append(walk("last", start: base.addingTimeInterval(7200))), "a second rescue does not block saving")
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasPrefix("sessions.unreadable-") }
            t.expectEqual(names.count, 2, "each damaged version gets its own rescue")
        } catch { t.check(false, "envelope fixture: \(error)") }
    }

    t.suite("Health group receipts retain every segment") { t in
        let folder = directory.appendingPathComponent("health")
        let url = folder.appendingPathComponent("health-queue.json")
        let receiptsURL = folder.appendingPathComponent("receipts.json")
        let first = walk("first", start: base)
        let second = walk("second", start: first.endedAt.addingTimeInterval(300))
        let now = second.endedAt.addingTimeInterval(601)
        do {
            let queue = HealthQueue(url: url, receiptsURL: receiptsURL)
            t.expectEqual(try queue.enqueueReadyGroups(sessions: [first, second], now: now, notBefore: base), 1,
                          "two segments publish one workout")
            let published = try Data(contentsOf: url)
            let receipts = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptsURL)) as? [String: Any]
            t.expectEqual(Set(receipts?["queued_session_ids"] as? [String] ?? []), Set([first.id, second.id]),
                          "receipts remember both source segments")
            // Model a crash after publication but before durable receipts.
            try FileManager.default.removeItem(at: receiptsURL)
            t.expectEqual(try queue.enqueueReadyGroups(sessions: [first, second], now: now, notBefore: base), 0,
                          "published group repairs receipts without another workout")
            t.expectEqual(try Data(contentsOf: url), published, "receipt repair leaves phone batch byte-identical")
            try FileManager.default.removeItem(at: url)
            let restarted = HealthQueue(url: url, receiptsURL: receiptsURL)
            t.expectEqual(try restarted.enqueueReadyGroups(sessions: [second], now: now, notBefore: base), 0,
                          "removing the first history segment cannot re-export the second")
            let older = walk("recovered-earlier", start: first.startedAt.addingTimeInterval(-1200))
            t.expectEqual(try restarted.enqueueReadyGroups(sessions: [older, first, second], now: now,
                                                          notBefore: older.startedAt), 0,
                          "a recovered older group leader cannot re-export an already queued group")
        } catch { t.check(false, "Health provenance fixture: \(error)") }
    }

    t.suite("history ranges retain midnight and DST totals") { t in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let dates = ["2026-03-28T22:30:00Z", "2026-03-29T00:30:00Z", "2026-10-24T21:30:00Z", "2026-10-25T00:30:00Z"]
        let iso = ISO8601DateFormatter()
        let sessions = dates.enumerated().map { walk("dst-\($0.offset)", start: iso.date(from: $0.element)!, duration: 10800) }
        let folder = directory.appendingPathComponent("days")
        let url = folder.appendingPathComponent("sessions.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(sessions).write(to: url)
            let store = SessionStore(url: url)
            for start in [sessions[0].startedAt, sessions[2].startedAt] {
                let end = calendar.date(byAdding: .day, value: 3, to: start)!
                let days = store.days(from: start, through: end, calendar: calendar)
                t.expectEqual(days.count, 4, "range includes empty and occupied calendar days")
                for day in days {
                    t.expectEqual(day, store.totals(on: day.day, calendar: calendar),
                                  "optimized range agrees with independent day aggregation across DST")
                }
            }
        } catch { t.check(false, "calendar history fixture: \(error)") }
    }
}
