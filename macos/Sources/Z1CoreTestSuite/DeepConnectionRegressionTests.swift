import CoreBluetooth
import Foundation
import Z1Core

/// Exposes the period in which native disconnect has been requested but has
/// not completed. All operations remain on the in-memory ScriptedPad.
private final class GatedDisconnectPad: Z1PadTransport, @unchecked Sendable {
    let base = ScriptedPad()
    let gate = Gate()
    let profileGate = Gate()
    let holdProfile: Bool
    private let lock = NSLock()
    private var disconnects = 0
    private var connections = 0
    init(holdProfile: Bool = false) { self.holdProfile = holdProfile; base.echo = .none }
    var disconnectCount: Int { lock.withLock { disconnects } }
    var connectCount: Int { lock.withLock { connections } }
    var notifications: AsyncStream<(String, Data)> { base.notifications }
    var peripheralIdentifier: UUID? { nil }
    var onDisconnect: (@Sendable () -> Void)? {
        get { base.onDisconnect }
        set { base.onDisconnect = newValue }
    }
    func waitPoweredOn() async throws {}
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String? { nil }
    func scanForTreadmill(timeout: TimeInterval) async throws -> String { base.deviceName }
    func connect(timeout: TimeInterval) async throws {
        lock.withLock { connections += 1 }
        try await base.connect(timeout: timeout)
    }
    func discoverProfile(services: [CBUUID], characteristics: [CBUUID]) async throws {
        if holdProfile { await profileGate.wait() }
    }
    func hasCharacteristic(_ uuid: CBUUID) -> Bool { base.hasCharacteristic(uuid) }
    func setNotify(_ uuid: CBUUID, enable: Bool) async throws {}
    func read(_ uuid: CBUUID) async throws -> Data { try await base.read(uuid) }
    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws {
        try await base.write(uuid, data, withResponse: withResponse)
    }
    func disconnect() async {
        let attempt = lock.withLock { disconnects += 1; return disconnects }
        let callback = onDisconnect
        if attempt == 1 { await gate.wait() }
        await base.disconnect()
        callback?()
    }
    func cancelConnectionNow() { base.cancelConnectionNow() }
}

