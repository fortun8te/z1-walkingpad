import CoreBluetooth
import Foundation
import Z1Core

// One suite per bug from the 2026-10-12 audit (research/17-z1-walkingpad-audit.md)
// plus the bugs found while verifying them. Every suite is written so that it
// FAILS against the behaviour the audit described; the suite names are the ones
// quoted in the bug table. Nothing here touches BLE, the real treadmill, the
// installed app's history or the iCloud Health queue.

private let ftms = [Z1Constants.fitnessMachineService]

// MARK: - matching and BLE timers

public func auditMatchAndTimerTests(_ t: TestRunner) async {
    t.suite("audit-01 DESKTOP PCs are never the pad") { t in
        for name in ["DESKTOP-AB12CDE", "desktop-ab12cde", "Desktop-ABC", "DESKTOP-0000000"] {
            t.check(!TreadmillMatch.accepts(name: name, serviceUUIDs: []), "\(name) without FTMS")
            t.check(!TreadmillMatch.accepts(name: name, serviceUUIDs: ftms), "\(name) with FTMS")
            t.check(TreadmillMatch.excludes(name: name), "\(name) is excluded from re-adoption too")
        }
        // The old rule accepted any name containing "desk", "walk" or "tread",
        // and any advertisement with the FTMS service whatever its name.
        for name in ["Walk Tracker", "Desk Lamp", "My Desk", "Heart Rate Strap", "MacBook Pro", "Sam's iPhone"] {
            t.check(!TreadmillMatch.accepts(name: name, serviceUUIDs: []), "\(name) without FTMS")
        }
        t.check(!TreadmillMatch.accepts(name: "Heart Rate Strap", serviceUUIDs: ftms), "an FTMS strap is not a treadmill")
        t.check(!TreadmillMatch.accepts(name: "", serviceUUIDs: ftms), "an empty name is never accepted")
        // Real pads still match.
        t.check(TreadmillMatch.accepts(name: "KS-HD-Z1D", serviceUUIDs: []), "Z1 by name alone")
        t.check(TreadmillMatch.accepts(name: "UREVO URTM025", serviceUUIDs: ftms), "generic pad with FTMS")
        t.check(TreadmillMatch.accepts(name: "Under Desk Treadmill", serviceUUIDs: ftms), "named under-desk pad with FTMS")
        t.check(!TreadmillMatch.excludes(name: "UREVO URTM025"), "a generic pad may be re-adopted")
        t.check(!TreadmillMatch.excludes(name: nil), "no name excludes nothing")
    }

    await t.suite("audit-02 stale BLE timers cannot fail a newer operation") { t in
        let queue = DispatchQueue(label: "z1tests.timeouts")
        let timeouts = OperationTimeouts(queue: queue)
        let log = FiredLog()

        // An operation that finished retires its timer.
        timeouts.schedule(after: 0.05, key: "connect") { log.add("finished-op") }
        timeouts.cancel("connect")

        // A newer operation under the same key replaces the older timer: the
        // old deadline must not fire against the new operation.
        timeouts.schedule(after: 0.05, key: "write:2AD9") { log.add("old-write") }
        timeouts.schedule(after: 1.5, key: "write:2AD9") { log.add("new-write") }

        // Unrelated keys are independent.
        timeouts.schedule(after: 0.05, key: "read:2AD4") { log.add("read") }
        timeouts.schedule(after: 0.05, key: "power:1") { log.add("power-1") }
        timeouts.schedule(after: 0.05, key: "power:2") { log.add("power-2") }
        timeouts.cancel(keysWithPrefix: "power:")

        // Poll (slow CI machines) until the short timers have fired, well before 1.5 s.
        for _ in 0..<40 where !log.entries.contains("read") { try? await Task.sleep(for: .milliseconds(25)) }
        try? await Task.sleep(for: .milliseconds(100))
        t.expectEqual(log.entries.sorted(), ["read"], "only the live timer fired before the newer deadline")
        t.expectEqual(timeouts.pendingKeys, ["write:2AD9"], "one timer left pending")

        for _ in 0..<120 where !log.entries.contains("new-write") { try? await Task.sleep(for: .milliseconds(25)) }
        t.expectEqual(log.entries.sorted(), ["new-write", "read"], "the newer timer fired once, the older never")
        t.expectEqual(timeouts.pendingKeys, [], "a fired timer retires its key")

        // cancelAll (a disconnect fails every pending operation at once).
        timeouts.schedule(after: 0.05, key: "a") { log.add("a") }
        timeouts.schedule(after: 0.05, key: "b") { log.add("b") }
        timeouts.cancelAll()
        try? await Task.sleep(for: .milliseconds(120))
        t.expectEqual(log.entries.sorted(), ["new-write", "read"], "cancelAll silences everything")
    }
}

private final class FiredLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var entries: [String] { lock.withLock { items } }
}

// MARK: - driver: control point, disconnects, races

