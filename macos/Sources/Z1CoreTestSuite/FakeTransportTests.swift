import CoreBluetooth
import Foundation
import Z1Core

/// Scripted in-memory BLE boundary. It never creates a CBCentralManager.
private final class FakePadTransport: Z1PadTransport, @unchecked Sendable {
    enum ScriptError: Error, LocalizedError {
        case connectFailed
        var errorDescription: String? { "scripted connect failure" }
    }

    let notifications: AsyncStream<(String, Data)>
    private let yieldNotification: AsyncStream<(String, Data)>.Continuation
    private let lock = NSLock()
    private var disconnectHandler: (@Sendable () -> Void)?
    private var writes: [Data] = []
    var failConnect = false
    var refuseSpeed = false
    var refuseFirstStart = false
    var confirmStop = false
    var peripheralIdentifier: UUID? { nil }

    var onDisconnect: (@Sendable () -> Void)? {
        get { lock.withLock { disconnectHandler } }
        set { lock.withLock { disconnectHandler = newValue } }
    }

    init() {
        var continuation: AsyncStream<(String, Data)>.Continuation!
        notifications = AsyncStream { continuation = $0 }
        yieldNotification = continuation
    }

    var commandOpcodes: [UInt8] {
        lock.withLock { writes.compactMap(\.first) }
    }

    func waitPoweredOn() async throws {}
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String? { nil }
    func scanForTreadmill(timeout: TimeInterval) async throws -> String { "UREVO Test Treadmill" }
    func connect(timeout: TimeInterval) async throws {
        if failConnect { throw ScriptError.connectFailed }
    }
    func discoverProfile(services: [CBUUID], characteristics: [CBUUID]) async throws {}
    func hasCharacteristic(_ uuid: CBUUID) -> Bool { uuid == Z1Constants.charControlPoint }
    func setNotify(_ uuid: CBUUID, enable: Bool) async throws {}
    func read(_ uuid: CBUUID) async throws -> Data { Data() }

    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws {
        guard uuid == Z1Constants.charControlPoint, let opcode = data.first else { return }
        lock.withLock { writes.append(data) }
        if opcode == Z1Constants.opStartOrResume {
            // A late reply to an unrelated command must not satisfy Start.
            yieldNotification.yield((uuid.uuidString, Data([0x80, Z1Constants.opStopOrPause, 0x03])))
        }
        if opcode == Z1Constants.opStartOrResume, refuseFirstStart,
           commandOpcodes.filter({ $0 == Z1Constants.opStartOrResume }).count == 1 {
            sendTelemetry(speed: 300, elapsed: 1, distance: 1)
            yieldNotification.yield((uuid.uuidString, Data([0x80, opcode, 4])))
            return
        }
        if opcode == Z1Constants.opStopOrPause, confirmStop { sendStopEvent() }
        let result: UInt8 = opcode == Z1Constants.opSetTargetSpeed && refuseSpeed ? 4 : 1
        yieldNotification.yield((uuid.uuidString, Data([0x80, opcode, result])))
    }

    func sendTelemetry(speed: Int, elapsed: Int, distance: Int) {
        let bytes: [UInt8] = [0x04, 0x04, UInt8(speed & 255), UInt8(speed >> 8), UInt8(distance & 255), UInt8((distance >> 8) & 255), UInt8((distance >> 16) & 255), UInt8(elapsed & 255), UInt8(elapsed >> 8)]
        yieldNotification.yield((Z1Constants.charTreadmillData.uuidString, Data(bytes)))
    }

    func sendStopEvent() {
        yieldNotification.yield((Z1Constants.charFitnessMachineStatus.uuidString, Data([2])))
    }

    func disconnect() async { onDisconnect?() }
    func cancelConnectionNow() { onDisconnect?() }
}