public func deepConnectionRegressionTests(_ t: TestRunner) async {
    await protocolBoundaryRegressionTests(t)
    await t.suite("deep connection lifecycle") { t in
        let overlapping = GatedDisconnectPad()
        let driver = Z1Treadmill(transport: overlapping, defaults: CountingDefaults.isolated())
        do {
            try await driver.connect()
            let first = Task { await driver.disconnect() }
            t.check(await waitUntil { overlapping.gate.hasEntered }, "first teardown reaches its gate")
            let second = Task { await driver.disconnect() }
            t.check(await waitUntil { await driver.status.phase == .disconnected }, "disconnect retires published link before waiting on native teardown")
            let reconnect = Task { try await driver.connect() }
            _ = await waitUntil {
                let phase = await driver.status.phase
                return phase == .scanning || phase == .ready
            }
            t.expectEqual(overlapping.connectCount, 1, "reconnect waits for outstanding native teardown")
            t.expectEqual(overlapping.disconnectCount, 1, "overlapping disconnect callers share one teardown")
            do {
                try await driver.start()
                t.check(false, "retired link must reject Start during teardown")
            } catch { t.check(true, "retired link rejects Start during teardown") }
            overlapping.gate.release()
            await first.value
            await second.value
            try await reconnect.value
            t.expectEqual(await driver.status.phase, .ready, "late teardown completions cannot reset the new connection")
            t.check(overlapping.base.isLinked, "new link remains connected after both old disconnects complete")
        } catch {
            overlapping.gate.release()
            t.check(false, "overlapping teardown fixture: \(error)")
        }
        await driver.disconnect()

        let setupLost = GatedDisconnectPad(holdProfile: true)
        setupLost.gate.release()
        let setupDriver = Z1Treadmill(transport: setupLost, defaults: CountingDefaults.isolated())
        let setup = Task { try await setupDriver.connect() }
        t.check(await waitUntil { setupLost.profileGate.hasEntered }, "setup reaches profile discovery gate")
        setupLost.base.dropLink()
        try? await Task.sleep(for: .milliseconds(40))
        setupLost.profileGate.release()
        switch await setup.result {
        case .success: t.check(false, "link lost during setup must fail connection")
        case .failure: t.check(true, "link lost during setup fails connection")
        }
        t.expectEqual(await setupDriver.status.phase, .error, "successful late GATT callback cannot report ready after link loss")
        await setupDriver.disconnect()

        let delayed = ScriptedPad()
        delayed.echo = .late(milliseconds: 120)
        let delayedDriver = Z1Treadmill(transport: delayed, defaults: CountingDefaults.isolated())
        do {
            try await delayedDriver.connect()
            await delayedDriver.disconnect()
            try await delayedDriver.connect()
            try await Task.sleep(for: .milliseconds(180))
            t.expectEqual(await delayedDriver.status.phase, .ready, "old captured disconnect callback cannot drop an immediate reconnect")
            delayed.dropLink()
            t.check(await waitUntil { await delayedDriver.status.phase == .disconnected }, "new connection callback still reports genuine link loss")
        } catch { t.check(false, "delayed disconnect fixture: \(error)") }
        await delayedDriver.disconnect()

        let latePackets = ScriptedPad()
        let packetDriver = Z1Treadmill(transport: latePackets, defaults: CountingDefaults.isolated())
        do {
            try await packetDriver.connect()
            await packetDriver.disconnect()
            latePackets.sendTelemetry(speed: 300, elapsed: 300, distance: 250)
            latePackets.sendRaw(Z1Constants.charFitnessMachineStatus, Data([4]))
            try await Task.sleep(for: .milliseconds(40))
            let retired = await packetDriver.status
            t.check(!retired.hasTelemetry && !retired.beltRunning && retired.speedKmh == 0, "late telemetry/status cannot revive a disconnected belt")
            latePackets.holdScan = true
            let reconnect = Task { try await packetDriver.connect() }
            _ = await waitUntil { latePackets.scanGate.hasEntered }
            latePackets.sendTelemetry(speed: 300, elapsed: 600, distance: 500)
            try await Task.sleep(for: .milliseconds(40))
            t.check(await !packetDriver.status.hasTelemetry, "scanning cannot publish packets from the previous link")
            latePackets.scanGate.release()
            try await reconnect.value
            latePackets.sendTelemetry(speed: 200, elapsed: 30, distance: 16)
            t.check(await waitUntil { await packetDriver.status.hasTelemetry }, "current connection continues receiving telemetry")
        } catch {
            latePackets.scanGate.release()
            t.check(false, "late packet fixture: \(error)")
        }
        await packetDriver.disconnect()
    }
}