public func auditDriverLinkTests(_ t: TestRunner) async {
    // --- audit-03: control-point replies are matched on the request opcode.
    await t.suite("audit-03 control-point replies are matched by opcode") { t in
        let pad = ScriptedPad()
        let defaults = CountingDefaults.isolated()
        let driver = Z1Treadmill(transport: pad, defaults: defaults)
        do {
            try await driver.connect()
            // Every reply the driver sees is first preceded by a stray reply to
            // a different command (a late answer to something that timed out).
            pad.silentControlOpcodes = [Z1Constants.opStartOrResume]
            let start = Task { try await driver.start() }
            _ = await waitUntil { pad.controlOpcodes.contains(Z1Constants.opStartOrResume) }
            pad.sendControlReply(opcode: Z1Constants.opStopOrPause, result: 3)
            pad.sendControlReply(opcode: Z1Constants.opSetTargetSpeed, result: 4)
            try? await Task.sleep(for: .milliseconds(100))
            let runningEarly = await driver.status.beltRunning
            t.check(!runningEarly, "Start is still waiting for its own reply after two stray replies")
            pad.sendControlReply(opcode: Z1Constants.opStartOrResume, result: 1)
            do {
                try await start.value
                t.check(true, "Start completes on its own reply")
            } catch {
                t.check(false, "stray replies must not complete or fail Start: \(error)")
            }
            t.expectEqual(pad.controlOpcodes, [Z1Constants.opRequestControl, Z1Constants.opStartOrResume], "Start was sent once, with no retry")
        } catch { t.check(false, "scripted control-point fixture: \(error)") }
        await driver.disconnect()
    }

    // --- audit-04: an own disconnect cannot mask a later real drop.
    await t.suite("audit-04 own disconnect never swallows a later real drop") { t in
        let echoes: [(String, DisconnectEcho)] = [
            ("no callback (no peripheral / 5 s fallback)", .none),
            ("callback during disconnect", .immediate),
            ("callback after disconnect returned", .late(milliseconds: 40)),
        ]
        for (label, echo) in echoes {
            let pad = ScriptedPad()
            pad.echo = echo
            let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
            do {
                try await driver.connect()
                await driver.disconnect()
                try? await Task.sleep(for: .milliseconds(120))
                let afterOwn = await driver.status
                t.expectEqual(afterOwn.phase, .disconnected, "\(label): own disconnect leaves .disconnected")
                t.expectNil(afterOwn.errorMessage, "\(label): an own disconnect is not an error")

                try await driver.connect()
                let ready = await driver.status.phase
                t.expectEqual(ready, .ready, "\(label): reconnect reaches ready")
                pad.dropLink()
                let noticed = await waitUntil { await driver.status.phase == .disconnected }
                t.check(noticed, "\(label): a genuine drop after an own disconnect is noticed")
                t.expectEqual(await driver.status.errorMessage, "Connection lost", "\(label): and reported as lost")
            } catch { t.check(false, "\(label): \(error)") }
        }
    }

    // --- audit-05: a connect error is not replaced by "Connection lost".
    await t.suite("audit-05 connect error survives the disconnect echo") { t in
        for (label, echo) in [
            ("echo during cleanup", DisconnectEcho.immediate),
            ("echo after cleanup", .late(milliseconds: 60)),
        ] {
            let pad = ScriptedPad()
            pad.connectError = ScriptedPad.ScriptError()
            pad.echo = echo
            let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
            do {
                try await driver.connect()
                t.check(false, "\(label): connect must throw")
            } catch {
                try? await Task.sleep(for: .milliseconds(200))
                let state = await driver.status
                t.expectEqual(state.phase, .error, "\(label): phase stays .error")
                t.check(state.errorMessage?.contains("scripted connect failure") == true, "\(label): the original cause is still the message, got \(state.errorMessage ?? "nil")")
            }
        }
        // A callback from a link that never came up must not invent a loss.
        let quiet = ScriptedPad()
        let idle = Z1Treadmill(transport: quiet, defaults: CountingDefaults.isolated())
        do {
            try await idle.connect()
            await idle.disconnect()
            quiet.dropLink()
            try? await Task.sleep(for: .milliseconds(60))
            t.expectNil(await idle.status.errorMessage, "an echo for a link already torn down is ignored")
        } catch { t.check(false, "idle echo fixture: \(error)") }
    }

    // --- new-01: Disconnect (or Quit) during a connect attempt.
    await t.suite("new-01 disconnect during a connect cannot be undone") { t in
        for stage in ["connect", "scan"] {
            let pad = ScriptedPad()
            if stage == "connect" { pad.holdConnect = true } else { pad.holdScan = true }
            let gate = stage == "connect" ? pad.connectGate : pad.scanGate
            let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
            let recorder = StatusRecorder(driver)
            let attempt = Task { try await driver.connect() }
            let parked = await waitUntil { gate.hasEntered }
            t.check(parked, "\(stage): attempt reached the \(stage) step")
            await driver.disconnect()
            gate.release()
            let outcome = await attempt.result
            switch outcome {
            case .success: t.check(false, "\(stage): superseded connect must not report success")
            case .failure(let error): t.check(error is CancellationError, "\(stage): superseded connect is cancelled, got \(error)")
            }
            try? await Task.sleep(for: .milliseconds(100))
            let final = await driver.status
            t.expectEqual(final.phase, .disconnected, "\(stage): the user's Disconnect stands")
            t.expectNil(final.errorMessage, "\(stage): no error is raised for a cancelled attempt")
            t.check(!pad.isLinked, "\(stage): the cancelled attempt leaves no link behind")
            t.check(!recorder.statuses.contains { $0.phase == .ready }, "\(stage): the pad never showed as ready")
            recorder.stop()
            // The next attempt is not poisoned by the cancelled one.
            pad.holdConnect = false
            pad.holdScan = false
            do {
                try await driver.connect()
                t.expectEqual(await driver.status.phase, .ready, "\(stage): a fresh connect after the cancelled one reaches ready")
                t.check(pad.isLinked, "\(stage): and holds the link")
            } catch { t.check(false, "\(stage): reconnect after cancel: \(error)") }
            await driver.disconnect()
        }
    }

    // --- new-01b: the cancelled attempt unwinds after a newer one has started.
    await t.suite("new-01b a cancelled attempt does not cut off the next one") { t in
        let pad = ScriptedPad()
        pad.holdConnect = true
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
        let first = Task { try await driver.connect() }
        _ = await waitUntil { pad.connectGate.hasEntered }
        await driver.disconnect()
        pad.holdConnect = false
        do {
            try await driver.connect() // the user (or the retry loop) is already trying again
            t.expectEqual(await driver.status.phase, .ready, "second attempt reaches ready while the first is still parked")
            pad.connectGate.release() // now the first one finally unwinds
            _ = await first.result
            try? await Task.sleep(for: .milliseconds(100))
            t.expectEqual(await driver.status.phase, .ready, "the late unwind leaves the second attempt's state alone")
            t.check(pad.isLinked, "and does not tear down the second attempt's link")
        } catch { t.check(false, "overlapping attempts: \(error)") }
        await driver.disconnect()
    }

    // --- new-02: an identical first frame after a reconnect still counts.
    await t.suite("new-02 identical frame after reconnect still reports telemetry") { t in
        let pad = ScriptedPad()
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
        do {
            try await driver.connect()
            pad.sendTelemetry(speed: 0, elapsed: 900, distance: 750)
            _ = await waitUntil { await driver.status.hasTelemetry }
            await driver.disconnect()
            try await driver.connect()
            let before = await driver.status
            t.check(!before.hasTelemetry, "fresh connection starts without telemetry")
            pad.sendTelemetry(speed: 0, elapsed: 900, distance: 750)
            let seen = await waitUntil { await driver.status.hasTelemetry }
            t.check(seen, "the same counters as before the drop are still a live frame")
        } catch { t.check(false, "reconnect fixture: \(error)") }
        await driver.disconnect()
    }
}

// MARK: - driver: the vendor channel, calories, persistence

