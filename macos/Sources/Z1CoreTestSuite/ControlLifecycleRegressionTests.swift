import CoreBluetooth
import Foundation
import Z1Core

/// Deliberately accepts writes after disconnect, so stale driver work cannot
/// hide behind a real peripheral rejecting it. Never creates a BLE central.
private final class LifecyclePadTransport: Z1PadTransport, @unchecked Sendable {
    let notifications: AsyncStream<(String, Data)>
    private let sink: AsyncStream<(String, Data)>.Continuation
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var writes: [UInt8] = []
    let rejectTelemetry: Bool
    let refuseFirstStop: Bool
    var peripheralIdentifier: UUID? { nil }
    var onDisconnect: (@Sendable () -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    var commands: [UInt8] { lock.withLock { writes } }

    init(rejectTelemetry: Bool = false, refuseFirstStop: Bool = false) {
        self.rejectTelemetry = rejectTelemetry
        self.refuseFirstStop = refuseFirstStop
        let pair = AsyncStream<(String, Data)>.makeStream()
        notifications = pair.stream
        sink = pair.continuation
    }
    func waitPoweredOn() async throws {}
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String? { nil }
    func scanForTreadmill(timeout: TimeInterval) async throws -> String { "Lifecycle Test Pad" }
    func connect(timeout: TimeInterval) async throws {}
    func discoverProfile(services: [CBUUID], characteristics: [CBUUID]) async throws {}
    func hasCharacteristic(_ uuid: CBUUID) -> Bool { uuid == Z1Constants.charControlPoint }
    func setNotify(_ uuid: CBUUID, enable: Bool) async throws {
        if rejectTelemetry, uuid == Z1Constants.charTreadmillData { throw BLETransportError.timeout }
    }
    func read(_ uuid: CBUUID) async throws -> Data { Data() }
    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws {
        guard uuid == Z1Constants.charControlPoint, let opcode = data.first else { return }
        lock.withLock { writes.append(opcode) }
        if refuseFirstStop, opcode == Z1Constants.opStopOrPause,
           commands.filter({ $0 == Z1Constants.opStopOrPause }).count == 1 {
            sink.yield((uuid.uuidString, Data([0x80, opcode, 4])))
        } else {
            reply(opcode)
        }
    }
    func reply(_ opcode: UInt8) {
        sink.yield((Z1Constants.charControlPoint.uuidString, Data([0x80, opcode, 1])))
    }
    func disconnect() async { onDisconnect?() }
    func cancelConnectionNow() { onDisconnect?() }
}

private final class WeakDriverReference {
    weak var value: Z1Treadmill?
    init(_ value: Z1Treadmill?) { self.value = value }
}

public func controlLifecycleRegressionTests(_ t: TestRunner) async {
    await t.suite("control command lifecycle") { t in
        let suite = "Z1-control-lifecycle-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let releasedFake = LifecyclePadTransport()
        var releasedDriver: Z1Treadmill? = Z1Treadmill(transport: releasedFake, defaults: UserDefaults(suiteName: suite)!)
        let weakDriver = WeakDriverReference(releasedDriver)
        do { try await releasedDriver?.connect() }
        catch { t.check(false, "release fixture: \(error)") }
        await releasedDriver?.disconnect()
        releasedDriver = nil
        try? await Task.sleep(for: .milliseconds(30))
        t.check(weakDriver.value == nil, "notification observation does not retain a discarded driver")

        let cancelledFake = LifecyclePadTransport()
        let cancelledDriver = Z1Treadmill(transport: cancelledFake, defaults: UserDefaults(suiteName: suite)!)
        do {
            try await cancelledDriver.connect()
            try await cancelledDriver.start()
            let pending = Task { try await cancelledDriver.setSpeed(3) }
            try await Task.sleep(for: .milliseconds(30))
            pending.cancel()
            do {
                try await pending.value
                t.check(false, "cancelled queued speed must fail")
            } catch is CancellationError {
                t.check(true, "cancelled queued speed fails with cancellation")
            }
            try await Task.sleep(for: .milliseconds(450))
            t.expectEqual(cancelledFake.commands, [0, 7], "cancelled speed never reaches transport")
        } catch { t.check(false, "queued cancellation fixture: \(error)") }
        await cancelledDriver.disconnect()

        let disconnectFake = LifecyclePadTransport()
        let disconnectDriver = Z1Treadmill(transport: disconnectFake, defaults: UserDefaults(suiteName: suite)!)
        do {
            try await disconnectDriver.connect()
            try await disconnectDriver.start()
            let pending = Task { try await disconnectDriver.stop() }
            try await Task.sleep(for: .milliseconds(30))
            await disconnectDriver.disconnect()
            do {
                try await pending.value
                t.check(false, "disconnect must abandon queued Stop")
            } catch { t.check(true, "disconnect abandons queued Stop") }
            try await disconnectDriver.connect()
            try await Task.sleep(for: .milliseconds(450))
            t.expectEqual(disconnectFake.commands, [0, 7], "old Stop cannot reach the new link")
        } catch { t.check(false, "disconnect queue fixture: \(error)") }
        await disconnectDriver.disconnect()

        let retryFake = LifecyclePadTransport(refuseFirstStop: true)
        let retryDriver = Z1Treadmill(transport: retryFake, defaults: UserDefaults(suiteName: suite)!)
        do {
            try await retryDriver.connect()
            try await retryDriver.start()
            let pending = Task { try await retryDriver.stop() }
            for _ in 0..<200 {
                if retryFake.commands.contains(Z1Constants.opStopOrPause) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            t.check(retryFake.commands.contains(Z1Constants.opStopOrPause), "Stop refusal reaches transport")
            // Enter the retry delay before replacing its connection.
            try await Task.sleep(for: .milliseconds(30))
            await retryDriver.disconnect()
            try await retryDriver.connect()
            do {
                try await pending.value
                t.check(false, "old Stop retry must fail after reconnect")
            } catch is CancellationError {
                t.check(true, "old Stop retry is cancelled after reconnect")
            }
            t.expectEqual(retryFake.commands, [0, 7, 8], "Stop retry cannot cross a reconnect")
        } catch { t.check(false, "Stop retry fixture: \(error)") }
        await retryDriver.disconnect()

        let burstFake = LifecyclePadTransport()
        let burstDriver = Z1Treadmill(transport: burstFake, defaults: UserDefaults(suiteName: suite)!)
        do {
            try await burstDriver.connect()
            try await burstDriver.start()
            let motions = (0..<12).map { _ in Task { try await burstDriver.setSpeed(3) } }
            try await Task.sleep(for: .milliseconds(80))
            try await burstDriver.stop()
            var cancellations = 0
            for motion in motions {
                do { try await motion.value }
                catch is CancellationError { cancellations += 1 }
            }
            t.expectEqual(cancellations, 12, "Stop retires every pending speed in a burst")
            t.expectEqual(burstFake.commands, [0, 7, 8], "Stop reclaims obsolete pacing slots before its timeout")
        } catch { t.check(false, "Stop burst fixture: \(error)") }
        await burstDriver.disconnect()

        let staleFake = LifecyclePadTransport()
        let staleDriver = Z1Treadmill(transport: staleFake, defaults: UserDefaults(suiteName: suite)!)
        do {
            try await staleDriver.connect()
            try await staleDriver.start()
            let pending = Task { try await staleDriver.setSpeed(3) }
            try await Task.sleep(for: .milliseconds(30))
            staleFake.reply(Z1Constants.opSetTargetSpeed)
            try await pending.value
            t.expectEqual(staleFake.commands, [0, 7, 2], "an unsolicited reply cannot acknowledge an unsent speed command")
        } catch { t.check(false, "unsent reply fixture: \(error)") }
        await staleDriver.disconnect()

        let telemetryFake = LifecyclePadTransport(rejectTelemetry: true)
        let telemetryDriver = Z1Treadmill(transport: telemetryFake, defaults: UserDefaults(suiteName: suite)!)
        do {
            try await telemetryDriver.connect()
            t.check(false, "telemetry subscription failure must prevent ready")
        } catch {
            let status = await telemetryDriver.status
            t.expectEqual(status.phase, .error, "telemetry subscription failure prevents ready")
            t.check(telemetryFake.commands.isEmpty, "missing telemetry sends no belt commands")
        }
        await telemetryDriver.disconnect()
    }
}
