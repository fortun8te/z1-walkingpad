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

        // unlock-ok detection
        t.check(Z1Protocol.isUnlockOK(Z1Protocol.buildFrame(cmd0: 0x71, cmd1: 0x80)), "isUnlockOK true")
        t.check(!Z1Protocol.isUnlockOK(Z1Protocol.buildFrame(cmd0: 0x71, cmd1: 0x81)), "isUnlockOK false for 71 81")
        t.check(!Z1Protocol.isUnlockOK(Data([0x00, 0x01, 0x02])), "isUnlockOK false for garbage")

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
        t.expectEqual(Z1Metrics.metForSpeed(0.0), 1.0, accuracy: 1e-12, "MET at 0.0 (resting)")
        // ACSM level-walking: VO2 = 0.1 * (km/h * 1000/60) + 3.5
        // 3.2 km/h = 53.33 m/min -> VO2 8.833 -> MET 2.524
        t.expectEqual(Z1Metrics.vo2ForSpeed(3.2), 8.833, accuracy: 0.001, "VO2 at 3.2 km/h")
        t.expectEqual(Z1Metrics.metForSpeed(3.2), 8.833 / 3.5, accuracy: 0.001, "MET at 3.2")
        // 6.4 km/h = 106.67 m/min -> VO2 14.167
        t.expectEqual(Z1Metrics.vo2ForSpeed(6.4), 14.167, accuracy: 0.001, "VO2 at max speed")
        t.expectEqual(Z1Metrics.metForSpeed(-1), 1.0, accuracy: 1e-12, "negative speed clamps to resting")

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

        t.expectEqual(Z1Units.kgToLb(75), 165.3, accuracy: 0.05, "75 kg -> 165.3 lb")
        t.expectEqual(Z1Units.lbToKg(165.3), 75, accuracy: 0.05, "165.3 lb -> ~75 kg")
        t.check(
            abs(Z1Units.lbToKg(Z1Units.kgToLb(82.5)) - 82.5) < 1e-9,
            "lb<->kg roundtrip"
        )

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

/// Stride-curve estimator tests.
public func strideTests(_ t: TestRunner) {
    t.suite("stride") { t in
        func calibrate(_ learner: inout StrideLearner, speed: Double = 3.5, stride: Double = 0.75) {
            for _ in 0 ..< 3 {
                learner.learn(distanceM: 40, steps: 40 / stride, speedKmh: speed)
            }
        }

        // Truncated telemetry: flags promise steps but the bytes end early —
        // the whole frame must drop (all nil), never decode as zeros.
        do {
            let truncated = Data([0x04, 0x24, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00])
            let parsed = Z1Protocol.parseTreadmillData(truncated)
            t.check(parsed.steps == nil, "truncated frame drops steps")
            t.check(parsed.distanceM == nil, "truncated frame drops distance")
            t.check(parsed.speedKmh == nil, "truncated frame drops speed")
        }

        let key = "z1.strideLearner.test"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        var fresh = StrideLearner(userDefaultsKey: key)
        t.check(!fresh.calibrated, "starts uncalibrated")
        t.expectNil(fresh.stride(for: 2.0), "no stride when uncalibrated")

        fresh.learn(distanceM: 100, steps: 150, speedKmh: 2.0) // below trust speed
        fresh.learn(distanceM: 0, steps: 100, speedKmh: 4.0)
        fresh.learn(distanceM: 100, steps: 0, speedKmh: 4.0)
        t.check(!fresh.calibrated, "invalid segments ignored")

        calibrate(&fresh)
        t.check(fresh.calibrated, "calibrated after valid segment")
        t.expectEqual(fresh.stride(for: 3.5)!, 0.75, accuracy: 1e-9, "bucket readback")

        var two = StrideLearner(userDefaultsKey: key + ".two")
        defer { UserDefaults.standard.removeObject(forKey: key + ".two") }
        calibrate(&two, speed: 3.0, stride: 0.70)
        calibrate(&two, speed: 4.0, stride: 0.80)
        t.expectEqual(two.stride(for: 3.5)!, 0.75, accuracy: 1e-9, "interpolation")
        t.expectEqual(two.stride(for: 1.6)!, 0.70, accuracy: 1e-9, "extrapolate low -> nearest")
        t.expectEqual(two.stride(for: 6.4)!, 0.80, accuracy: 1e-9, "extrapolate high -> nearest")

        var threshold = StrideLearner(userDefaultsKey: key + ".min")
        defer { UserDefaults.standard.removeObject(forKey: key + ".min") }
        threshold.learn(distanceM: 50, steps: 50 / 0.75, speedKmh: 3.5)
        t.expectNil(threshold.stride(for: 3.5), "one window not calibrated")
        threshold.learn(distanceM: 50, steps: 50 / 0.75, speedKmh: 3.5)
        t.expectNil(threshold.stride(for: 3.5), "two windows not calibrated")
        threshold.learn(distanceM: 10, steps: 10 / 0.75, speedKmh: 3.5)
        t.expectEqual(threshold.stride(for: 3.5)!, 0.75, accuracy: 1e-9, "cumulative crosses threshold")

        var outlier = StrideLearner(userDefaultsKey: key + ".outlier")
        defer { UserDefaults.standard.removeObject(forKey: key + ".outlier") }
        outlier.learn(distanceM: 100, steps: 1, speedKmh: 4.0)
        t.check(outlier.buckets.isEmpty, "impossible stride rejected")

        let reloaded = StrideLearner(userDefaultsKey: key)
        t.expectEqual(reloaded.stride(for: 3.5)!, 0.75, accuracy: 1e-9, "persistence roundtrip")
    }
}

