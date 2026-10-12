import CoreBluetooth
import Foundation

// CoreBluetooth objects are thread-confined to this transport's serial delegate
// queue in practice; these conformances let them cross actor boundaries.
extension CBPeripheral: @retroactive @unchecked Sendable {}
extension CBCharacteristic: @retroactive @unchecked Sendable {}
extension CBService: @retroactive @unchecked Sendable {}
extension CBUUID: @retroactive @unchecked Sendable {}

public enum BLETransportError: Error, Equatable, LocalizedError {
    case bluetoothUnavailable(String)
    case timeout
    case notConnected
    case missingCharacteristics
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let why): "Bluetooth unavailable: \(why)"
        case .timeout: "BLE operation timed out"
        case .notConnected: "not connected to a peripheral"
        case .missingCharacteristics: "required GATT characteristics not found"
        case .operationInProgress: "BLE operation already in progress"
        }
    }
}

/// Thin async/await wrapper around CBCentralManager + CBPeripheral.
///
/// All delegate work runs on a private serial queue; continuations are guarded
/// by a lock; notifications are fanned out as `(uuidString, data)` pairs on an
/// AsyncStream so ordering is preserved for the consumer.
final class BLETransport: NSObject, Z1PadTransport, @unchecked Sendable {

    private let queue = DispatchQueue(label: "z1walkingpad.ble")
    private let lock = NSLock()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var scanPrefix = ""
    private var scanByMatch = false

    // Pending one-shot operations (all guarded by `lock`).
    private var poweredOnConts: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var scanCont: CheckedContinuation<String, Error>?
    private var connectCont: CheckedContinuation<Void, Error>?
    private var disconnectCont: CheckedContinuation<Void, Never>?
    private var servicesCont: CheckedContinuation<Void, Error>?
    private var charsConts: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var readConts: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeConts: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyConts: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var timeoutTokens: [String: UUID] = [:]
    private var timeoutItems: [String: DispatchWorkItem] = [:]
    private var expectedDisconnectIDs: Set<UUID> = []

    let notifications: AsyncStream<(String, Data)>
    private let notifyYield: AsyncStream<(String, Data)>.Continuation

    /// Called (on the BLE queue) whenever the peripheral disconnects,
    /// whether expected or not.
    var onDisconnect: (@Sendable () -> Void)?

    override init() {
        var cont: AsyncStream<(String, Data)>.Continuation!
        notifications = AsyncStream { cont = $0 }
        notifyYield = cont
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - helpers

    private func scheduleTimeout(_ seconds: TimeInterval, key: String, _ fire: @escaping @Sendable () -> Void) {
        let token = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { () -> Bool in
                guard self.timeoutTokens[key] == token else { return false }
                self.timeoutTokens[key] = nil
                self.timeoutItems[key] = nil
                return true
            }
            if current { fire() }
        }
        lock.withLock {
            timeoutItems[key]?.cancel()
            timeoutTokens[key] = token
            timeoutItems[key] = item
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func clearTimeout(_ key: String) {
        lock.withLock {
            timeoutTokens[key] = nil
            timeoutItems.removeValue(forKey: key)?.cancel()
        }
    }

    private func opKey(_ kind: String, _ uuid: CBUUID) -> String {
        "\(kind):\(uuid.uuidString)"
    }

    /// Take and clear an optional continuation under the lock.
    private func take<T>(_ keyPath: ReferenceWritableKeyPath<BLETransport, CheckedContinuation<T, Error>?>, timeoutKey: String)
        -> CheckedContinuation<T, Error>?
    {
        let result = lock.withLock {
            defer { self[keyPath: keyPath] = nil }
            return self[keyPath: keyPath]
        }
        if result != nil { clearTimeout(timeoutKey) }
        return result
    }

    private func lookup(_ uuid: CBUUID) throws -> (CBPeripheral, CBCharacteristic) {
        try lock.withLock {
            guard let peripheral else { throw BLETransportError.notConnected }
            guard let char = characteristics[uuid] else { throw BLETransportError.missingCharacteristics }
            return (peripheral, char)
        }
    }

    private func failAllPending(_ error: Error) {
        let (powered, scan, connect, services, chars, reads, writes, notifys) = lock.withLock { () -> (
            [CheckedContinuation<Void, Error>],
            CheckedContinuation<String, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            [CBUUID: CheckedContinuation<Void, Error>],
            [CBUUID: CheckedContinuation<Data, Error>],
            [CBUUID: CheckedContinuation<Void, Error>],
            [CBUUID: CheckedContinuation<Void, Error>]
        ) in
            defer {
                poweredOnConts.removeAll()
                scanCont = nil
                connectCont = nil
                servicesCont = nil
                charsConts.removeAll()
                readConts.removeAll()
                writeConts.removeAll()
                notifyConts.removeAll()
            }
            return (Array(poweredOnConts.values), scanCont, connectCont, servicesCont, charsConts, readConts, writeConts, notifyConts)
        }
        let keys = lock.withLock { Array(timeoutItems.keys) }
        keys.forEach(clearTimeout)
        powered.forEach { $0.resume(throwing: error) }
        scan?.resume(throwing: error)
        connect?.resume(throwing: error)
        services?.resume(throwing: error)
        chars.values.forEach { $0.resume(throwing: error) }
        reads.values.forEach { $0.resume(throwing: error) }
        writes.values.forEach { $0.resume(throwing: error) }
        notifys.values.forEach { $0.resume(throwing: error) }
    }

    private static func describeState(_ state: CBManagerState) -> String {
        switch state {
        case .unauthorized: "Bluetooth permission denied for this app"
        case .poweredOff: "Bluetooth is turned off"
        case .unsupported: "Bluetooth LE is not supported on this Mac"
        case .resetting: "Bluetooth is resetting"
        default: "Bluetooth state \(state.rawValue)"
        }
    }

    // MARK: - public API

    func waitPoweredOn() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let id = UUID()
            let state = lock.withLock { () -> CBManagerState in
                let s = central.state
                if s == .unknown || s == .resetting {
                    poweredOnConts[id] = cont
                }
                return s
            }
            switch state {
            case .poweredOn: cont.resume()
            case .unknown, .resetting:
                scheduleTimeout(10, key: "power:\(id)") { [weak self] in
                    guard let self else { return }
                    let pending = self.lock.withLock { self.poweredOnConts.removeValue(forKey: id) }
                    pending?.resume(throwing: BLETransportError.timeout)
                }
            default: cont.resume(throwing: BLETransportError.bluetoothUnavailable(Self.describeState(state)))
            }
        }
    }