public func auditDriverTelemetryTests(_ t: TestRunner) async {
    await t.suite("new-03 vendor unlock path and a wrapping step register") { t in
        let pad = ScriptedPad()
        pad.vendor = true
        pad.deviceName = "KS-HD-Z1D"
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
        do {
            try await driver.connect()
            let ready = await driver.status
            t.expectEqual(ready.phase, .ready, "vendor profile unlocks and reaches ready")
            t.expectEqual(
                pad.vendorFrames.first,
                Data([0x71, 0x00, 0x05, 0x01, 0x2E, 0x5A, 0x31, 0x44, 0x74]),
                "first vendor write is the unlock frame for KS-HD-Z1D"
            )
            t.expectEqual(ready.properties[1], 1, "SETTING_GET property 1 parsed")
            t.expectEqual(ready.properties[10], 0x200, "SETTING_GET property 10 parsed")
            t.expectEqual(ready.minSpeedKmh, 1.6, accuracy: 0.001, "speed range read from the pad")
            t.expectEqual(ready.maxSpeedKmh, 6.4, accuracy: 0.001, "speed range read from the pad")

            // The pad's u16 step register wraps. Elapsed and distance keep
            // going, so this is the same walk and its calories must survive.
            // The first interval is long and the second short, so a reset in
            // between shows up as a clear drop, not as noise.
            pad.sendTelemetry(speed: 300, elapsed: 100, distance: 80, steps: 65_530)
            _ = await waitUntil { await driver.status.hasTelemetry }
            try? await Task.sleep(for: .milliseconds(1_500))
            pad.sendTelemetry(speed: 300, elapsed: 101, distance: 81, steps: 65_535)
            _ = await waitUntil { await driver.status.elapsedS == 101 }
            try? await Task.sleep(for: .milliseconds(150))
            let beforeWrap = await driver.status.caloriesKcal
            pad.sendTelemetry(speed: 300, elapsed: 102, distance: 82, steps: 3)
            _ = await waitUntil { await driver.status.elapsedS == 102 }
            let afterWrap = await driver.status
            t.check(beforeWrap > 0.05, "calories accumulate while walking (\(beforeWrap))")
            t.check(afterWrap.caloriesKcal > beforeWrap, "a step-register wrap does not reset the walk's calories (\(beforeWrap) -> \(afterWrap.caloriesKcal))")
            t.expectEqual(afterWrap.padSteps, 3, "the raw register is reported as it arrives")

            // A genuine pad reset (time and distance fall) does restart calories.
            pad.sendTelemetry(speed: 300, elapsed: 2, distance: 1, steps: 5)
            _ = await waitUntil { await driver.status.elapsedS == 2 }
            t.check(await driver.status.caloriesKcal < afterWrap.caloriesKcal, "a pad counter reset restarts the calorie estimate")

            // Vendor settings and the 0x77 tunnel fallback.
            try await driver.setDisplayUnits(imperial: true)
            t.expectEqual(await driver.status.properties[1], 3, "display-units write keeps the other bits and sets miles")
        } catch { t.check(false, "vendor fixture: \(error)") }
        await driver.disconnect()
    }

    await t.suite("audit-09 no per-packet preference writes, throttled calorie save") { t in
        let pad = ScriptedPad()
        let defaults = CountingDefaults.isolated()
        let log = defaults.log
        let driver = Z1Treadmill(transport: pad, defaults: defaults)
        do {
            try await driver.connect()
            for second in 1...60 {
                pad.sendTelemetry(speed: 300, elapsed: second, distance: second)
            }
            _ = await waitUntil { await driver.status.elapsedS == 60 }
            let written = log.keys
            t.expectEqual(written.filter { $0 == "z1.calorieState" }.count, 1, "60 telemetry frames save the calorie state once")
            t.expectEqual(written.filter { $0 != "z1.calorieState" }, [], "no other preference is written per packet (e.g. z1.lastGoodStrideM, z1.strideLearner)")
            t.check(Z1Treadmill.calorieStateSaveInterval >= .seconds(30), "calorie state is saved at most every 30 s while walking")
        } catch { t.check(false, "persistence fixture: \(error)") }
        await driver.disconnect()
    }
}

// MARK: - tracker, history, Health queue

