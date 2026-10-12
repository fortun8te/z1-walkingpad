import CoreBluetooth
import Foundation
import Z1Core

/// A one-shot gate a scripted transport can park an operation on.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resume = lock.withLock { () -> Bool in
                entered = true
                if open { return true }
                waiters.append(cont)
                return false
            }
            if resume { cont.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    var hasEntered: Bool { lock.withLock { entered } }
}

/// What the scripted transport does with the disconnect callback when the
/// driver asks it to disconnect.
enum DisconnectEcho: Sendable {
    /// No callback at all (no peripheral to cancel, or the 5 s fallback).
    case none
    /// The callback arrives while `disconnect()` is still running.
    case immediate
    /// The callback arrives after `disconnect()` has returned.
    case late(milliseconds: Int)
}

/// Scripted in-memory pad. It never creates a CBCentralManager, so a test can
/// not scan for, connect to or move the real treadmill.
///
/// With `vendor` on it also speaks the KingSmith supplement channel (unlock,
/// SYS_INFO, SETTING_GET, property writes, the 0x77 tunnel), which is the
/// path the real Z1 takes and the one the plain fake does not exercise.
final class ScriptedPad: Z1PadTransport, @unchecked Sendable {
    let notifications: AsyncStream<(String, Data)>
    private let yieldNotification: AsyncStream<(String, Data)>.Continuation
    private let lock = NSLock()
    private var disconnectHandler: (@Sendable () -> Void)?
    private var written: [(uuid: CBUUID, data: Data)] = []
    private var controlTimes: [ContinuousClock.Instant] = []
    private var linkedFlag = false
    private var disconnects = 0
    private var scanTimeoutsSeen: [TimeInterval] = []

    // Script. Set before the driver connects.
    var vendor = false
    var deviceName = "UREVO Test Treadmill"
    var connectError: Error?
    var echo: DisconnectEcho = .immediate
    let connectGate = Gate()
    let scanGate = Gate()
    var holdConnect = false
    var holdScan = false
    /// Result code to answer a control-point opcode with. Default 1 (success).
    var controlResults: [UInt8: UInt8] = [:]
    var silentControlOpcodes: Set<UInt8> = []

    var peripheralIdentifier: UUID? { nil }

    var onDisconnect: (@Sendable () -> Void)? {
        get { lock.withLock { disconnectHandler } }
        set { lock.withLock { disconnectHandler = newValue } }
    }

    struct ScriptError: Error, LocalizedError {
        var errorDescription: String? { "scripted connect failure" }
    }

    init() {
        var continuation: AsyncStream<(String, Data)>.Continuation!
        notifications = AsyncStream { continuation = $0 }
        yieldNotification = continuation
    }

    // MARK: observation

    var controlOpcodes: [UInt8] {
        lock.withLock { written.filter { $0.uuid == Z1Constants.charControlPoint }.compactMap { $0.data.first } }
    }

    /// When each control-point write reached the pad.
    var controlWriteTimes: [ContinuousClock.Instant] { lock.withLock { controlTimes } }

    var vendorFrames: [Data] {
        lock.withLock { written.filter { $0.uuid == Z1Constants.charSupplementWrite }.map(\.data) }
    }

    var isLinked: Bool { lock.withLock { linkedFlag } }
    var disconnectCount: Int { lock.withLock { disconnects } }

    // MARK: stimulus

    /// A genuine link loss, as CoreBluetooth reports it.
    func dropLink() {
        lock.withLock { linkedFlag = false }
        onDisconnect?()
    }

    func sendTelemetry(speed: Int, elapsed: Int, distance: Int, steps: Int? = nil) {
        var bytes: [UInt8] = steps == nil ? [0x04, 0x04] : [0x04, 0x24]
        bytes += [UInt8(speed & 255), UInt8(speed >> 8)]
        bytes += [UInt8(distance & 255), UInt8((distance >> 8) & 255), UInt8((distance >> 16) & 255)]
        bytes += [UInt8(elapsed & 255), UInt8(elapsed >> 8)]
        if let steps { bytes += [UInt8(steps & 255), UInt8(steps >> 8)] }
        yieldNotification.yield((Z1Constants.charTreadmillData.uuidString, Data(bytes)))
    }

    func sendRaw(_ uuid: CBUUID, _ data: Data) {
        yieldNotification.yield((uuid.uuidString, data))
    }

    func sendStopEvent() {
        yieldNotification.yield((Z1Constants.charFitnessMachineStatus.uuidString, Data([2])))
    }

    func sendControlReply(opcode: UInt8, result: UInt8) {
        yieldNotification.yield((Z1Constants.charControlPoint.uuidString, Data([0x80, opcode, result])))
    }

    // MARK: Z1PadTransport