/// Interpolation must tick the display without inflating the session total.
public func stepSmootherTests(_ t: TestRunner) {
    t.suite("step-smoother") { t in
        var clock = StepSmoother()
        clock.speedKmh = 3.0
        clock.strideM = 0.75
        // 3 km/h / 0.75 m = 1.11 steps/s. Ten 1 Hz packets of 1 step each.
        for _ in 0 ..< 10 {
            clock.addDelta(1)
            clock.interpolate(secondsSincePacket: 0.9)
            t.check(clock.displaySteps >= clock.packetSteps, "display never behind packet")
            t.check(clock.displaySteps <= clock.packetSteps + 3, "display cap")
        }
        t.expectEqual(clock.packetSteps, 10, accuracy: 1e-9, "packets are the total")
        clock.addDelta(0)
        t.expectEqual(clock.displaySteps, 10, accuracy: 1e-9, "next packet snaps leftover ticks away")

        // The old interpolator added expected steps on top of the packet
        // delta every second, so 10s of walking stored ~20 steps.
        t.check(clock.packetSteps < 15, "must not double-count interpolated ticks")
    }
}

/// Physical-remote session merging tests.
public func automaticHealthExportTests(_ t: TestRunner) {
    t.suite("automatic-health-export") { t in
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
            stoppedAt.addingTimeInterval(600),
            "remote Stop sets one ten-minute deadline"
        )

        // More zero-speed frames do not move the deadline.
        let repeatedZero = tracker.observe(
            status(running: false, elapsed: 700, distance: 550, steps: 900),
            at: stoppedAt.addingTimeInterval(300)
        )
        t.expectEqual(
            repeatedZero.finalizationDeadline,
            stoppedAt.addingTimeInterval(600),
            "repeated zero telemetry does not extend grace"
        )

        // Restart one second before expiry. Reset counters are folded into the
        // same session instead of finalizing a second workout.
        let resumed = tracker.observe(
            status(running: true, elapsed: 1, distance: 1, steps: 2),
            at: stoppedAt.addingTimeInterval(599)
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
            tracker.finalizeIfDue(at: finalStop.addingTimeInterval(599)).completed.isEmpty,
            "session is not logged early"
        )
        let due = tracker.finalizeIfDue(at: finalStop.addingTimeInterval(600))
        t.expectEqual(due.completed.count, 1, "one merged workout is offered to the history")
        if let walk = due.completed.first {
            t.expectEqual(walk.id, "remote-session-1", "history entry shares the session ID")
            t.expectEqual(walk.activeDurationS, 901, "active time excludes the break")
            t.expectEqual(walk.distanceM, 701, "distance spans both walking segments")
            t.check(!walk.offeredToHealth, "local history never claims a Health export")
            tracker.acknowledgeLog(sessionID: walk.id)
        }
        t.check(
            tracker.finalizeIfDue(at: finalStop.addingTimeInterval(600)).completed.isEmpty,
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
            let restoredDue = restored.finalizeIfDue(at: base.addingTimeInterval(1_200))
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
        let due = tracker.finalizeIfDue(at: stopped.addingTimeInterval(600))
        t.expectEqual(due.completed.count, 1, "a five-minute walk still reaches the history")
        t.check(
            due.completed.first?.offeredToHealth == false,
            "local history never claims a Health export"
        )

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
            noise.finalizeIfDue(at: base.addingTimeInterval(700)).completed.isEmpty,
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
            store.append(walk("b", at: noon.addingTimeInterval(3_600), minutes: 15, meters: 1_000, steps: 1_500)),
            "a second walk on the same day is stored"
        )
        _ = store.append(walk("c", at: noon.addingTimeInterval(-86_400), minutes: 20, meters: 1_400, steps: 2_000))

        let today = store.totals(on: noon, calendar: calendar)
        t.expectEqual(today.walks, 2, "today counts both of today's walks")
        t.expectEqual(today.activeDurationS, 45 * 60, "today sums active time")
        t.expectEqual(today.distanceM, 3_000, "today sums distance")
        t.expectEqual(today.steps, 4_500, "today sums steps")

        let week = store.recentDays(7, endingOn: noon, calendar: calendar)
        t.expectEqual(week.count, 7, "the week chart always has seven days")
        t.expectEqual(week.last?.walks, 2, "the last bar is today")
        t.check(week.first?.isEmpty == true, "days with no walks are empty, not missing")
        t.expectEqual(week[5].walks, 1, "yesterday keeps its own walk")

        // Reload from disk: the history must survive a relaunch.
        let reopened = SessionStore(url: temp)
        t.expectEqual(reopened.sessions.count, 3, "history is reloaded from disk")
        t.expectEqual(reopened.mostRecent(2).first?.id, "b", "most recent is newest first")
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
            2_226,
            "impossible stride is rewritten from distance at 0.53 m"
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
    }
}