public func auditHistoryTests(_ t: TestRunner) {
    func status(running: Bool, elapsed: Int, distance: Int, steps: Int, padSteps: Int? = nil) -> Z1Treadmill.Status {
        var s = Z1Treadmill.Status()
        s.phase = .ready; s.hasTelemetry = true
        s.beltRunning = running; s.speedKmh = running ? 3.2 : 0
        s.elapsedS = elapsed; s.distanceM = distance; s.steps = steps; s.padSteps = padSteps
        return s
    }
    let base = Date(timeIntervalSince1970: 2_100_000_000)

    t.suite("audit-10 separate walks stay separate (no 3 h merge)") { t in
        t.expectEqual(RemoteSessionTracker.stopGraceSeconds, 120, "a belt run ends after two minutes stopped, not three hours")
        // 5 minutes between two runs: two walks, two IDs.
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(status(running: true, elapsed: 600, distance: 500, steps: 700), at: base, newSessionID: { "first" })
        _ = tracker.observe(status(running: false, elapsed: 600, distance: 500, steps: 700), at: base.addingTimeInterval(1))
        let closed = tracker.finalizeIfDue(at: base.addingTimeInterval(1 + 120))
        t.expectEqual(closed.completed.map(\.id), ["first"], "the first run is closed after two minutes")
        tracker.acknowledgeLog(sessionID: "first")
        _ = tracker.observe(status(running: true, elapsed: 3, distance: 2, steps: 4), at: base.addingTimeInterval(300), newSessionID: { "second" })
        t.expectEqual(tracker.openWalkTotals?.id, "second", "a run five minutes later is its own walk")

        // The store keeps what it is given: walks 40 min and 2 h 59 min apart
        // are neither merged on append nor on reload.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-audit10-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sessions.json")
        func walk(_ id: String, _ start: Date) -> WalkSession {
            WalkSession(id: id, startedAt: start, endedAt: start.addingTimeInterval(900), activeDurationS: 900, distanceM: 750, steps: 1_200, caloriesKcal: 40, exportedToHealth: false)
        }
        let store = SessionStore(url: url)
        _ = store.append(walk("w1", base))
        _ = store.append(walk("w2", base.addingTimeInterval(900 + 40 * 60)))
        _ = store.append(walk("w3", base.addingTimeInterval(2 * 900 + 40 * 60 + 2 * 3600 + 59 * 60)))
        let reopened = SessionStore(url: url)
        t.expectEqual(reopened.sessions.map(\.id), ["w1", "w2", "w3"], "three walks stay three walks after a reload")
        t.expectEqual(reopened.sessions.map(\.activeDurationS), [900, 900, 900], "durations are not summed")
    }

    t.suite("audit-11 loading never rewrites history or the pad's steps") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-audit11-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sessions.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let iso = ISO8601DateFormatter()
            // Two walks 30 minutes apart (the old store merged these on load) with
            // pad step counts the gait model would have replaced.
            let a = base, b = base.addingTimeInterval(900 + 1_800)
            let bytes = Data("""
                [{"id":"a","startedAt":"\(iso.string(from: a))","endedAt":"\(iso.string(from: a.addingTimeInterval(900)))","activeDurationS":900,"distanceM":750,"steps":1234,"caloriesKcal":40,"exportedToHealth":false,"rawPadSteps":1234},\
                {"id":"b","startedAt":"\(iso.string(from: b))","endedAt":"\(iso.string(from: b.addingTimeInterval(900)))","activeDurationS":900,"distanceM":750,"steps":99,"caloriesKcal":40,"exportedToHealth":true}]
                """.utf8)
            try bytes.write(to: url)
            let store = SessionStore(url: url)
            t.expectEqual(store.sessions.map(\.id), ["a", "b"], "adjacent walks are not merged on load")
            t.expectEqual(store.sessions.map(\.steps), [1_234, 99], "stored steps are not replaced by the gait model")
            t.expectEqual(store.sessions.first?.rawPadSteps, 1_234, "the pad's own count is kept")
            t.expectEqual(store.sessions.last?.stepModelVersion, "legacy", "a count with no provenance is labelled legacy")
            t.expectEqual(try Data(contentsOf: url), bytes, "load wrote nothing")
        } catch { t.check(false, "load fixture: \(error)") }
    }

    t.suite("audit-12 the pad's step count is kept, and junk is not") { t in
        var tracker = RemoteSessionTracker()
        _ = tracker.observe(status(running: false, elapsed: 0, distance: 0, steps: 0, padSteps: 4_679), at: base)
        _ = tracker.observe(status(running: true, elapsed: 1, distance: 1, steps: 2, padSteps: 4_681), at: base.addingTimeInterval(1), newSessionID: { "kept" })
        // 600 m in 10 minutes, 0.75 m per step: 800 pad steps on top of the register.
        _ = tracker.observe(status(running: true, elapsed: 600, distance: 600, steps: 940, padSteps: 5_479), at: base.addingTimeInterval(600))
        _ = tracker.observe(status(running: false, elapsed: 600, distance: 600, steps: 940, padSteps: 5_479), at: base.addingTimeInterval(601))
        let kept = tracker.finalizeIfDue(at: base.addingTimeInterval(601 + 120)).completed.first
        t.expectEqual(kept?.rawPadSteps, 800, "pad steps are counted as deltas, not as the leftover register")
        t.expectEqual(kept?.steps, 800, "the walk's steps are the pad's count")
        if let kept { tracker.acknowledgeLog(sessionID: kept.id) }

        // A register that did not follow the walk (4,679 steps over 100 m).
        var junk = RemoteSessionTracker()
        _ = junk.observe(status(running: true, elapsed: 90, distance: 100, steps: 156, padSteps: 4_679), at: base, newSessionID: { "junk" })
        _ = junk.observe(status(running: false, elapsed: 90, distance: 100, steps: 156, padSteps: 4_679), at: base.addingTimeInterval(1))
        let fallback = junk.finalizeIfDue(at: base.addingTimeInterval(1 + 120)).completed.first
        t.expectNil(fallback?.rawPadSteps, "an absurd register is not trusted")
        t.expectEqual(fallback?.steps, 156, "the modelled count is used instead")

        // The count survives the store.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-audit12-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(url: dir.appendingPathComponent("sessions.json"))
        if let kept {
            var holder = RemoteSessionTracker()
            t.check(store.record(kept, weightKg: 74, tracker: &holder), "walk with pad steps is recorded")
            let reopened = SessionStore(url: dir.appendingPathComponent("sessions.json"))
            t.expectEqual(reopened.sessions.first?.rawPadSteps, 800, "pad steps survive a reload")
            t.expectNil(reopened.sessions.first?.stepModelVersion, "a measured count carries no model version")
        }
    }

    t.suite("audit-13 the Health queue writer is wired to history") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-audit13-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("queue/health-queue.json")
        let queue = HealthQueue(url: queueURL)
        let ended = Date().addingTimeInterval(-1_200)
        let started = ended.addingTimeInterval(-1_800)
        let cutover = started.addingTimeInterval(-60)
        let store = SessionStore(url: dir.appendingPathComponent("sessions.json"), healthQueue: queue, healthCutover: cutover)
        let walk = WalkSession(id: "queued-walk", startedAt: started, endedAt: ended, activeDurationS: 1_800, distanceM: 1_700, steps: 2_500, caloriesKcal: 90, exportedToHealth: false)
        t.check(!FileManager.default.fileExists(atPath: queueURL.path), "nothing is written before a walk exists")
        t.check(store.append(walk), "walk is stored")
        t.expectEqual((try? queue.queuedSessionIDs()) ?? [], Set(["queued-walk"]), "storing a finished walk puts it in the Shortcut queue")
        let root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: queueURL))) as? [String: Any]
        t.expectEqual(root?["schema_version"] as? Int, 2, "queue keeps the Shortcut's schema")

        // A walk that is still inside the ten-minute grouping window waits.
        let freshDir = dir.appendingPathComponent("fresh")
        let freshQueue = HealthQueue(url: freshDir.appendingPathComponent("health-queue.json"))
        let freshStore = SessionStore(url: freshDir.appendingPathComponent("sessions.json"), healthQueue: freshQueue, healthCutover: cutover)
        let recent = WalkSession(id: "too-fresh", startedAt: Date().addingTimeInterval(-900), endedAt: Date().addingTimeInterval(-60), activeDurationS: 840, distanceM: 700, steps: 1_000, caloriesKcal: 40, exportedToHealth: false)
        _ = freshStore.append(recent)
        t.expectEqual((try? freshQueue.queuedSessionIDs()) ?? ["error"], [], "a walk stopped a minute ago is not queued yet")
    }

    t.suite("new-04 quitting mid-walk does not leave an immortal open walk") { t in
        var before = RemoteSessionTracker()
        _ = before.observe(status(running: true, elapsed: 900, distance: 750, steps: 1_200), at: base, newSessionID: { "interrupted" })
        _ = before.observe(status(running: true, elapsed: 960, distance: 800, steps: 1_280), at: base.addingTimeInterval(60))
        // The app is quit (or killed) here. The next process only has the saved blob.
        guard let blob = try? JSONEncoder().encode(before),
              var after = try? JSONDecoder().decode(RemoteSessionTracker.self, from: blob) else {
            t.check(false, "tracker blob round trip"); return
        }
        t.expectEqual(after.openWalkTotals?.id, "interrupted", "the interrupted walk is still known after a relaunch")
        t.expectEqual(after.finalizationDeadline, base.addingTimeInterval(60 + 120), "and it has a deadline, so it cannot stay open forever")
        // The pad stays idle, so no telemetry ever arrives. Nothing but the
        // deadline can close the walk.
        t.check(after.finalizeIfDue(at: base.addingTimeInterval(60 + 119)).completed.isEmpty, "not closed early")
        let closed = after.finalizeIfDue(at: base.addingTimeInterval(86_400)).completed
        t.expectEqual(closed.map(\.id), ["interrupted"], "closed at the next check, a day later")
        t.expectEqual(closed.first?.endedAt, base.addingTimeInterval(60), "at the moment it was last seen, not at relaunch time")
        t.expectEqual(closed.first?.activeDurationS, 960, "with the time it really covered")

        // A relaunch within the grace window while the walk goes on keeps one walk.
        var resumed = try! JSONDecoder().decode(RemoteSessionTracker.self, from: blob)
        _ = resumed.observe(status(running: true, elapsed: 990, distance: 830, steps: 1_320), at: base.addingTimeInterval(90))
        t.expectEqual(resumed.openWalkTotals?.id, "interrupted", "a quick relaunch continues the same walk")
        t.expectEqual(resumed.openWalkTotals?.activeDurationS, 990, "without losing or doubling time")
    }

    t.suite("new-05 an unreadable entry does not hide or erase the rest") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-new05-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sessions.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let iso = ISO8601DateFormatter()
            func entry(_ id: String, _ start: Date) -> String {
                "{\"id\":\"\(id)\",\"startedAt\":\"\(iso.string(from: start))\",\"endedAt\":\"\(iso.string(from: start.addingTimeInterval(900)))\",\"activeDurationS\":900,\"distanceM\":750,\"steps\":1100,\"caloriesKcal\":40,\"exportedToHealth\":false}"
            }
            let text = "[\(entry("good-1", base)),{\"id\":\"broken\",\"startedAt\":\"yesterday\"},\(entry("good-2", base.addingTimeInterval(7_200)))]"
            let original = Data(text.utf8)
            try original.write(to: url)
            let store = SessionStore(url: url)
            t.expectEqual(store.sessions.map(\.id), ["good-1", "good-2"], "the readable walks load")
            t.expectEqual(store.unreadableEntryCount, 1, "the unreadable one is counted")
            t.check(store.append(WalkSession(id: "new", startedAt: base.addingTimeInterval(20_000), endedAt: base.addingTimeInterval(20_900), activeDurationS: 900, distanceM: 750, steps: 1_100, caloriesKcal: 40, exportedToHealth: false)), "a new walk saves")
            let rescued = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("sessions.unreadable-") } ?? []
            t.expectEqual(rescued.count, 1, "the file with the unreadable entry is kept aside before it is replaced")
            if let name = rescued.first {
                t.expectEqual(try? Data(contentsOf: dir.appendingPathComponent(name)), original, "the aside copy is the original bytes")
            }
            t.expectEqual(SessionStore(url: url).sessions.map(\.id), ["good-1", "good-2", "new"], "the new file holds everything that was readable")
        } catch { t.check(false, "unreadable-entry fixture: \(error)") }

        // A file that is not a walk list at all.
        let garbageDir = dir.appendingPathComponent("garbage")
        let garbage = garbageDir.appendingPathComponent("sessions.json")
        do {
            try FileManager.default.createDirectory(at: garbageDir, withIntermediateDirectories: true)
            try Data("not json {".utf8).write(to: garbage)
            let store = SessionStore(url: garbage)
            t.expectEqual(store.sessions.count, 0, "nothing can be read from garbage")
            _ = store.append(WalkSession(id: "fresh", startedAt: base, endedAt: base.addingTimeInterval(900), activeDurationS: 900, distanceM: 750, steps: 1_100, caloriesKcal: 40, exportedToHealth: false))
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: garbageDir.path))?.filter { $0.hasPrefix("sessions.unreadable-") } ?? []
            t.expectEqual(kept.count, 1, "an unreadable history file is preserved, not overwritten")
        } catch { t.check(false, "garbage fixture: \(error)") }
    }

    t.suite("new-06 a blocked Health batch is polled with backoff") { t in
        let delays = (0..<8).map { SessionStore.healthRetryDelay(attempt: $0) }
        t.expectEqual(delays, [60, 120, 240, 480, 900, 900, 900, 900], "one minute, doubling to fifteen minutes")
        t.expectEqual(SessionStore.healthRetryDelay(attempt: -3), 60, "negative attempts are the first")
        t.expectEqual(SessionStore.healthRetryDelay(attempt: 10_000), 900, "huge attempts stay capped")
    }

    t.suite("new-07 an idle queue check does not touch the disk") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-new07-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("health-queue.json")
        let receipts = dir.appendingPathComponent("health-queue-receipts.json")
        let queue = HealthQueue(url: queueURL)
        let ended = Date().addingTimeInterval(-3_600)
        let session = WalkSession(id: "idle-1", startedAt: ended.addingTimeInterval(-1_800), endedAt: ended, activeDurationS: 1_800, distanceM: 1_700, steps: 2_500, caloriesKcal: 90, exportedToHealth: false)
        do {
            t.expectEqual(try queue.enqueueReadyGroups(sessions: [session], now: Date(), notBefore: .distantPast), 1, "first call publishes")
            try FileManager.default.removeItem(at: queueURL) // the phone consumed it
            func identity() -> (NSNumber?, Date?) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: receipts.path)
                return (attrs?[.systemFileNumber] as? NSNumber, attrs?[.modificationDate] as? Date)
            }
            let before = identity()
            for _ in 0..<5 { _ = try queue.enqueueReadyGroups(sessions: [session], now: Date(), notBefore: .distantPast) }
            let after = identity()
            t.check(before.0 != nil && before.0 == after.0 && before.1 == after.1, "five no-op checks leave the receipt file untouched")
            t.check(!FileManager.default.fileExists(atPath: queueURL.path), "and do not republish")
        } catch { t.check(false, "idle queue fixture: \(error)") }
    }
}