    /// The identifier of the peripheral we are currently bound to, if any.
    /// Persist it to skip the scan on the next launch.
    var peripheralIdentifier: UUID? {
        lock.withLock { peripheral?.identifier }
    }

    /// Re-adopt a peripheral macOS already knows by identifier, skipping the
    /// scan entirely. Returns its name, or nil when the system has forgotten
    /// it (or cannot tell us the name — which the unlock token is derived
    /// from, so a nameless peripheral is useless to us).
    ///
    /// Requires the central to be powered on.
    func adoptKnownPeripheral(identifier: UUID, namePrefix: String) -> String? {
        guard let found = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return nil
        }
        let name = found.name ?? ""
        let ok = !name.isEmpty && (name.hasPrefix(namePrefix) || TreadmillMatch.accepts(name: found.name, serviceUUIDs: []))
        guard ok else { return nil }
        lock.withLock { peripheral = found }
        return name
    }

    /// Scan for the first peripheral whose name starts with `namePrefix`.
    /// Returns the device name; the peripheral is retained internally.
    func scan(namePrefix: String, timeout: TimeInterval) async throws -> String {
        try await waitPoweredOn()
        return try await withCheckedThrowingContinuation { cont in
            let busy = lock.withLock { () -> Bool in
                if scanCont != nil { return true }
                scanPrefix = namePrefix
                scanByMatch = false
                scanCont = cont
                return false
            }
            if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
            scheduleTimeout(timeout, key: "scan") { [weak self] in
                guard let self, let cont = self.take(\.scanCont, timeoutKey: "scan") else { return }
                self.central.stopScan()
                cont.resume(throwing: BLETransportError.timeout)
            }
            queue.async {
                self.central.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }

    /// Scan for any FTMS treadmill / walking pad we know how to drive.
    func scanForTreadmill(timeout: TimeInterval) async throws -> String {
        try await waitPoweredOn()
        return try await withCheckedThrowingContinuation { cont in
            let busy = lock.withLock { () -> Bool in
                if scanCont != nil { return true }
                scanPrefix = ""
                scanByMatch = true
                scanCont = cont
                return false
            }
            if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
            scheduleTimeout(timeout, key: "scan") { [weak self] in
                guard let self, let cont = self.take(\.scanCont, timeoutKey: "scan") else { return }
                self.central.stopScan()
                cont.resume(throwing: BLETransportError.timeout)
            }
            queue.async {
                // Nil services: KingSmith often omits 0x1826 from the advert.
                self.central.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }

    func hasCharacteristic(_ uuid: CBUUID) -> Bool {
        lock.withLock { characteristics[uuid] != nil }
    }

    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let (target, busy) = lock.withLock { () -> (CBPeripheral?, Bool) in
                guard let peripheral else { return (nil, false) }
                if connectCont != nil { return (peripheral, true) }
                connectCont = cont
                return (peripheral, false)
            }
            if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
            guard let target else {
                cont.resume(throwing: BLETransportError.notConnected)
                return
            }
            // Already linked (a pending connect from a previous attempt landed
            // while we were not waiting) — CoreBluetooth would not call the
            // delegate again, so resolve immediately.
            if target.state == .connected {
                if let cont = take(\.connectCont, timeoutKey: "connect") {
                    queue.async { target.delegate = self }
                    cont.resume()
                }
                return
            }
            scheduleTimeout(timeout, key: "connect") { [weak self] in
                guard let self, let cont = self.take(\.connectCont, timeoutKey: "connect") else { return }
                // CoreBluetooth's connect() never times out on its own: the
                // request stays queued forever. Abandoning it without
                // cancelling leaves a pending connect for a peripheral that
                // only accepts one central, so every later attempt queues
                // behind the last dead one and the app slowly stops being
                // able to connect at all.
                self.central.cancelPeripheralConnection(target)
                cont.resume(throwing: BLETransportError.timeout)
            }
            queue.async {
                _ = self.lock.withLock { self.expectedDisconnectIDs.remove(target.identifier) }
                target.delegate = self
                self.central.connect(target, options: nil)
            }
        }
    }

    func discoverProfile(services: [CBUUID], characteristics chars: [CBUUID]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let (target, busy) = lock.withLock { () -> (CBPeripheral?, Bool) in
                guard let peripheral else { return (nil, false) }
                if servicesCont != nil { return (peripheral, true) }
                servicesCont = cont
                return (peripheral, false)
            }
            if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
            guard let target else {
                cont.resume(throwing: BLETransportError.notConnected)
                return
            }
            scheduleTimeout(Z1Constants.gattOpTimeout, key: "services") { [weak self] in
                guard let self, let cont = self.take(\.servicesCont, timeoutKey: "services") else { return }
                cont.resume(throwing: BLETransportError.timeout)
            }
            queue.async { target.discoverServices(services) }
        }
        for serviceUUID in services {
            let found = lock.withLock { () -> (CBPeripheral, CBService)? in
                guard let peripheral,
                      let service = peripheral.services?.first(where: { $0.uuid == serviceUUID })
                else { return nil }
                return (peripheral, service)
            }
            guard let (target, service) = found else { continue }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let busy = lock.withLock { () -> Bool in
                    if charsConts[serviceUUID] != nil { return true }
                    charsConts[serviceUUID] = cont
                    return false
                }
                if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
                let key = opKey("chars", serviceUUID)
                scheduleTimeout(Z1Constants.gattOpTimeout, key: key) { [weak self] in
                    guard let self else { return }
                    let cont = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                        defer { self.charsConts[serviceUUID] = nil }
                        return self.charsConts[serviceUUID]
                    }
                    cont?.resume(throwing: BLETransportError.timeout)
                }
                queue.async { target.discoverCharacteristics(chars, for: service) }
            }
        }
        try lock.withLock {
            let required: [CBUUID] = [
                Z1Constants.charTreadmillData,
                Z1Constants.charControlPoint,
            ]
            for uuid in required where characteristics[uuid] == nil {
                throw BLETransportError.missingCharacteristics
            }
        }
    }

    func setNotify(_ uuid: CBUUID, enable: Bool) async throws {
        let (target, char) = try lookup(uuid)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let busy = lock.withLock { () -> Bool in
                if notifyConts[uuid] != nil { return true }
                notifyConts[uuid] = cont
                return false
            }
            if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
            let key = opKey("notify", uuid)
            scheduleTimeout(Z1Constants.gattOpTimeout, key: key) { [weak self] in
                guard let self else { return }
                let cont = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    defer { self.notifyConts[uuid] = nil }
                    return self.notifyConts[uuid]
                }
                cont?.resume(throwing: BLETransportError.timeout)
            }
            queue.async { target.setNotifyValue(enable, for: char) }
        }
    }

    func read(_ uuid: CBUUID) async throws -> Data {
        let (target, char) = try lookup(uuid)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let busy = lock.withLock { () -> Bool in
                if readConts[uuid] != nil { return true }
                readConts[uuid] = cont
                return false
            }
            if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
            let key = opKey("read", uuid)
            scheduleTimeout(Z1Constants.gattOpTimeout, key: key) { [weak self] in
                guard let self else { return }
                let cont = self.lock.withLock { () -> CheckedContinuation<Data, Error>? in
                    defer { self.readConts[uuid] = nil }
                    return self.readConts[uuid]
                }
                cont?.resume(throwing: BLETransportError.timeout)
            }
            queue.async { target.readValue(for: char) }
        }
    }

    func write(_ uuid: CBUUID, _ data: Data, withResponse: Bool) async throws {
        let (target, char) = try lookup(uuid)
        if withResponse {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let busy = lock.withLock { () -> Bool in
                    if writeConts[uuid] != nil { return true }
                    writeConts[uuid] = cont
                    return false
                }
                if busy { cont.resume(throwing: BLETransportError.operationInProgress); return }
                let key = opKey("write", uuid)
                scheduleTimeout(Z1Constants.gattOpTimeout, key: key) { [weak self] in
                    guard let self else { return }
                    let cont = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                        defer { self.writeConts[uuid] = nil }
                        return self.writeConts[uuid]
                    }
                    cont?.resume(throwing: BLETransportError.timeout)
                }
                queue.async { target.writeValue(data, for: char, type: .withResponse) }
            }
        } else {
            queue.async { target.writeValue(data, for: char, type: .withoutResponse) }
        }
    }

    /// Best-effort synchronous teardown for process exit, where there is no
    /// time to await anything. The pad accepts a single central, so leaving
    /// the link up on quit is what makes the *next* launch fail to connect.
    func cancelConnectionNow() {
        let target = lock.withLock { () -> CBPeripheral? in peripheral }
        guard let target else { return }
        central.cancelPeripheralConnection(target)
    }

    func disconnect() async {
        let target = lock.withLock { () -> CBPeripheral? in peripheral }
        guard let target else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let busy = lock.withLock { () -> Bool in
                if disconnectCont != nil { return true }
                disconnectCont = cont
                return false
            }
            if busy { cont.resume(); return }
            _ = lock.withLock { expectedDisconnectIDs.insert(target.identifier) }
            scheduleTimeout(5, key: "disconnect") { [weak self] in
                guard let self else { return }
                let cont = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    defer { self.disconnectCont = nil }
                    return self.disconnectCont
                }
                cont?.resume()
            }
            queue.async { self.central.cancelPeripheralConnection(target) }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let conts = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { poweredOnConts.removeAll() }
                return Array(poweredOnConts.values)
            }
            let keys = lock.withLock { timeoutItems.keys.filter { $0.hasPrefix("power:") } }
            keys.forEach(clearTimeout)
            conts.forEach { $0.resume() }
        case .unknown:
            break
        default:
            let error = BLETransportError.bluetoothUnavailable(Self.describeState(central.state))
            let conts = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { poweredOnConts.removeAll() }
                return Array(poweredOnConts.values)
            }
            let keys = lock.withLock { timeoutItems.keys.filter { $0.hasPrefix("power:") } }
            keys.forEach(clearTimeout)
            conts.forEach { $0.resume(throwing: error) }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let (prefix, byMatch) = lock.withLock { (scanPrefix, scanByMatch) }
        let ok: Bool
        if byMatch {
            ok = TreadmillMatch.accepts(name: name, serviceUUIDs: services)
        } else {
            ok = name?.hasPrefix(prefix) == true
        }
        guard ok else { return }
        if let cont = take(\.scanCont, timeoutKey: "scan") {
            central.stopScan()
            lock.withLock { self.peripheral = peripheral }
            cont.resume(returning: name!)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if let cont = take(\.connectCont, timeoutKey: "connect") {
            cont.resume()
        } else {
            // A connect that completed after its waiter timed out is an
            // abandoned request, not a usable link.
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else { return }
        if let cont = take(\.connectCont, timeoutKey: "connect") {
            cont.resume(throwing: error ?? BLETransportError.notConnected)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else { return }
        let (requested, expected) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Bool) in
            let expected = expectedDisconnectIDs.remove(peripheral.identifier) != nil
            defer {
                self.peripheral = nil
                characteristics.removeAll()
                disconnectCont = nil
            }
            return (disconnectCont, expected)
        }
        clearTimeout("disconnect")
        failAllPending(BLETransportError.notConnected)
        requested?.resume()
        if !expected { onDisconnect?() }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let cont = take(\.servicesCont, timeoutKey: "services") {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        lock.withLock {
            for char in service.characteristics ?? [] {
                characteristics[char.uuid] = char
            }
        }
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { charsConts[service.uuid] = nil }
            return charsConts[service.uuid]
        }
        if cont != nil { clearTimeout(opKey("chars", service.uuid)) }
        if let cont {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let readCont = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { readConts[uuid] = nil }
            return readConts[uuid]
        }
        if let readCont {
            clearTimeout(opKey("read", uuid))
            if let error {
                readCont.resume(throwing: error)
            } else {
                readCont.resume(returning: characteristic.value ?? Data())
            }
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        notifyYield.yield((uuid.uuidString, value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { writeConts[characteristic.uuid] = nil }
            return writeConts[characteristic.uuid]
        }
        if let cont {
            clearTimeout(opKey("write", characteristic.uuid))
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { notifyConts[characteristic.uuid] = nil }
            return notifyConts[characteristic.uuid]
        }
        if let cont {
            clearTimeout(opKey("notify", characteristic.uuid))
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }
}