public func fakeTransportRegressionTests(_ t: TestRunner) async {
    await t.suite("fake BLE transport") { t in
        // The injected fake guarantees the test cannot scan or connect to a pad.
        let fake = FakePadTransport()
        let treadmill = Z1Treadmill(transport: fake)
        do {
            try await treadmill.connect()
            let ready = await treadmill.status
            t.expectEqual(ready.phase, .ready, "fake profile reaches ready")
            try await treadmill.start()
            let moving = await treadmill.status
            t.expectEqual(moving.beltRunning, true, "Start accepts its matching CP opcode")
            t.expectEqual(
                fake.commandOpcodes,
                [Z1Constants.opRequestControl, Z1Constants.opStartOrResume],
                "control request precedes Start and late Stop reply is ignored"
            )
            await treadmill.disconnect()
            let stopped = await treadmill.status
            t.expectEqual(stopped.phase, .disconnected, "intentional disconnect clears phase")
        } catch {
            t.check(false, "scripted driver flow: \(error)")
        }

        let stopFake = FakePadTransport()
        stopFake.refuseSpeed = true
        let stopDriver = Z1Treadmill(transport: stopFake)
        do {
            try await stopDriver.connect()
            try await stopDriver.start()
            let beforeInvalid = stopFake.commandOpcodes.count
            for value in [Double.nan, Double.infinity, -Double.infinity] {
                do {
                    try await stopDriver.setSpeed(value)
                    t.check(false, "nonfinite speed rejected")
                } catch { t.check(true, "nonfinite speed rejected") }
            }
            t.expectEqual(stopFake.commandOpcodes.count, beforeInvalid, "invalid inputs send no physical commands")
            let speed = Task { try await stopDriver.setSpeed(3.0) }
            for _ in 0..<200 {
                if stopFake.commandOpcodes.contains(Z1Constants.opSetTargetSpeed) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            t.check(stopFake.commandOpcodes.contains(Z1Constants.opSetTargetSpeed), "speed refusal fixture reached transport")
            _ = try await stopDriver.stop()
            do {
                try await speed.value
                t.check(false, "Stop invalidates refused speed retry")
            } catch is CancellationError {
                t.check(true, "Stop invalidates refused speed retry")
            } catch { t.check(false, "expected speed cancellation, got \(error)") }
            t.expectEqual(stopFake.commandOpcodes.filter { $0 == Z1Constants.opSetTargetSpeed }.count, 1, "no speed retry is sent after Stop")
            t.expectEqual(stopFake.commandOpcodes.last, Z1Constants.opStopOrPause, "Stop is final control command")
            await stopDriver.disconnect()
        } catch { t.check(false, "stop-priority fixture: \(error)") }

        let startFake = FakePadTransport()
        startFake.refuseFirstStart = true
        startFake.confirmStop = true
        let startDriver = Z1Treadmill(transport: startFake)
        do {
            try await startDriver.connect()
            let start = Task { try await startDriver.start() }
            for _ in 0..<300 {
                if await startDriver.status.beltRunning { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let beforeStop = await startDriver.status
            t.check(beforeStop.beltRunning, "Start retry fixture has device motion")
            _ = try await startDriver.stop()
            do {
                try await start.value
                t.check(false, "Stop must invalidate the older Start")
            } catch is CancellationError {
                t.check(true, "Stop invalidates the older Start")
            }
            t.expectEqual(startFake.commandOpcodes, [0, 7, 8], "no Start retry after Stop")
            let final = await startDriver.status
            t.check(!final.beltRunning && final.speedKmh == 0, "device Stop event clears measured motion")
            await startDriver.disconnect()
        } catch { t.check(false, "Start/Stop priority fixture: \(error)") }

        let telemetryFake = FakePadTransport()
        let telemetryDriver = Z1Treadmill(transport: telemetryFake)
        do {
            try await telemetryDriver.connect()
            telemetryFake.sendTelemetry(speed: 300, elapsed: 900, distance: 750)
            try await Task.sleep(for: .milliseconds(30))
            _ = try await telemetryDriver.stop()
            let accepted = await telemetryDriver.status
            t.check(accepted.stopRequested && accepted.beltRunning && accepted.speedKmh == 3, "Stop acknowledgement is not hardware confirmation")
            var tracker = RemoteSessionTracker()
            _ = tracker.observe(accepted)
            telemetryFake.sendStopEvent()
            try await Task.sleep(for: .milliseconds(30))
            let confirmed = await telemetryDriver.status
            let observation = tracker.observe(confirmed)
            t.check(!confirmed.stopRequested && !confirmed.beltRunning && confirmed.speedKmh == 0, "hardware Stop updates the entire published motion state")
            t.check(observation.finalizationDeadline != nil, "hardware Stop saves without requiring another treadmill frame")
            telemetryFake.sendTelemetry(speed: 300, elapsed: 10, distance: 6)
            try await Task.sleep(for: .milliseconds(30))
            let newRun = await telemetryDriver.status
            t.expectEqual(newRun.elapsedS, 10, "disabled accumulation follows new elapsed counter")
            t.expectEqual(newRun.distanceM, 6, "disabled accumulation follows new distance counter")
            await telemetryDriver.disconnect()
            try await telemetryDriver.connect()
            let reconnecting = await telemetryDriver.status
            t.check(!reconnecting.hasTelemetry && reconnecting.speedKmh == 0, "reconnect does not publish stale speed as fresh telemetry")
            await telemetryDriver.setWeight(75)
            let configured = await telemetryDriver.status
            t.check(!configured.hasTelemetry, "settings changes cannot fabricate fresh telemetry")
            await telemetryDriver.disconnect()
        } catch { t.check(false, "telemetry lifecycle fixture: \(error)") }

        let failedFake = FakePadTransport()
        failedFake.failConnect = true
        let failedDriver = Z1Treadmill(transport: failedFake)
        do {
            try await failedDriver.connect()
            t.check(false, "scripted connect error propagates")
        } catch {
            let state = await failedDriver.status
            t.expectEqual(state.phase, .error, "failed connect stays an error")
            t.check(state.errorMessage?.contains("scripted connect failure") == true, "cleanup keeps original error")
        }
    }
}