// MARK: - live.json

public func auditLiveExportTests(_ t: TestRunner) async {
    await t.suite("audit-14 live.json writes: state flips at once, progress on a heartbeat") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-audit14-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.json")
        let exporter = await MainActor.run { LiveExport(url: url) }
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        var status = Z1Treadmill.Status()
        status.phase = .ready; status.beltRunning = true; status.speedKmh = 3.0
        var today = DayTotals(day: t0)
        func read() -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        }
        do {
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0, at: t0), "first frame writes")
            // Progress frames once a second for ten seconds: only the heartbeat writes.
            var writes = 0
            for second in 1...10 {
                status.elapsedS = second; status.distanceM = second
                if try await exporter.publish(status: status, today: today, goalProgress: 0, at: t0.addingTimeInterval(Double(second))) { writes += 1 }
            }
            t.expectEqual(writes, 2, "ten one-second frames cause two writes (at 5 s and 10 s), not ten")
            t.expectEqual(read()?["elapsedSec"] as? Int, 10, "the file holds the latest heartbeat")

            // Speed change: prompt, but not more than once a second.
            status.speedKmh = 3.4
            t.check(!(try await exporter.publish(status: status, today: today, goalProgress: 0, at: t0.addingTimeInterval(10.4))), "a speed change inside a second waits")
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0, at: t0.addingTimeInterval(11.1)), "and goes out within the next second")

            // Stop, 0.2 s after a write. The pad stops streaming, so nothing
            // else would ever correct the file: it must be written now.
            status.elapsedS = 12
            _ = try await exporter.publish(status: status, today: today, goalProgress: 0, at: t0.addingTimeInterval(12.0))
            status.beltRunning = false; status.speedKmh = 0
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0, at: t0.addingTimeInterval(12.2)), "Stop is written immediately")
            t.expectEqual(read()?["beltRunning"] as? Bool, false, "the file says the belt stopped")
            t.expectEqual(read()?["speedKmh"] as? Double, 0, "at zero speed")

            // Idle and connected: a walk finishing adds to today. Nothing is
            // streaming, so this change is written when it happens.
            today.activeDurationS = 600; today.distanceM = 500
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0.1, at: t0.addingTimeInterval(12.3)), "an idle change to today's totals is written at once")
            t.expectEqual(read()?["todayDistanceM"] as? Int, 500, "readers see the new total")

            // Disconnect right after.
            status.phase = .disconnected
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0.1, at: t0.addingTimeInterval(12.4)), "a disconnect is written at once")
            t.expectEqual(read()?["connected"] as? Bool, false, "and readers see it")

            // A clock set back by an hour must not freeze the file.
            status.phase = .ready; status.beltRunning = true; status.speedKmh = 3.0
            _ = try await exporter.publish(status: status, today: today, goalProgress: 0.1, at: t0.addingTimeInterval(20))
            status.elapsedS = 99
            t.check(try await exporter.publish(status: status, today: today, goalProgress: 0.1, at: t0.addingTimeInterval(-3_000)), "a clock that moved back is not throttled until it catches up")
        } catch { t.check(false, "live.json fixture: \(error)") }
    }
}