private final class ProtocolValidationPad: Z1PadTransport, @unchecked Sendable {
    let base = ScriptedPad()
    let identity: UUID?
    let failProfile: Bool
    let propertyResult: UInt8?
    let rangeOverride: Data?
    let revokeSpeedControlOnce: Bool
    private let lock = NSLock()
    private var opcodes: [UInt8] = []
    var commands: [UInt8] { lock.withLock { opcodes } }
    init(vendor: Bool = false, identity: UUID? = nil, failProfile: Bool = false,
         propertyResult: UInt8? = 0, rangeOverride: Data? = nil, revokeSpeedControlOnce: Bool = false) {
        base.vendor = vendor
        if vendor { base.deviceName = "KS-HD-Z1D" }
        self.identity = identity
        self.failProfile = failProfile
        self.propertyResult = propertyResult
        self.rangeOverride = rangeOverride
        self.revokeSpeedControlOnce = revokeSpeedControlOnce
    }
    var notifications: AsyncStream<(String, Data)> { base.notifications }
    var peripheralIdentifier: UUID? { identity }
    var onDisconnect: (@Sendable () -> Void)? {
        get { base.onDisconnect }
        set { base.onDisconnect = newValue }
    }
    func waitPoweredOn() async throws {}
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String? { base.deviceName }
    func scanForTreadmill(timeout: TimeInterval) async throws -> String { try await base.scanForTreadmill(timeout: timeout) }
    func connect(timeout: TimeInterval) async throws { try await base.connect(timeout: timeout) }
    func discoverProfile(services: [CBUUID], characteristics: [CBUUID]) async throws {
        if failProfile { throw BLETransportError.missingCharacteristics }
    }
    func hasCharacteristic(_ uuid: CBUUID) -> Bool { base.hasCharacteristic(uuid) }
    func setNotify(_ uuid: CBUUID, enable: Bool) async throws {}
    func read(_ uuid: CBUUID) async throws -> Data {
        if uuid == Z1Constants.charSupportedSpeedRange, let rangeOverride { return rangeOverride }
        return try await base.read(uuid)
    }
    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws {
        if uuid == Z1Constants.charControlPoint, let op = data.first {
            let speedAttempt = lock.withLock {
                opcodes.append(op)
                return opcodes.filter { $0 == Z1Constants.opSetTargetSpeed }.count
            }
            if revokeSpeedControlOnce, op == Z1Constants.opSetTargetSpeed, speedAttempt == 1 {
                base.sendControlReply(opcode: op, result: 5)
                return
            }
        }
        if uuid == Z1Constants.charSupplementWrite, let frame = Z1Protocol.parseFrame(data),
           frame.cmd0 == 0x72, frame.cmd1 == 1, let id = frame.data.first {
            let payload = Data([id] + (propertyResult.map { [$0] } ?? []))
            base.sendRaw(Z1Constants.charSupplementNotify, Z1Protocol.buildFrame(cmd0: 0x72, cmd1: 0x81, data: payload))
            return
        }
        try await base.write(uuid, data, withResponse: withResponse)
    }
    func disconnect() async { await base.disconnect() }
    func cancelConnectionNow() { base.cancelConnectionNow() }
}