public func stepSanityTests(_ t: TestRunner) {
    t.suite("step-sanity") { t in
        t.expectEqual(StepSanity.steps(2_294, distanceM: 1_180), 2_294, "plausible pad count is kept")
        t.expectEqual(StepSanity.steps(30_118, distanceM: 1_180), 2_226, "impossible leftover is rewritten")
        t.expectEqual(StepSanity.steps(4_747, distanceM: 50), 94, "open-walk leftover total is rewritten")
        t.expectEqual(StepSanity.steps(4_679, distanceM: 10), 19, "10 m leftover pad total is rewritten")
        t.expectEqual(StepSanity.steps(4_679, distanceM: 0), 0, "no distance, drop leftover steps")

        var session = StepSession()
        t.expectEqual(
            session.ingest(pad: 4_679, previousPad: 4_678, elapsedReset: true, distanceReset: true),
            0,
            "new pad session with leftover register starts at 0"
        )
        t.expectEqual(
            session.ingest(pad: 4_680, previousPad: 4_679, elapsedReset: false, distanceReset: false),
            1,
            "next packet ticks one"
        )
        t.expectEqual(
            session.ingest(pad: 4_681, previousPad: 4_680, elapsedReset: false, distanceReset: false),
            2,
            "ticks stay monotonic"
        )
        var dumped = StepSession()
        t.expectEqual(
            dumped.ingest(pad: 0, previousPad: 2_000, elapsedReset: true, distanceReset: true),
            0,
            "omitted-then-zero after reset"
        )
        t.expectEqual(
            dumped.ingest(pad: 4_679, previousPad: 0, elapsedReset: false, distanceReset: false),
            0,
            "dumped leftover total is not a 4,679-step jump"
        )
        t.expectEqual(
            dumped.ingest(pad: 4_680, previousPad: 4_679, elapsedReset: false, distanceReset: false),
            1,
            "after the dump, ticks are 1, 2, 3"
        )
        var leftover = StepSession()
        t.expectEqual(
            leftover.ingest(
                pad: 6_043,
                previousPad: 6_042,
                elapsedReset: false,
                distanceReset: false,
                distanceM: 760
            ),
            6_043,
            "without a counter reset, pad steps are the live count"
        )
        var reconnect = StepSession()
        t.expectEqual(
            reconnect.ingest(
                pad: 7_528,
                previousPad: nil,
                elapsedReset: false,
                distanceReset: false,
                distanceM: 630
            ),
            0,
            "first packet after connect with leftover register starts at 0"
        )
    }
}