// MARK: - calendar edges

public func auditCalendarTests(_ t: TestRunner) {
    t.suite("new-08 day totals across DST and midnight conserve every unit") { t in
        var amsterdam = Calendar(identifier: .gregorian)
        amsterdam.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            amsterdam.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        // 2026-03-29 is 23 hours long (02:00 -> 03:00), 2026-10-25 is 25 hours long.
        let cases: [(String, Date, Date, Date, Date)] = [
            ("spring forward", local(2026, 3, 28, 23, 30), local(2026, 3, 29, 3, 30), local(2026, 3, 28, 0), local(2026, 3, 29, 0)),
            ("fall back", local(2026, 10, 24, 23, 30), local(2026, 10, 25, 3, 30), local(2026, 10, 24, 0), local(2026, 10, 25, 0)),
        ]
        for (label, start, end, firstDay, secondDay) in cases {
            let wall = end.timeIntervalSince(start)
            let session = WalkSession(id: label, startedAt: start, endedAt: end, activeDurationS: Int(wall), distanceM: 6_001, steps: 9_001, caloriesKcal: 120, exportedToHealth: false)
            var d1 = DayTotals(day: firstDay), d2 = DayTotals(day: secondDay)
            d1.add(session, calendar: amsterdam)
            d2.add(session, calendar: amsterdam)
            t.expectEqual(d1.distanceM + d2.distanceM, 6_001, "\(label): distance conserved across the two days")
            t.expectEqual(d1.steps + d2.steps, 9_001, "\(label): steps conserved")
            t.expectEqual(d1.activeDurationS + d2.activeDurationS, Int(wall), "\(label): time conserved")
            t.expectEqual(d1.caloriesKcal + d2.caloriesKcal, 120, accuracy: 0.0001, "\(label): calories conserved")
            // The 30 minutes before midnight and the rest after it.
            t.expectEqual(Double(d1.activeDurationS), 1_800, accuracy: 1, "\(label): the first day holds the half hour before midnight")

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-new08-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = SessionStore(url: dir.appendingPathComponent("sessions.json"))
            _ = store.append(session)
            let series = store.days(from: firstDay, through: secondDay, calendar: amsterdam)
            t.expectEqual(series.map(\.distanceM).reduce(0, +), 6_001, "\(label): the day series conserves distance")
            t.expectEqual(series.count, 2, "\(label): two calendar days")
        }
    }

    t.suite("new-09 unit conversions are exact and round-trip") { t in
        t.expectEqual(Z1Units.metersToMiles(1_609.344), 1, accuracy: 1e-12, "one mile")
        t.expectEqual(Z1Units.kmhToMph(1.609344), 1, accuracy: 1e-12, "1.609344 km/h is 1 mph")
        t.expectEqual(Z1Units.mphToKmh(1), 1.609344, accuracy: 1e-12, "1 mph in km/h")
        t.expectEqual(Z1Units.metersToFeet(0.3048), 1, accuracy: 1e-12, "one foot")
        for kmh in stride(from: 0.5, through: 12.0, by: 0.1) {
            if abs(Z1Units.mphToKmh(Z1Units.kmhToMph(kmh)) - kmh) > 1e-9 { t.check(false, "speed round trip at \(kmh)"); break }
        }
        // 6.4 km/h, the pad's top speed, reads 3.98 mph and 4.0 within a tenth.
        t.expectEqual((Z1Units.kmhToMph(6.4) * 10).rounded() / 10, 4.0, "top speed displays as 4.0 mph")
    }
}

// MARK: - pacing, Start hold, reload, wiring