    func waitPoweredOn() async throws {}
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String? { nil }

    /// The timeout each scan was asked for.
    var scanTimeouts: [TimeInterval] { lock.withLock { scanTimeoutsSeen } }

    func scanForTreadmill(timeout: TimeInterval) async throws -> String {
        lock.withLock { scanTimeoutsSeen.append(timeout) }
        if holdScan { await scanGate.wait() }
        return deviceName
    }

    func connect(timeout: TimeInterval) async throws {
        if holdConnect { await connectGate.wait() }
        if let connectError { throw connectError }
        lock.withLock { linkedFlag = true }
    }

    func discoverProfile(services: [CBUUID], characteristics: [CBUUID]) async throws {}

    func hasCharacteristic(_ uuid: CBUUID) -> Bool {
        if uuid == Z1Constants.charControlPoint { return true }
        guard vendor else { return false }
        return uuid == Z1Constants.charSupplementWrite
            || uuid == Z1Constants.charSupplementNotify
            || uuid == Z1Constants.charSupportedSpeedRange
    }

    func setNotify(_ uuid: CBUUID, enable: Bool) async throws {}

    func read(_ uuid: CBUUID) async throws -> Data {
        // Supported speed range: 1.60 to 6.40 km/h.
        uuid == Z1Constants.charSupportedSpeedRange ? Data([0xA0, 0x00, 0x80, 0x02]) : Data()
    }

    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws {
        lock.withLock {
            written.append((uuid, data))
            if uuid == Z1Constants.charControlPoint { controlTimes.append(.now) }
        }
        if uuid == Z1Constants.charControlPoint, let opcode = data.first {
            guard !silentControlOpcodes.contains(opcode) else { return }
            sendControlReply(opcode: opcode, result: controlResults[opcode] ?? 1)
        } else if uuid == Z1Constants.charSupplementWrite, let frame = Z1Protocol.parseFrame(data) {
            replyOnSupplementChannel(to: frame)
        }
    }

    private func replyOnSupplementChannel(to frame: (cmd0: UInt8, cmd1: UInt8, data: Data)) {
        func reply(_ cmd0: UInt8, _ cmd1: UInt8, _ payload: [UInt8] = []) {
            yieldNotification.yield((
                Z1Constants.charSupplementNotify.uuidString,
                Z1Protocol.buildFrame(cmd0: cmd0, cmd1: cmd1, data: Data(payload))
            ))
        }
        switch (frame.cmd0, frame.cmd1) {
        case (Z1Constants.vopUnlock, 0x00): reply(0x71, 0x80, [0])
        case (Z1Constants.vopUnlock, 0x01): reply(0x71, 0x81, [0])
        case (Z1Constants.vopProperty, 0x00):
            // property 1 = 0x0001 (km), property 10 = 0x0200 (manual mode)
            reply(0x72, 0x80, [1, 0, 1, 0, 10, 0, 0, 2])
        case (Z1Constants.vopProperty, 0x01):
            reply(0x72, 0x81, [frame.data.first ?? 0, 0])
        case (0x77, 0x01):
            reply(0x77, 0x81, [frame.data.first ?? 0, 0])
        default: break
        }
    }

    func disconnect() async {
        lock.withLock { linkedFlag = false; disconnects += 1 }
        switch echo {
        case .none: break
        case .immediate: onDisconnect?()
        case .late(let milliseconds):
            let handler = onDisconnect
            Task {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                handler?()
            }
        }
    }

    func cancelConnectionNow() { lock.withLock { linkedFlag = false } }
}

/// Which preference keys were written. Sendable, so a test can keep it after
/// handing the (non-Sendable) defaults object to the driver.
final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func add(_ key: String) { lock.withLock { recorded.append(key) } }
    var keys: [String] { lock.withLock { recorded } }
}

/// UserDefaults that remembers which keys were written.
final class CountingDefaults: UserDefaults, @unchecked Sendable {
    let log = WriteLog()

    override func set(_ value: Any?, forKey defaultName: String) {
        log.add(defaultName)
        super.set(value, forKey: defaultName)
    }

    static func isolated() -> CountingDefaults {
        let name = "z1tests.\(UUID().uuidString)"
        let defaults = CountingDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// Records every status the driver publishes.
final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Z1Treadmill.Status] = []
    private var task: Task<Void, Never>?

    init(_ driver: Z1Treadmill) {
        let stream = driver.statusUpdates
        task = Task { [weak self] in
            for await status in stream { self?.lock.withLock { self?.seen.append(status) } }
        }
    }

    var statuses: [Z1Treadmill.Status] { lock.withLock { seen } }
    func stop() { task?.cancel() }
}

func waitUntil(_ seconds: Double = 3, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
