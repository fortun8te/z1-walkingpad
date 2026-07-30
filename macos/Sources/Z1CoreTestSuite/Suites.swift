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

/// Runs every suite. Returns the process exit code (0 = all passed).
@discardableResult
public func runAllZ1CoreTests() -> Int32 {
    let runner = TestRunner()
    protocolTests(runner)
    metricsTests(runner)
    unitsTests(runner)
    if runner.failures == 0 {
        print("PASS: \(runner.checks) checks, 0 failures")
        return 0
    }
    print("FAILED: \(runner.checks) checks, \(runner.failures) failures")
    return 1
}