public func auditDriverPacingTests(_ t: TestRunner) async {
    await t.suite("new-10 queued commands keep the firmware's write spacing") { t in
        let pad = ScriptedPad()
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
        do {
            try await driver.connect()
            try await driver.start()
            let before = pad.controlWriteTimes.count
            // Three commands queued inside one 400 ms window.
            async let first: Void = driver.setSpeed(2.0)
            async let second: Void = driver.setSpeed(2.2)
            async let third: Void = driver.setSpeed(2.4)
            _ = try await (first, second, third)
            let times = Array(pad.controlWriteTimes.dropFirst(max(0, before - 1)))
            t.expectEqual(times.count, 4, "Start and three speed writes")
            let gaps = zip(times, times.dropFirst()).map { $0.1 - $0.0 }
            t.check(gaps.allSatisfy { $0 >= .milliseconds(380) }, "every control write is at least 400 ms after the last (gaps: \(gaps.map { Int($0.components.attoseconds / 1_000_000_000_000_000) + Int($0.components.seconds) * 1000 }) ms)")
        } catch { t.check(false, "pacing fixture: \(error)") }
        await driver.disconnect()
    }

    await t.suite("new-11 a Start that did nothing does not stay on screen") { t in
        let pad = ScriptedPad()
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated(), startHold: .milliseconds(300))
        do {
            try await driver.connect()
            try await driver.start()
            t.check(await driver.status.beltRunning, "an accepted Start shows running at once")
            let cleared = await waitUntil(2) { await !driver.status.beltRunning }
            t.check(cleared, "with no telemetry the hold ends by itself and the button goes back to Start")

            // A Start that works is not undone by the expiry.
            try await driver.start()
            pad.sendTelemetry(speed: 200, elapsed: 3, distance: 2)
            _ = await waitUntil { await driver.status.speedKmh > 0 }
            try? await Task.sleep(for: .milliseconds(600))
            t.check(await driver.status.beltRunning, "a belt that is moving stays running past the hold")
        } catch { t.check(false, "start-hold fixture: \(error)") }
        await driver.disconnect()
    }
}

public func auditStoreWiringTests(_ t: TestRunner) {
    let base = Date(timeIntervalSince1970: 2_100_000_000)
    func walk(_ id: String, start: Date, minutes: Int = 30) -> WalkSession {
        WalkSession(id: id, startedAt: start, endedAt: start.addingTimeInterval(Double(minutes * 60)), activeDurationS: minutes * 60, distanceM: minutes * 55, steps: minutes * 85, caloriesKcal: Double(minutes) * 3, exportedToHealth: false)
    }

    t.suite("new-12 a failed read cannot shrink the history held in memory") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-new12-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        for index in 0..<3 { _ = store.append(walk("w\(index)", start: base.addingTimeInterval(Double(index) * 7_200))) }
        do {
            // The next read finds garbage (a transient failure, a bad sync).
            let good = try Data(contentsOf: url)
            try Data("not json".utf8).write(to: url)
            store.reload()
            t.expectEqual(store.sessions.count, 3, "history in memory survives an unreadable file")
            t.check(store.append(walk("w3", start: base.addingTimeInterval(30_000))), "and the next walk still saves")
            t.expectEqual(SessionStore(url: url).sessions.map(\.id), ["w0", "w1", "w2", "w3"], "the file written afterwards holds all four")

            // A clean file is trusted: a walk removed by hand stays removed.
            try good.write(to: url)
            let edited = SessionStore(url: dir.appendingPathComponent("other/sessions.json"))
            _ = edited.append(walk("w0", start: base))
            _ = edited.append(walk("w1", start: base.addingTimeInterval(7_200)))
            try Data(contentsOf: dir.appendingPathComponent("other/sessions.json")).write(to: url)
            store.reload()
            t.expectEqual(store.sessions.map(\.id), ["w0", "w1"], "a readable file is taken as it is")
        } catch { t.check(false, "reload fixture: \(error)") }
    }

    t.suite("new-13 Health queue wiring: cutover is kept, damaged cutover is recovered") { t in
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("z1-new13-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionsURL = dir.appendingPathComponent("sessions.json")
        let queueURL = dir.appendingPathComponent("queue/health-queue.json")
        let cutoverURL = dir.appendingPathComponent("health-queue-cutover.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()
        do {
            // Before the queue existed: one finished walk from three hours ago.
            let older = walk("older", start: now.addingTimeInterval(-3 * 3_600 - 1_800))
            _ = SessionStore(url: sessionsURL).append(older)

            // First start with the queue: the cutover is written, nothing old is exported.
            _ = SessionStore(url: sessionsURL, healthQueueURL: queueURL)
            let created = try decoder.decode(Date.self, from: Data(contentsOf: cutoverURL))
            t.check(abs(created.timeIntervalSinceNow) < 10, "the cutover is written at first start")
            t.check(!FileManager.default.fileExists(atPath: queueURL.path), "history from before the cutover is not exported")

            // A restart keeps it exactly.
            let before = try Data(contentsOf: cutoverURL)
            _ = SessionStore(url: sessionsURL, healthQueueURL: queueURL)
            t.expectEqual(try Data(contentsOf: cutoverURL), before, "a restart keeps the original cutover")

            // With the cutover three hours back, a walk after it is queued once it is old enough.
            try encoder.encode(now.addingTimeInterval(-3 * 3_600)).write(to: cutoverURL)
            let store = SessionStore(url: sessionsURL, healthQueueURL: queueURL)
            t.check(!FileManager.default.fileExists(atPath: queueURL.path), "the older walk still predates the cutover")
            _ = store.append(walk("after", start: now.addingTimeInterval(-2 * 3_600 - 1_800)))
            t.expectEqual((try? HealthQueue(url: queueURL).queuedSessionIDs()) ?? [], Set(["after"]), "a walk after the cutover reaches the Shortcut queue")

            // A damaged cutover must not switch the queue off for good.
            try Data("{broken".utf8).write(to: cutoverURL)
            try? FileManager.default.removeItem(at: queueURL)
            let recovered = SessionStore(url: sessionsURL, healthQueueURL: queueURL)
            let rebuilt = try? decoder.decode(Date.self, from: Data(contentsOf: cutoverURL))
            t.check(rebuilt != nil && abs(rebuilt!.timeIntervalSinceNow) < 10, "a damaged cutover is replaced by one from now")
            _ = recovered.append(walk("later", start: now.addingTimeInterval(-3_000)))
            t.check(recovered.sessions.contains { $0.id == "later" }, "and the store keeps working")
        } catch { t.check(false, "wiring fixture: \(error)") }
    }
}

// MARK: - parsers and tracker under arbitrary input

/// Small deterministic generator so a failure reproduces.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public func auditRobustnessTests(_ t: TestRunner) {
    t.suite("new-15 parsers never trap on arbitrary bytes") { t in
        var rng = SplitMix(state: 0xC0FFEE)
        var parsedFrames = 0
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...24, using: &rng)
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = Z1Protocol.parseTreadmillData(bytes)
            _ = Z1Protocol.parsePropertyRecords(bytes)
            if Z1Protocol.parseFrame(bytes) != nil { parsedFrames += 1 }
            // Slices keep their parent's indices; the parsers must not assume zero.
            if length > 3 { _ = Z1Protocol.parseTreadmillData(bytes.dropFirst(2)); _ = Z1Protocol.parseFrame(bytes.dropFirst(1)) }
        }
        t.check(true, "20,000 random buffers parsed without trapping (\(parsedFrames) happened to be valid frames)")
        // Every frame the driver builds parses back.
        for cmd0 in [UInt8(0x71), 0x72, 0x77] {
            for size in 0...40 {
                let payload = Data((0..<size).map { UInt8($0 & 0xFF) })
                let frame = Z1Protocol.buildFrame(cmd0: cmd0, cmd1: 0x01, data: payload)
                if Z1Protocol.parseFrame(frame)?.data != payload { t.check(false, "frame round trip \(cmd0) \(size)"); return }
            }
        }
        t.check(true, "built frames round-trip")
        t.check(Z1Protocol.unlockFrame(deviceName: "").isEmpty && Z1Protocol.unlockFrame(deviceName: "abc").isEmpty, "a name too short to unlock returns no frame instead of trapping")
    }

    // (the driver half of this fuzz needs a running pad, see auditDriverFuzzTests)
    t.suite("new-16 tracker invariants hold for random telemetry, drops and restarts") { t in
        var rng = SplitMix(state: 20_261_012)
        var violations: [String] = []
        for run in 0..<300 {
            var tracker = RemoteSessionTracker()
            var now = Date(timeIntervalSince1970: 2_000_000_000)
            var elapsed = Int.random(in: 0...100, using: &rng), distance = Int.random(in: 0...80, using: &rng), steps = Int.random(in: 0...3000, using: &rng)
            var seen = Set<String>()
            var counter = 0
            func id() -> String { counter += 1; return "run\(run)-\(counter)" }
            for _ in 0..<150 {
                now.addTimeInterval(Double(Int.random(in: 1...(Bool.random(using: &rng) ? 5 : 900), using: &rng)))
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: tracker.markConnectionDrop(at: now)
                case 1:
                    if let blob = try? JSONEncoder().encode(tracker), let restored = try? JSONDecoder().decode(RemoteSessionTracker.self, from: blob) { tracker = restored }
                case 2: elapsed = Int.random(in: 0...50, using: &rng); distance = Int.random(in: 0...40, using: &rng); steps = Int.random(in: 0...90, using: &rng) // pad counter reset
                default:
                    let running = Int.random(in: 0..<4, using: &rng) != 0
                    if running { elapsed += 1; distance += Int.random(in: 0...2, using: &rng); steps += Int.random(in: 0...3, using: &rng) }
                    var status = Z1Treadmill.Status()
                    status.phase = .ready; status.hasTelemetry = true
                    status.beltRunning = running; status.speedKmh = running ? 3.0 : 0
                    status.elapsedS = elapsed; status.distanceM = distance; status.steps = steps
                    status.padSteps = Bool.random(using: &rng) ? steps + 4_000 : nil
                    let observation = tracker.observe(status, at: now, newSessionID: id)
                    for walk in observation.completed {
                        if walk.activeDurationS < 0 || walk.distanceM < 0 || walk.steps < 0 { violations.append("negative totals in \(walk.id)") }
                        if walk.endedAt < walk.startedAt { violations.append("\(walk.id) ends before it starts") }
                        if !seen.insert(walk.id).inserted { violations.append("duplicate \(walk.id)") }
                        tracker.acknowledgeLog(sessionID: walk.id)
                    }
                }
                if let open = tracker.openWalkTotals {
                    if open.activeDurationS < 0 || open.distanceM < 0 || open.steps < 0 { violations.append("negative open totals \(open.id)") }
                    if open.endedAt < open.startedAt { violations.append("open walk \(open.id) ends before it starts") }
                }
            }
            // Far in the future every walk closes and nothing stays open.
            let end = tracker.finalizeIfDue(at: now.addingTimeInterval(86_400 * 3))
            _ = end
            tracker.markConnectionDrop(at: now.addingTimeInterval(86_400 * 3))
            let final = tracker.finalizeIfDue(at: now.addingTimeInterval(86_400 * 4))
            var ids = Set<String>()
            for walk in final.completed {
                if !ids.insert(walk.id).inserted { violations.append("duplicate pending id \(walk.id)") }
                tracker.acknowledgeLog(sessionID: walk.id)
            }
            if tracker.openWalkTotals != nil { violations.append("run \(run): a walk stayed open after a drop and four days") }
            if tracker.hasPendingLogs { violations.append("run \(run): pending logs remain after acknowledgement") }
            if violations.count > 5 { break }
        }
        t.check(violations.isEmpty, "300 random timelines: \(violations.prefix(5))")
    }
}