private func protocolBoundaryRegressionTests(_ t: TestRunner) async {
    await t.suite("protocol packet and acknowledgement boundaries") { t in
        // SIG GATT supplement: elevation gain is two u16s, each pace is one
        // u16, and force/power are two s16s. KingSmith steps follow bit 12.
        let full = Data([
            0xFE, 0x3F, 0x2C, 1, 0x36, 1, 123, 0, 0,
            100, 0, 200, 0, 10, 0, 20, 0, 0x90, 1, 0xF4, 1,
            60, 0, 100, 0, 2, 80, 30, 0x84, 3, 120, 0, 7, 0, 8, 0, 200, 0,
        ])
        let parsed = Z1Protocol.parseTreadmillData(full)
        t.expectEqual(parsed.speedKmh, 3, "full FTMS record speed")
        t.expectEqual(parsed.calories, 60, "optional fields keep energy aligned")
        t.expectEqual(parsed.elapsedS, 900, "optional fields keep elapsed time aligned")
        t.expectEqual(parsed.steps, 200, "force/power precede vendor step count")
        for end in 0..<full.count {
            t.check(Z1Protocol.parseTreadmillData(Data(full.prefix(end))).raw.isEmpty, "truncated FTMS prefix \(end) is rejected whole")
        }

        let malformedPad = ScriptedPad()
        let malformedDefaults = CountingDefaults.isolated()
        let writes = malformedDefaults.log
        let malformedDriver = Z1Treadmill(transport: malformedPad, defaults: malformedDefaults)
        do {
            try await malformedDriver.connect()
            malformedPad.sendRaw(Z1Constants.charTreadmillData, Data([0x04, 0x24, 0x2C, 1]))
            malformedPad.sendRaw(Z1Constants.charTreadmillData, Data([0x04]))
            try await Task.sleep(for: .milliseconds(40))
            t.check(await !malformedDriver.status.hasTelemetry, "malformed packets never establish telemetry freshness")
            t.check(writes.keys.isEmpty, "malformed initial packets do not persist fictitious counters")
            malformedPad.sendTelemetry(speed: 300, elapsed: 30, distance: 25)
            _ = await waitUntil { await malformedDriver.status.hasTelemetry }
            let before = await malformedDriver.status
            try await Task.sleep(for: .milliseconds(100))
            malformedPad.sendRaw(Z1Constants.charTreadmillData, Data([0x04, 0x24, 0x2C, 1]))
            try await Task.sleep(for: .milliseconds(40))
            t.expectEqual(await malformedDriver.status, before, "malformed packet changes neither live counters nor calories")
        } catch { t.check(false, "malformed telemetry fixture: \(error)") }
        await malformedDriver.disconnect()

        for result: UInt8? in [4, nil, 0] {
            let pad = ProtocolValidationPad(vendor: true, propertyResult: result)
            let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
            do {
                try await driver.connect()
                for property in [1, 10] {
                    do {
                        if property == 1 { try await driver.setDisplayUnits(imperial: true) }
                        else { try await driver.sleep() }
                        t.check(result == 0, "setting \(property) succeeds only on an explicit zero result")
                    } catch Z1Error.propertyRefused(let id, _) {
                        t.check(result != 0 && Int(id) == property, "rejected or incomplete setting reply reaches caller")
                    }
                }
                let state = await driver.status
                t.expectEqual(state.properties[1], result == 0 ? 3 : 1, "units cache follows accepted setting only")
                t.expectEqual(state.properties[10], result == 0 ? 0x240 : 0x200, "sleep cache follows accepted setting only")
            } catch { t.check(false, "property validation fixture: \(error)") }
            await driver.disconnect()
        }

        for remembered in [false, true] {
            let suite = "z1tests.profile.\(UUID().uuidString)"
            let id = UUID()
            let preferences = UserDefaults(suiteName: suite)!
            if remembered { preferences.set(id.uuidString, forKey: "z1.knownPeripheralID") }
            let pad = ProtocolValidationPad(identity: id, failProfile: true)
            let driver = Z1Treadmill(transport: pad, defaults: UserDefaults(suiteName: suite)!)
            do { try await driver.connect(); t.check(false, "invalid profile must fail") }
            catch { t.check(true, "invalid profile rejected") }
            t.expectNil(preferences.string(forKey: "z1.knownPeripheralID"), "invalid profile cannot pin future reconnects (remembered=\(remembered))")
            await driver.disconnect()
            preferences.removePersistentDomain(forName: suite)
        }

        let invalidRangePad = ProtocolValidationPad(vendor: true, rangeOverride: Data([0, 0, 0, 0]))
        let invalidRangeDriver = Z1Treadmill(transport: invalidRangePad, defaults: CountingDefaults.isolated())
        do {
            try await invalidRangeDriver.connect()
            let state = await invalidRangeDriver.status
            t.expectEqual(state.minSpeedKmh, 1.6, "invalid range retains Z1 minimum")
            t.expectEqual(state.maxSpeedKmh, 6.4, "invalid range retains Z1 maximum")
        } catch { t.check(false, "range validation fixture: \(error)") }
        await invalidRangeDriver.disconnect()

        let lostControlPad = ProtocolValidationPad(revokeSpeedControlOnce: true)
        let lostControlDriver = Z1Treadmill(transport: lostControlPad, defaults: CountingDefaults.isolated())
        do {
            try await lostControlDriver.connect()
            try await lostControlDriver.start()
            try await lostControlDriver.setSpeed(3)
            t.expectEqual(lostControlPad.commands, [0, 7, 2, 0, 2], "FTMS result5 reacquires control and retries exactly once")
        } catch { t.check(false, "control reacquisition fixture: \(error)") }
        await lostControlDriver.disconnect()
    }
}
