import Foundation
import Z1Core

/// Frame building/parsing tests (mirrors the Python test vectors).
public func protocolTests(_ t: TestRunner) {
    t.suite("protocol") { t in
        // Verified on hardware: KS-HD-Z1D -> 71 00 05 01 2e 5a 31 44 74
        t.expectEqual(
            Z1Protocol.unlockFrame(deviceName: "KS-HD-Z1D"),
            Data([0x71, 0x00, 0x05, 0x01, 0x2E, 0x5A, 0x31, 0x44, 0x74]),
            "unlock frame known vector"
        )

        // checksum roundtrip
        let payload = Data([0x01, 0x02, 0x03, 0xFF])
        let frame = Z1Protocol.buildFrame(cmd0: 0x72, cmd1: 0x01, data: payload)
        t.expectEqual(frame.count, 3 + payload.count + 1, "frame length")
        let parsed = Z1Protocol.parseFrame(frame)
        t.expectEqual(parsed?.cmd0, 0x72, "roundtrip cmd0")
        t.expectEqual(parsed?.cmd1, 0x01, "roundtrip cmd1")
        t.expectEqual(parsed?.data, payload, "roundtrip data")

        // bad checksum rejected
        var corrupted = Z1Protocol.buildFrame(cmd0: 0x72, cmd1: 0x00, data: Data([0x00]))
        corrupted[corrupted.count - 1] ^= 0xFF
        t.expectEqual(Z1Protocol.parseFrame(corrupted)?.cmd0, nil, "bad checksum rejected")

        // malformed frames rejected
        t.expectEqual(Z1Protocol.parseFrame(Data([0x71, 0x80]))?.cmd0, nil, "short frame rejected")
        t.expectEqual(
            Z1Protocol.parseFrame(Data([0x71, 0x80, 0x02, 0x00]))?.cmd0, nil,
            "truncated body rejected"
        )

        // spec vector: SETTING_GET (all) = 72 00 01 00 73
        t.expectEqual(
            Z1Protocol.settingGetFrame(),
            Data([0x72, 0x00, 0x01, 0x00, 0x73]),
            "SETTING_GET all vector"
        )

        // SYS_INFO frame roundtrip
        let sysinfo = Z1Protocol.parseFrame(Z1Protocol.sysInfoFrame(unixTime: 0, userID: 0))
        t.expectEqual(sysinfo?.cmd0, 0x71, "sysinfo cmd0")
        t.expectEqual(sysinfo?.cmd1, 0x01, "sysinfo cmd1")
        t.expectEqual(sysinfo?.data, Data(count: 8), "sysinfo 8-byte payload")

        // property records [id, error, lo, hi]; error != 0 skipped
        let records = Data([0x01, 0x00, 0x03, 0x00, 0x05, 0x01, 0x09, 0x00, 0x04, 0x00, 0x05, 0x00])
        let props = Z1Protocol.parsePropertyRecords(records)
        t.expectEqual(props[1], 3, "property 1 parsed")
        t.expectEqual(props[4], 5, "property 4 parsed")
        t.expectNil(props[5], "error record skipped")

        // spec telemetry vector: 04 24 fa 00 00 00 00 02 00 00 00
        let raw = Data([0x04, 0x24, 0xFA, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        let d = Z1Protocol.parseTreadmillData(raw)
        t.expectEqual(d.speedKmh, 2.5, "vector speed")
        t.expectEqual(d.distanceM, 0, "vector distance")
        t.expectEqual(d.elapsedS, 2, "vector elapsed")
        t.expectEqual(d.steps, 0, "vector steps")

        // u24 distance + all fields
        let full = Data([
            0x04, 0x24,
            0x80, 0x02, // speed 640 -> 6.4 km/h
            0x34, 0x12, 0x00, // distance u24 = 4660 m
            0x3C, 0x00, // elapsed 60 s
            0x41, 0x01, // steps 321
        ])
        let f = Z1Protocol.parseTreadmillData(full)
        t.expectEqual(f.speedKmh, 6.4, "full speed")
        t.expectEqual(f.distanceM, 4660, "full distance (u24)")
        t.expectEqual(f.elapsedS, 60, "full elapsed")
        t.expectEqual(f.steps, 321, "full steps")

        // truncated telemetry
        t.expectNil(Z1Protocol.parseTreadmillData(Data()).speedKmh, "empty telemetry")
        t.expectNil(Z1Protocol.parseTreadmillData(Data([0x04])).speedKmh, "1-byte telemetry")
    }
}

/// MET table / calorie math tests.
public func metricsTests(_ t: TestRunner) {
    t.suite("metrics") { t in
        t.expectEqual(Z1Metrics.vo2ForSpeed(0.0), 3.5, accuracy: 1e-12, "VO2 at rest is 1 MET")
        // ACSM level-walking: VO2 = 0.1 * (km/h * 1000/60) + 3.5
        // 3.2 km/h = 53.33 m/min -> VO2 8.833
        t.expectEqual(Z1Metrics.vo2ForSpeed(3.2), 8.833, accuracy: 0.001, "VO2 at 3.2 km/h")
        // 6.4 km/h = 106.67 m/min -> VO2 14.167
        t.expectEqual(Z1Metrics.vo2ForSpeed(6.4), 14.167, accuracy: 0.001, "VO2 at max speed")
        t.expectEqual(Z1Metrics.vo2ForSpeed(-1), 3.5, accuracy: 1e-12, "negative speed clamps to resting")

        // 8.833 * 75 / 200 = 3.3125
        t.expectEqual(Z1Metrics.kcalPerMinute(3.2, weightKg: 75), 3.3125, accuracy: 0.001, "kcal/min known vector")

        var tracker = CalorieTracker(weightKg: 75)
        tracker.addSample(speedKmh: 3.2, elapsedS: 60)
        t.expectEqual(tracker.totalKcal, 3.3125, accuracy: 0.001, "tracker one minute")
        tracker.addSample(speedKmh: 3.2, elapsedS: 0)
        tracker.addSample(speedKmh: 3.2, elapsedS: -5)
        t.expectEqual(tracker.totalKcal, 3.3125, accuracy: 0.001, "tracker ignores non-positive intervals")
        tracker.addSample(speedKmh: 3.2, elapsedS: 60)
        t.expectEqual(tracker.totalKcal, 6.625, accuracy: 0.001, "tracker two minutes")
        tracker.reset()
        t.expectEqual(tracker.totalKcal, 0.0, accuracy: 1e-12, "tracker reset")

        var heavy = CalorieTracker(weightKg: 75)
        heavy.weightKg = 150
        heavy.addSample(speedKmh: 3.2, elapsedS: 60)
        t.expectEqual(heavy.totalKcal, 6.625, accuracy: 0.001, "double weight -> double burn")
    }
}

/// Unit conversion + display-units property-bit tests.
public func unitsTests(_ t: TestRunner) {
    t.suite("units") { t in
        t.expectEqual(Z1Units.kmhToMph(6.4), 3.98, accuracy: 0.005, "6.4 km/h -> 3.98 mph")
        t.expectEqual(Z1Units.mphToKmh(3.98), 6.4, accuracy: 0.01, "3.98 mph -> ~6.4 km/h")
        t.check(
            abs(Z1Units.mphToKmh(Z1Units.kmhToMph(4.2)) - 4.2) < 1e-9,
            "mph<->km/h roundtrip"
        )

        t.expectEqual(Z1Units.metersToMiles(1609), 1.0, accuracy: 0.001, "1609 m -> 1.0 mi")
        t.expectEqual(Z1Units.metersToFeet(100), 328.084, accuracy: 0.001, "100 m -> 328 ft")

        // property 1, bit 0x0002: set = miles, clear = km; other bits preserved
        // (docs/protocol.md property table; hardware unit reports 0x0003)
        t.expectEqual(Z1Units.displayUnitsValue(current: 0x0003, imperial: true), 0x0003, "bit set keeps miles")
        t.expectEqual(Z1Units.displayUnitsValue(current: 0x0003, imperial: false), 0x0001, "bit clear -> km, bit0 preserved")
        t.expectEqual(Z1Units.displayUnitsValue(current: 0x0001, imperial: true), 0x0003, "km -> miles, bit0 preserved")
        t.expectEqual(Z1Units.displayUnitsValue(current: 0, imperial: true), 0x0002, "absent property defaults to 0")
        t.check(Z1Units.propertyIndicatesImperial(0x0003), "0x0003 indicates imperial")
        t.check(!Z1Units.propertyIndicatesImperial(0x0001), "0x0001 indicates metric")

        // property write frame vector: 72 01 03 01 <lo> <hi> CC
        t.expectEqual(
            Z1Protocol.propertyWriteFrame(propID: 1, value: 0x0003),
            Data([0x72, 0x01, 0x03, 0x01, 0x03, 0x00, 0x7A]),
            "property-1 write frame vector"
        )
    }
}

/// A frame the flags promise more bytes for than it carries is dropped whole.
public func truncatedTelemetryTests(_ t: TestRunner) {
    t.suite("truncated telemetry") { t in
        // Flags promise steps but the bytes end early: the whole frame must
        // drop (all nil), never decode as zeros that read as a counter reset.
        let truncated = Data([0x04, 0x24, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00])
        let parsed = Z1Protocol.parseTreadmillData(truncated)
        t.check(parsed.steps == nil, "truncated frame drops steps")
        t.check(parsed.distanceM == nil, "truncated frame drops distance")
        t.check(parsed.speedKmh == nil, "truncated frame drops speed")
    }
}

/// The modelled step total only ever grows within a run.
public func stepCounterTests(_ t: TestRunner) {
    t.suite("step-counter") { t in
        var counter = StepCounter()
        counter.strideM = 0.68
        counter.ingest(reportedSteps: 4_489, distanceM: 2_900)
        t.expectEqual(counter.steps, 4_489, accuracy: 1e-9, "the first packet is taken as it is")
        let before = counter.steps
        // Recalculating the entire walk at a new speed used to report 4,317
        // and visibly run the counter backwards.
        counter.ingest(reportedSteps: 4_317, distanceM: 2_901)
        t.check(counter.steps >= before, "speed changes never make steps go backwards")
        t.expectEqual(counter.steps, before + 1 / 0.68, accuracy: 1e-9, "one new metre adds one metre of steps")
        let afterMetre = counter.steps
        counter.ingest(reportedSteps: 4_317, distanceM: 2_901)
        t.expectEqual(counter.steps, afterMetre, accuracy: 1e-9, "a duplicate packet adds nothing")
        counter.ingest(reportedSteps: 10, distanceM: 6)
        t.expectEqual(counter.steps, 10, accuracy: 1e-9, "a counter reset starts the new run from the pad's count")
        counter.reset()
        t.expectEqual(counter.steps, 0, accuracy: 1e-9, "reset clears the run")
    }
}

/// Belt-run tracking: segments, stop grace, drops and relaunch recovery.
public func remoteSessionTrackerTests(_ t: TestRunner) {
    t.suite("remote-session-tracker") { t in
        func status(
            running: Bool,
            elapsed: Int,
            distance: Int,
            steps: Int,
            hasTelemetry: Bool = true
        ) -> Z1Treadmill.Status {
            var value = Z1Treadmill.Status()
            value.phase = .ready
            value.hasTelemetry = hasTelemetry
            value.beltRunning = running
            value.speedKmh = running ? 3.2 : 0
            value.elapsedS = elapsed
            value.distanceM = distance
            value.steps = steps
            return value
        }

        let grace = RemoteSessionTracker.stopGraceSeconds
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        var tracker = RemoteSessionTracker()

        // Establish a stopped baseline so stale pad totals are not imported.
        _ = tracker.observe(status(running: false, elapsed: 100, distance: 50, steps: 70), at: base)
        _ = tracker.observe(
            status(running: true, elapsed: 101, distance: 51, steps: 72),
            at: base.addingTimeInterval(1),
            newSessionID: { "remote-session-1" }
        )
        _ = tracker.observe(
            status(running: true, elapsed: 700, distance: 550, steps: 900),
            at: base.addingTimeInterval(600)
        )
        let stoppedAt = base.addingTimeInterval(601)
        let stopped = tracker.observe(
            status(running: false, elapsed: 700, distance: 550, steps: 900),
            at: stoppedAt
        )
        t.expectEqual(
            stopped.finalizationDeadline,
            stoppedAt.addingTimeInterval(grace),
            "remote Stop sets the grace deadline"
        )

        // More zero-speed frames do not move the deadline.
        let repeatedZero = tracker.observe(
            status(running: false, elapsed: 700, distance: 550, steps: 900),
            at: stoppedAt.addingTimeInterval(60)
        )
        t.expectEqual(
            repeatedZero.finalizationDeadline,
            stoppedAt.addingTimeInterval(grace),
            "repeated zero telemetry does not extend grace"
        )

        // Restart one second before expiry. Reset counters are folded into the
        // same session instead of finalizing a second workout.
        let resumed = tracker.observe(
            status(running: true, elapsed: 1, distance: 1, steps: 2),
            at: stoppedAt.addingTimeInterval(grace - 1)
        )
        t.expectNil(resumed.finalizationDeadline, "restart within grace cancels finalization")
        t.check(resumed.completed.isEmpty, "restart within grace does not log a walk")
        _ = tracker.observe(
            status(running: true, elapsed: 301, distance: 201, steps: 450),
            at: stoppedAt.addingTimeInterval(899)
        )
        let finalStop = stoppedAt.addingTimeInterval(900)
        _ = tracker.observe(
            status(running: false, elapsed: 301, distance: 201, steps: 450),
            at: finalStop
        )
        t.check(
            tracker.finalizeIfDue(at: finalStop.addingTimeInterval(grace - 1)).completed.isEmpty,
            "session is not logged early"
        )
        let due = tracker.finalizeIfDue(at: finalStop.addingTimeInterval(grace))
        t.expectEqual(due.completed.count, 1, "one merged workout is offered to the history")
        if let walk = due.completed.first {
            t.expectEqual(walk.id, "remote-session-1", "history entry shares the session ID")
            t.expectEqual(walk.activeDurationS, 901, "active time excludes the break")
            t.expectEqual(walk.distanceM, 701, "distance spans both walking segments")
            tracker.acknowledgeLog(sessionID: walk.id)
        }
        t.check(
            tracker.finalizeIfDue(at: finalStop.addingTimeInterval(grace)).completed.isEmpty,
            "an acknowledged history entry is not offered twice"
        )

        // Display interpolation ticks up, then the next packet snaps back a
        // couple of steps. That is not a pad reset — Today must not gain
        // the whole counter.
        var snap = RemoteSessionTracker()
        _ = snap.observe(status(running: false, elapsed: 0, distance: 0, steps: 0), at: base)
        _ = snap.observe(
            status(running: true, elapsed: 60, distance: 50, steps: 80),
            at: base.addingTimeInterval(60),
            newSessionID: { "snap-walk" }
        )
        _ = snap.observe(
            status(running: true, elapsed: 61, distance: 51, steps: 83),
            at: base.addingTimeInterval(61)
        )
        _ = snap.observe(
            status(running: true, elapsed: 62, distance: 52, steps: 81),
            at: base.addingTimeInterval(62)
        )
        t.expectEqual(snap.openWalkTotals?.steps, 81, "open-walk steps follow the pad session count")
        t.check((snap.openWalkTotals?.steps ?? 0) < 150, "must not add the live counter on a 2-step dip")

        // The estimated live count is recomputed when speed changes, so it
        // can move by far more than the interpolator's 1-3 step snap. For a
        // single pad-counter run, Today must still equal the live card.
        var speedChange = RemoteSessionTracker()
        _ = speedChange.observe(
            status(running: true, elapsed: 3_000, distance: 2_900, steps: 4_489),
            at: base,
            newSessionID: { "speed-change-walk" }
        )
        _ = speedChange.observe(
            status(running: true, elapsed: 3_001, distance: 2_901, steps: 4_317),
            at: base.addingTimeInterval(1)
        )
        t.expectEqual(speedChange.openWalkTotals?.steps, 4_317, "one walk uses the same live step estimate in both cards")
        if let open = speedChange.openWalkTotals {
            let today = WalkDisplayTotals.addingTrackedWalks(
                to: DayTotals(day: base), savedSessionIDs: [], tracker: speedChange, weightKg: 74
            )
            t.expectEqual(open.steps, 4_317, "the open walk keeps its step estimate")
            t.expectEqual(today.steps, 4_317, "Today card preserves the open walk step estimate")
        } else {
            t.check(false, "speed-change walk remains open")
        }

        // Already-inflated tracker (from the old interpolator) heals on the
        // next live frame of the same walk.
        var inflated = RemoteSessionTracker()
        _ = inflated.observe(status(running: false, elapsed: 0, distance: 0, steps: 0), at: base)
        _ = inflated.observe(
            status(running: true, elapsed: 100, distance: 80, steps: 20_000),
            at: base.addingTimeInterval(100),
            newSessionID: { "inflated-walk" }
        )
        _ = inflated.observe(
            status(running: true, elapsed: 101, distance: 81, steps: 2_278),
            at: base.addingTimeInterval(101)
        )
        t.expectEqual(
            inflated.openWalkTotals?.steps,
            2_278,
            "runaway session snaps to the live pad count"
        )

        var drop = RemoteSessionTracker()
        _ = drop.observe(
            status(running: true, elapsed: 100, distance: 80, steps: 120),
            at: base,
            newSessionID: { "drop-walk" }
        )
        _ = drop.observe(
            status(running: false, elapsed: 100, distance: 80, steps: 120),
            at: base.addingTimeInterval(100)
        )
        t.check(drop.finalizationDeadline != nil, "stop starts grace")
        let droppedAt = base.addingTimeInterval(100)
        drop.markConnectionDrop(at: droppedAt)
        t.expectEqual(
            drop.finalizationDeadline,
            droppedAt.addingTimeInterval(grace),
            "BLE drop starts a bounded segment deadline"
        )
        t.check(drop.openWalkTotals != nil, "walk stays open across a drop")
        t.expectEqual(
            drop.finalizeIfDue(at: droppedAt.addingTimeInterval(grace)).completed.first?.id,
            "drop-walk",
            "unrecovered drop eventually logs the walk"
        )

        var movingDrop = RemoteSessionTracker()
        _ = movingDrop.observe(
            status(running: true, elapsed: 180, distance: 140, steps: 220),
            at: base,
            newSessionID: { "moving-drop" }
        )
        movingDrop.markConnectionDrop(at: base.addingTimeInterval(1))
        t.expectEqual(
            movingDrop.finalizeIfDue(at: base.addingTimeInterval(1 + grace)).completed.first?.id,
            "moving-drop",
            "lost link while belt was moving also finalizes"
        )

        // A pending stopped session survives relaunch and keeps the original
        // deadline and ID.
        var persisted = RemoteSessionTracker()
        _ = persisted.observe(
            status(running: true, elapsed: 600, distance: 500, steps: 700),
            at: base,
            newSessionID: { "persisted-session" }
        )
        _ = persisted.observe(
            status(running: false, elapsed: 600, distance: 500, steps: 700),
            at: base.addingTimeInterval(600)
        )
        do {
            let data = try JSONEncoder().encode(persisted)
            var restored = try JSONDecoder().decode(RemoteSessionTracker.self, from: data)
            let restoredDue = restored.finalizeIfDue(at: base.addingTimeInterval(600) + grace)
            t.expectEqual(restoredDue.completed.first?.id, "persisted-session", "relaunch restores pending session")
        } catch {
            t.check(false, "tracker persistence roundtrip: \(error)")
        }
    }
}

/// Walks too small for Apple Health must still reach the local history, and
/// state written by an older build must keep decoding.
func historyAndCompatibilityTests(_ t: TestRunner) {
    t.suite("short walks + tracker compatibility") { t in
        func status(running: Bool, elapsed: Int, distance: Int, steps: Int) -> Z1Treadmill.Status {
            var value = Z1Treadmill.Status()
            value.phase = .ready
            value.hasTelemetry = true
            value.beltRunning = running
            value.speedKmh = running ? 3.2 : 0
            value.elapsedS = elapsed
            value.distanceM = distance
            value.steps = steps
            return value
        }

        // A five-minute walk: below Health's ten-minute floor, above the
        // history's one-minute noise floor.
        let base = Date(timeIntervalSince1970: 2_100_000_000)
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(status(running: false, elapsed: 0, distance: 0, steps: 0), at: base)
        _ = tracker.observe(
            status(running: true, elapsed: 1, distance: 1, steps: 2),
            at: base.addingTimeInterval(1),
            newSessionID: { "short-walk" }
        )
        _ = tracker.observe(
            status(running: true, elapsed: 300, distance: 260, steps: 400),
            at: base.addingTimeInterval(300)
        )
        let stopped = base.addingTimeInterval(301)
        _ = tracker.observe(status(running: false, elapsed: 300, distance: 260, steps: 400), at: stopped)
        let due = tracker.finalizeIfDue(at: stopped.addingTimeInterval(RemoteSessionTracker.stopGraceSeconds))
        t.expectEqual(due.completed.count, 1, "a five-minute walk still reaches the history")

        // A ten-second nudge of the belt is noise, not a walk.
        var noise = RemoteSessionTracker()
        _ = noise.observe(status(running: false, elapsed: 0, distance: 0, steps: 0), at: base)
        _ = noise.observe(
            status(running: true, elapsed: 1, distance: 1, steps: 1),
            at: base.addingTimeInterval(1),
            newSessionID: { "nudge" }
        )
        _ = noise.observe(
            status(running: false, elapsed: 10, distance: 8, steps: 12),
            at: base.addingTimeInterval(10)
        )
        t.check(
            noise.finalizeIfDue(at: base.addingTimeInterval(RemoteSessionTracker.stopGraceSeconds + 60)).completed.isEmpty,
            "a ten-second belt nudge is not recorded as a walk"
        )

        // State saved before the history queue existed must still decode,
        // rather than resetting the tracker and losing a walk in flight.
        let legacyState: [String: Any] = [
            "pendingSessions": [],
            "idleCounters": ["elapsedS": 5, "distanceM": 4, "steps": 3],
        ]
        if let legacy = try? JSONSerialization.data(withJSONObject: legacyState),
           let restored = try? JSONDecoder().decode(RemoteSessionTracker.self, from: legacy)
        {
            t.check(!restored.hasPendingLogs, "legacy state decodes with an empty history queue")
        } else {
            t.check(false, "state saved by an older build must still decode")
        }
    }
}

/// The on-disk walk history.
func sessionStoreTests(_ t: TestRunner) {
    t.suite("session store") { t in
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("z1-history-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 2_000_000_000)

        func walk(_ id: String, at start: Date, minutes: Int, meters: Int, steps: Int) -> WalkSession {
            WalkSession(
                id: id,
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(minutes) * 60),
                activeDurationS: minutes * 60,
                distanceM: meters,
                steps: steps,
                caloriesKcal: 100,
                exportedToHealth: true
            )
        }

        let store = SessionStore(url: temp)
        t.check(store.append(walk("a", at: noon, minutes: 30, meters: 2_000, steps: 3_000)), "first walk stored")
        t.check(
            !store.append(walk("a", at: noon, minutes: 30, meters: 2_000, steps: 3_000)),
            "the same walk is never stored twice"
        )
        t.check(
            store.append(walk("b", at: noon.addingTimeInterval(4 * 3_600), minutes: 15, meters: 1_000, steps: 1_500)),
            "a second walk on the same day is stored"
        )
        _ = store.append(walk("c", at: noon.addingTimeInterval(-86_400), minutes: 20, meters: 1_400, steps: 2_000))

        let today = store.totals(on: noon, calendar: calendar)
        t.expectEqual(today.walks, 2, "today counts both of today's walks")
        t.expectEqual(today.activeDurationS, 45 * 60, "today sums active time")
        t.expectEqual(today.distanceM, 3_000, "today sums distance")
        t.expectEqual(today.steps, 4_500, "today preserves recorded step counts")

        let span = store.days(
            from: calendar.date(byAdding: .day, value: -1, to: noon)!,
            through: noon,
            calendar: calendar
        )
        t.expectEqual(span.count, 2, "inclusive day range")
        t.expectEqual(span.last?.walks, 2, "range end is today")

        let week = store.days(
            from: calendar.date(byAdding: .day, value: -6, to: noon)!,
            through: noon,
            calendar: calendar
        )
        t.expectEqual(week.count, 7, "the week chart always has seven days")
        t.expectEqual(week.last?.walks, 2, "the last bar is today")
        t.check(week.first?.isEmpty == true, "days with no walks are empty, not missing")
        t.expectEqual(week[5].walks, 1, "yesterday keeps its own walk")

        // Reload from disk: the history must survive a relaunch.
        let reopened = SessionStore(url: temp)
        t.expectEqual(reopened.sessions.count, 3, "history is reloaded from disk")
        t.expectEqual(reopened.sessions.last?.id, "b", "history is ordered oldest first")
        t.expectEqual(
            reopened.totals(on: noon, calendar: calendar).distanceM,
            3_000,
            "totals survive a reload"
        )

        t.check(
            store.append(walk("hot", at: noon.addingTimeInterval(7_200), minutes: 27, meters: 1_180, steps: 30_118)),
            "inflated walk is stored"
        )
        t.expectEqual(
            store.sessions.first { $0.id == "hot" }?.steps,
            30_118,
            "loading and appending never rewrite recorded steps"
        )
    }
}

public func healthWeightTests(_ t: TestRunner) {
    t.suite("health-weight") { t in
        let json = """
        {"kg":82.4,"measuredAt":"2026-08-31T07:00:00Z","source":"apple-health"}
        """.data(using: .utf8)!
        let sample = HealthWeight.parse(data: json)
        t.expectEqual(sample?.kg ?? 0, 82.4, accuracy: 0.01, "kg from Health dump")
        t.check(sample?.measuredAt != nil, "measuredAt parsed")

        let lb = """
        {"lb":180.8}
        """.data(using: .utf8)!
        t.expectEqual(HealthWeight.parse(data: lb)?.kg ?? 0, 82.0, accuracy: 0.2, "lb converts")

        t.check(HealthWeight.parse(data: Data("{\"kg\":3}".utf8)) == nil, "reject nonsense kg")

        // A Shortcut on a Dutch phone writes 74,3, which is not JSON.
        let comma = Data("{\"kg\": 74,3, \"measuredAt\": \"2026-08-31T07:00:00Z\", \"source\": \"apple-health\"}".utf8)
        t.expectEqual(HealthWeight.parse(data: comma)?.kg ?? 0, 74.3, accuracy: 0.001, "decimal comma from a Shortcut is read")
        t.check(HealthWeight.parse(data: comma)?.measuredAt != nil, "and the date beside it survives")
        t.expectEqual(HealthWeight.parse(data: Data("{\"lb\": 163,8}".utf8))?.kg ?? 0, 74.3, accuracy: 0.05, "decimal comma in pounds")
        t.check(HealthWeight.parse(data: Data("{\"kg\": 74,3,".utf8)) == nil, "still rejects real garbage")

        // The newest of several files wins.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-weight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let older = dir.appendingPathComponent("older.json")
            let newer = dir.appendingPathComponent("newer.json")
            try Data(#"{"kg": 80.0, "measuredAt": "2026-08-01T07:00:00Z"}"#.utf8).write(to: older)
            try Data(#"{"kg": 74.3, "measuredAt": "2026-08-31T07:00:00Z"}"#.utf8).write(to: newer)
            let missing = dir.appendingPathComponent("missing.json")
            t.expectEqual(HealthWeight.load(from: [older, missing, newer])?.kg ?? 0, 74.3, accuracy: 0.001, "the latest sample wins")
            t.check(HealthWeight.load(from: [missing]) == nil, "no file, no weight")
        } catch { t.check(false, "weight fixture: \(error)") }
    }
}

public func gaitModelTests(_ t: TestRunner) {
    t.suite("gait-model") { t in
        let length = GaitModel.stepLengthM(speedKmh: 3.24)
        t.expectEqual(length, 0.64037, accuracy: 0.0001, "3.24 km/h step length")
        let modelled = GaitModel.steps(distanceM: 8_310, speedKmh: 3.24)
        t.check((12_970...12_990).contains(modelled), "8.31 km at 3.24 km/h ≈ 12,980")
        t.expectEqual(GaitModel.steps(distanceM: 0, speedKmh: 3.2), 0, "no distance, no steps")
        t.expectEqual(
            GaitModel.stepLengthM(speedKmh: 99), GaitModel.stepLengthM(speedKmh: GaitModel.maxSpeedKmh),
            "speed is clamped to the model's range"
        )
    }
}

public func treadmillMatchTests(_ t: TestRunner) {
    t.suite("treadmill-match") { t in
        t.check(TreadmillMatch.accepts(name: "KS-HD-Z1E", serviceUUIDs: []), "Z1 by name")
        t.check(!TreadmillMatch.accepts(name: "UREVO URTM025", serviceUUIDs: []), "generic brand needs FTMS")
        t.check(TreadmillMatch.accepts(name: "UREVO URTM025", serviceUUIDs: [Z1Constants.fitnessMachineService]), "Urevo with FTMS")
        t.check(TreadmillMatch.accepts(name: "WalkingPad C2", serviceUUIDs: []), "WalkingPad C2")
        t.check(
            !TreadmillMatch.accepts(name: "Desk Treadmill", serviceUUIDs: []),
            "generic desk treadmill name alone is insufficient"
        )
        t.check(
            !TreadmillMatch.accepts(name: "DESKTOP-AB12CDE", serviceUUIDs: [Z1Constants.fitnessMachineService]),
            "Windows PC is never selected, even with FTMS"
        )
        t.check(
            !TreadmillMatch.accepts(name: "KICKR BIKE", serviceUUIDs: [Z1Constants.fitnessMachineService]),
            "indoor bike rejected"
        )
        t.check(
            !TreadmillMatch.accepts(name: nil, serviceUUIDs: [Z1Constants.fitnessMachineService]),
            "unnamed FTMS rejected"
        )
    }
}

public func counterRestoreTests(_ t: TestRunner) {
    t.suite("counter-restore") { t in
        // Real failure shape from 2026-09-04: persistence was disabled, but
        // 7.10 km of stale offsets turned a 2.45 km walk into 9.55 km.
        let freshWalk = CounterRestorePlan.make(
            savedElapsed: 2_645,
            savedDistance: 2_450,
            savedOffsetElapsed: 6_126,
            savedOffsetDistance: 7_100,
            savedKcal: 548.5,
            currentElapsed: 2_645,
            currentDistance: 2_450
        )
        t.expectEqual(freshWalk.totalKcal, 0, accuracy: 0.001, "stale cross-session calories are dropped with stale offsets")

        let continuingWalk = CounterRestorePlan.make(
            savedElapsed: 600,
            savedDistance: 500,
            savedOffsetElapsed: 0,
            savedOffsetDistance: 0,
            savedKcal: 30,
            currentElapsed: 660,
            currentDistance: 550
        )
        t.expectEqual(continuingWalk.totalKcal, 30, accuracy: 0.001, "same counter run restores calories")
        t.expectEqual(continuingWalk.gapElapsed, 60, "same counter run accounts for reconnect time")
        t.expectEqual(continuingWalk.gapDistance, 50, "same counter run accounts for reconnect distance")
    }
}

/// Runs every suite. Returns the process exit code (0 = all passed).
@discardableResult
public func runAllZ1CoreTests() async -> Int32 {
    let runner = TestRunner()
    protocolTests(runner)
    metricsTests(runner)
    unitsTests(runner)
    truncatedTelemetryTests(runner)
    stepCounterTests(runner)
    remoteSessionTrackerTests(runner)
    historyAndCompatibilityTests(runner)
    sessionStoreTests(runner)
    healthWeightTests(runner)
    gaitModelTests(runner)
    treadmillMatchTests(runner)
    counterRestoreTests(runner)
    beltSegmentRegressionTests(runner)
    sessionMigrationRegressionTests(runner)
    realHistoryCopyRegressionTests(runner)
    healthQueueRegressionTests(runner)
    healthQueueResetFileTests(runner)
    await pendingWalkDisplayTests(runner)
    adversarialPersistenceTests(runner)
    await liveExportRegressionTests(runner)
    await fakeTransportRegressionTests(runner)
    await auditMatchAndTimerTests(runner)
    await auditDriverLinkTests(runner)
    await auditDriverTelemetryTests(runner)
    await auditDriverPacingTests(runner)
    auditStoreWiringTests(runner)
    auditRobustnessTests(runner)
    await auditDriverFuzzTests(runner)
    auditHistoryTests(runner)
    await auditLiveExportTests(runner)
    auditCalendarTests(runner)
    appSupportTests(runner)
    await reconnectPolicyTests(runner)
    await rememberedPadTests(runner)
    if runner.failures == 0 {
        print("PASS: \(runner.checks) checks, 0 failures")
        return 0
    }
    print("FAILED: \(runner.checks) checks, \(runner.failures) failures")
    return 1
}