public func updateFeedTests(_ t: TestRunner) {
    t.suite("update-feed") { t in
        let json = """
        {"version":"202609011200","shortVersion":"1.0","url":"http://127.0.0.1:8741/Z1WalkingPad-202609011200.zip","sha256":"abc","notes":"steps"}
        """.data(using: .utf8)!
        do {
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: json)
            t.check(feed.isNewer(than: "202608311500"), "later timestamp is an update")
            t.check(!feed.isNewer(than: "202609011200"), "same build is not an update")
            t.check(!feed.isNewer(than: "202609011201"), "older feed is not an update")
            t.expectEqual(feed.packageURL?.host, "127.0.0.1", "package host")
        } catch {
            t.check(false, "feed JSON decodes: \(error)")
        }
    }
}

/// Runs every suite. Returns the process exit code (0 = all passed).
@discardableResult
public func runAllZ1CoreTests() -> Int32 {
    let runner = TestRunner()
    protocolTests(runner)
    metricsTests(runner)
    unitsTests(runner)
    strideTests(runner)
    stepSmootherTests(runner)
    automaticHealthExportTests(runner)
    historyAndCompatibilityTests(runner)
    sessionStoreTests(runner)
    healthWeightTests(runner)
    stepSanityTests(runner)
    updateFeedTests(runner)
    openMeteoTests(runner)
    if runner.failures == 0 {
        print("PASS: \(runner.checks) checks, 0 failures")
        return 0
    }
    print("FAILED: \(runner.checks) checks, \(runner.failures) failures")
    return 1
}

/// Moon phase math and weather-snapshot flag/JSON tests.
func openMeteoTests(_ t: TestRunner) {
    t.suite("open-meteo") { t in
        // New moon anchor: 2000-01-06 18:14 UTC.
        let epoch = Date(timeIntervalSince1970: 947_182_440)
        let synodic = 29.530588853 * 86_400
        t.expectEqual(MoonPhase.fraction(at: epoch), 0.0, accuracy: 0.01, "new moon at anchor epoch")
        t.expectEqual(
            MoonPhase.fraction(at: epoch.addingTimeInterval(14.765294 * 86_400)),
            0.5,
            accuracy: 0.01,
            "full moon half a cycle later"
        )
        t.expectEqual(
            MoonPhase.fraction(at: epoch.addingTimeInterval(synodic)),
            0.0,
            accuracy: 0.01,
            "phase wraps to new moon after one synodic month"
        )

        // A 1990s date (before the anchor) must still land in [0, 1).
        let ninetiesFraction = MoonPhase.fraction(at: Date(timeIntervalSince1970: 788_918_400))
        t.check(ninetiesFraction >= 0 && ninetiesFraction < 1, "pre-epoch date stays in [0,1)")

        t.expectEqual(MoonPhase.illumination(at: epoch), 0.0, accuracy: 0.01, "no light at new moon")
        t.expectEqual(
            MoonPhase.illumination(at: epoch.addingTimeInterval(14.765294 * 86_400)),
            1.0,
            accuracy: 0.01,
            "full disc at full moon"
        )

        // The memberwise initializer stays internal, so snapshots are built
        // through the same Codable path the app already relies on.
        func snapshot(code: Int = 0, precipitation: Double = 0, cloudCover: Double = 0) -> WeatherSnapshot {
            let json = "{\"cloudCover\":\(cloudCover),\"precipitation\":\(precipitation),\"weatherCode\":\(code),\"fetchedAt\":0}"
            do {
                return try JSONDecoder().decode(WeatherSnapshot.self, from: Data(json.utf8))
            } catch {
                fatalError("test snapshot fixture failed to decode: \(error)")
            }
        }
        t.check(snapshot(code: 71).isSnow, "code 71 is snow")
        t.check(snapshot(code: 85).isSnow, "code 85 is snow")
        t.check(!snapshot(code: 61).isSnow, "code 61 is not snow")

        let rain = snapshot(code: 61, precipitation: 0.2)
        t.check(rain.isRaining && !rain.isSnowing, "rainy code with water is rain only")
        let snowfall = snapshot(code: 71, precipitation: 0.2)
        t.check(snowfall.isSnowing, "snow code with precipitation snows")
        t.check(
            snapshot(cloudCover: 0.3).isClear && !snapshot(cloudCover: 0.5).isClear,
            "clear threshold sits below 45% cloud"
        )

        do {
            let original = snapshot(code: 71, precipitation: 0.2, cloudCover: 0.6)
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(WeatherSnapshot.self, from: data)
            t.expectEqual(restored, original, "weather JSON roundtrip unchanged")
        } catch {
            t.check(false, "weather JSON roundtrip: \(error)")
        }
    }
}