public func auditDriverFuzzTests(_ t: TestRunner) async {
    await t.suite("new-17 the driver survives garbage notifications and keeps its counters sane") { t in
        let pad = ScriptedPad()
        pad.vendor = true
        pad.deviceName = "KS-HD-Z1D"
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
        do {
            try await driver.connect()
            var rng = SplitMix(state: 99)
            let channels = [Z1Constants.charTreadmillData, Z1Constants.charFitnessMachineStatus, Z1Constants.charControlPoint, Z1Constants.charSupplementNotify]
            var elapsed = 0
            for index in 0..<3_000 {
                let channel = channels[Int.random(in: 0..<channels.count, using: &rng)]
                let length = Int.random(in: 0...20, using: &rng)
                pad.sendRaw(channel, Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }))
                if index % 7 == 0 {
                    elapsed += 1
                    pad.sendTelemetry(speed: Int.random(in: 0...700, using: &rng), elapsed: elapsed, distance: elapsed, steps: elapsed * 2)
                }
            }
            pad.sendTelemetry(speed: 300, elapsed: 5_000, distance: 4_000, steps: 6_000)
            let reached = await waitUntil(5) { await driver.status.elapsedS == 5_000 }
            t.check(reached, "a valid frame is still understood after thousands of garbage ones")
            let status = await driver.status
            t.check(status.elapsedS >= 0 && status.distanceM >= 0 && status.steps >= 0 && status.caloriesKcal >= 0 && status.caloriesKcal.isFinite, "counters stay non-negative and finite")
            t.expectEqual(status.phase, .ready, "garbage does not drop the link")
        } catch { t.check(false, "driver fuzz fixture: \(error)") }
        await driver.disconnect()
    }
}
