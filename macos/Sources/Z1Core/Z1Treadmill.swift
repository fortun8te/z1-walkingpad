import CoreBluetooth
import Foundation

/// A counter that can be read from any thread. See `Z1Treadmill.linkEpoch`.
final class LinkEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    var value: Int { lock.withLock { current } }

    @discardableResult
    func advance() -> Int {
        lock.withLock {
            current += 1
            return current
        }
    }
}

public enum Z1Error: Error, Equatable, LocalizedError {
    case notFound
    case notConnected
    case unlockTimeout
    case vendorTimeout
    case controlPointTimeout
    case controlRefused(op: UInt8, result: UInt8)
    case speedOutOfRange(Double)
    case invalidDeviceName

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "No treadmill found (is it on, and is the phone app disconnected?)"
        case .notConnected:
            "not connected/unlocked — call connect() first"
        case .unlockTimeout:
            "unlock timed out — pad did not answer the supplement handshake"
        case .vendorTimeout:
            "vendor frame response timed out"
        case .controlPointTimeout:
            "control point indication timed out"
        case .controlRefused(let op, let result):
            "control point refused op \(String(format: "%02x", op)): \(Self.cpResultName(result))"
        case .speedOutOfRange(let kmh):
            "speed \(kmh) out of range"
        case .invalidDeviceName:
            "pad name is too short to derive its unlock code"
        }
    }

    static func cpResultName(_ result: UInt8) -> String {
        switch result {
        case 1: "success"
        case 2: "op not supported"
        case 3: "invalid parameter"
        case 4: "failed"
        case 5: "control not permitted"
        default: "code \(result)"
        }
    }
}

/// Async BLE client for the KingSmith WalkingPad Z1.
///
/// Protocol recap (see docs/protocol.md): the pad ignores every FTMS control
/// point command and suppresses all notifications until the supplement-channel
/// unlock frame lands. Order:
///
/// 1. subscribe supplement notify characteristic
/// 2. send unlock frame (write WITHOUT response)
/// 3. await 71 80 -> send SYS_INFO -> SETTING_GET
/// 4. FTMS works from here on: request control -> start/stop/set speed
public actor Z1Treadmill {

    public enum Phase: String, Sendable {
        case disconnected
        case scanning
        case connecting
        case ready
        case error
    }

    /// Snapshot of everything the UI needs. Speed is the live belt speed;
    /// distance/elapsed/steps are deltas since the last `start()` (pad
    /// counters persist across BLE connections).
    public struct Status: Sendable, Equatable {
        public var phase: Phase = .disconnected
        public var deviceName: String?
        public var beltRunning = false
        /// Stop was accepted; await device telemetry/status before claiming stopped.
        public var stopRequested = false
        public var speedKmh = 0.0
        public var distanceM = 0
        public var elapsedS = 0
        public var steps = 0
        /// Raw counter reported by the pad, when available. `steps` is the
        /// labelled gait-model estimate used by the display.
        public var padSteps: Int?
        /// Metres per step implied by the live numbers, once meaningful.
        public var impliedStrideM: Double?
        public var caloriesKcal = 0.0
        public var minSpeedKmh = 1.6
        public var maxSpeedKmh = 6.4
        public var hasTelemetry = false
        public var properties: [Int: Int] = [:]
        public var errorMessage: String?

        public init() {}
    }

    public private(set) var status = Status()
    public nonisolated let statusUpdates: AsyncStream<Status>
    private let statusYield: AsyncStream<Status>.Continuation

    private nonisolated let transport: any Z1PadTransport
    private var notifyPump: Task<Void, Never>?

    private var telemetry = Z1Protocol.TreadmillData()
    // The pad is the master of counters: time/distance/steps are shown
    // exactly as the pad reports them (it resets them on Stop and on its
    // own schedule). Calories are computed client-side but follow the same
    // lifecycle — the tracker resets whenever the pad's counters do.
    private var calorieTracker = CalorieTracker()
    private let defaults: UserDefaults

    /// The speed to model steps at: the belt's own while it moves, else this
    /// walk's average, else 3 km/h.
    private var modelSpeedKmh: Double {
        let live = telemetry.speedKmh ?? 0
        if live > 0.4 { return live }
        let metres = max(0, telemetry.distanceM ?? 0)
        let seconds = max(0, telemetry.elapsedS ?? 0)
        return seconds > 0 ? Double(metres) / Double(seconds) * 3.6 : 3.0
    }

    /// Belt metres ÷ modelled step length. The pad's step register is not used.
    private var modelledSteps: Int {
        GaitModel.steps(distanceM: max(0, telemetry.distanceM ?? 0), speedKmh: modelSpeedKmh)
    }

    /// Modelled step length in metres, once the walk is long enough to say.
    private var impliedStrideM: Double? {
        guard max(0, telemetry.distanceM ?? 0) >= 10 else { return nil }
        return GaitModel.stepLengthM(speedKmh: modelSpeedKmh)
    }

    private var calorieStateRestored = false
    /// After Start, keep beltRunning true for a beat so omitted-speed
    /// telemetry cannot flip the button back to Start before the belt moves.
    private var startHoldUntil: ContinuousClock.Instant?
    private let startHold: Duration
    private var startHoldExpiry: Task<Void, Never>?
    private var hasControl = false
    private var unlocked = false
    /// KingSmith supplement channel. Generic FTMS pads leave this false.
    private var usesVendor = false
    private var lastVendorWrite: ContinuousClock.Instant?
    private var lastControlWrite: ContinuousClock.Instant?
    private var vendorSlotEnd: ContinuousClock.Instant?
    private var controlSlotEnd: ContinuousClock.Instant?
    private var lastTelemetryInstant: ContinuousClock.Instant?

    struct Frame: Sendable {
        var cmd0: UInt8
        var cmd1: UInt8
        var data: Data
    }

    private struct Waiter<T: Sendable> {
        let id: UUID
        let cont: CheckedContinuation<T, Error>
        var timeout: Task<Void, Never>?
    }

    private typealias VendorWaiter = (waiter: Waiter<Frame>, pred: @Sendable (Frame) -> Bool)
    private var vendorWaiters: [VendorWaiter] = []
    private var cpWaiters: [(opcode: UInt8, waiter: Waiter<Data>)] = []

    /// `transport` and `defaults` are injectable so tests can drive the driver
    /// against a scripted pad and an isolated defaults suite.
    public init(
        weightKg: Double = Z1Metrics.defaultWeightKg,
        transport: (any Z1PadTransport)? = nil,
        defaults: UserDefaults = .standard,
        startHold: Duration = .seconds(5)
    ) {
        var cont: AsyncStream<Status>.Continuation!
        statusUpdates = AsyncStream { cont = $0 }
        statusYield = cont
        calorieTracker = CalorieTracker(weightKg: weightKg)
        self.transport = transport ?? BLETransport()
        self.defaults = defaults
        self.startHold = startHold
    }

    private var pumpStarted = false

    /// Deferred out of `init`: actor initializers can't capture `self` in
    /// escaping closures. Called at the top of `connect()`.
    private func ensurePumpStarted() {
        guard !pumpStarted else { return }
        pumpStarted = true
        transport.onDisconnect = { [weak self] in
            guard let self else { return }
            // Stamp the report with the link it belongs to *now*, on the
            // transport's queue. The actor handles it a moment later, and by
            // then a newer connect or disconnect may have started; the stamp
            // is how it tells a stale echo from a loss of the current link.
            let stamp = self.linkEpoch.value
            Task { await self.handleTransportDisconnect(epoch: stamp) }
        }
        notifyPump = Task { [weak self] in
            guard let self else { return }
            for await (uuidString, data) in self.transport.notifications {
                await self.handleNotification(uuidString, data)
            }
        }
    }

    public func setWeight(_ kg: Double) {
        guard kg > 0 else { return }
        calorieTracker.weightKg = kg
        emitStatus()
    }

    // MARK: - connection

    /// Bumped by every `connect()` and `disconnect()`. An attempt that sees a
    /// different value after an await has been superseded and must not touch
    /// the published state again: a Disconnect (or Quit) that lands while a
    /// scan or connect is in flight would otherwise be undone when that
    /// attempt finishes and flips the phase to `ready` on a link we dropped.
    private nonisolated let linkEpoch = LinkEpoch()
    /// How many of our own teardowns are in flight. A disconnect callback that
    /// arrives meanwhile is the echo of our own cancel, not a lost link. A
    /// counter, not a flag: overlapping teardowns (a failed connect cleaning
    /// up while the user disconnects) must not clear each other's mark.
    private var ownDisconnectsInFlight = 0

    private func ensureCurrent(_ epoch: Int) throws {
        guard epoch == linkEpoch.value else { throw CancellationError() }
    }

    private func tearDownTransport() async {
        ownDisconnectsInFlight += 1
        await transport.disconnect()
        ownDisconnectsInFlight -= 1
    }

    /// `scanTimeout` bounds the scan for a pad that is not already remembered.
    public func connect(scanTimeout: TimeInterval = Z1Constants.scanTimeout) async throws {
        guard status.phase == .disconnected || status.phase == .error else { return }
        ensurePumpStarted()
        let epoch = linkEpoch.advance()
        mutate {
            $0.phase = .scanning
            $0.errorMessage = nil
            $0.hasTelemetry = false
        }
        do {
            try await transport.waitPoweredOn()
            try ensureCurrent(epoch)
            let (name, adopted) = try await resolvePeripheral(scanTimeout: scanTimeout)
            try ensureCurrent(epoch)
            mutate { $0.phase = .connecting; $0.deviceName = name }
            do {
                try await transport.connect(timeout: Z1Constants.connectTimeout)
            } catch {
                // A remembered peripheral that refuses is stale (pad re-paired,
                // or a different Mac wrote the identifier): forget it so the
                // next attempt scans. A plain timeout only means the pad is not
                // there right now (off, or out of range); the identifier is
                // still right, and keeping it spares the next try a full scan.
                if adopted, epoch == linkEpoch.value, (error as? BLETransportError) != .timeout {
                    forgetPeripheral()
                }
                throw error
            }
            try ensureCurrent(epoch)
            rememberPeripheral()
            try await transport.discoverProfile(
                services: [Z1Constants.fitnessMachineService, Z1Constants.supplementService],
                characteristics: [
                    Z1Constants.charSupportedSpeedRange,
                    Z1Constants.charTreadmillData,
                    Z1Constants.charFitnessMachineStatus,
                    Z1Constants.charControlPoint,
                    Z1Constants.charSupplementNotify,
                    Z1Constants.charSupplementWrite,
                ]
            )
            try ensureCurrent(epoch)

            try? await transport.setNotify(Z1Constants.charTreadmillData, enable: true)
            try? await transport.setNotify(Z1Constants.charFitnessMachineStatus, enable: true)
            try ensureCurrent(epoch)

            usesVendor = transport.hasCharacteristic(Z1Constants.charSupplementWrite)
                && transport.hasCharacteristic(Z1Constants.charSupplementNotify)
            unlocked = false
            if usesVendor {
                guard name.utf8.count >= 4 else { throw Z1Error.invalidDeviceName }
                try await transport.setNotify(Z1Constants.charSupplementNotify, enable: true)
                try ensureCurrent(epoch)
                _ = try await vendorRoundtrip(
                    Z1Protocol.unlockFrame(deviceName: name),
                    pred: { $0.cmd0 == Z1Constants.vopUnlock && $0.cmd1 == 0x80 },
                    timeout: Z1Constants.unlockTimeout
                )
                try ensureCurrent(epoch)
                _ = try? await vendorRoundtrip(
                    Z1Protocol.sysInfoFrame(unixTime: UInt32(clamping: Int(Date().timeIntervalSince1970))),
                    pred: { $0.cmd0 == Z1Constants.vopUnlock && $0.cmd1 == 0x81 }
                )
                try ensureCurrent(epoch)
                if let reply = try? await vendorRoundtrip(
                    Z1Protocol.settingGetFrame(),
                    pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x80 }
                ) {
                    let props = Z1Protocol.parsePropertyRecords(reply.data)
                    mutate { $0.properties = props }
                }
                try ensureCurrent(epoch)
            }
            unlocked = true

            // FTMS statics + control point indications
            if transport.hasCharacteristic(Z1Constants.charSupportedSpeedRange),
               let range = try? await transport.read(Z1Constants.charSupportedSpeedRange), range.count >= 4 {
                try ensureCurrent(epoch)
                let lo = Int(range[range.startIndex]) | (Int(range[range.startIndex + 1]) << 8)
                let hi = Int(range[range.startIndex + 2]) | (Int(range[range.startIndex + 3]) << 8)
                mutate {
                    $0.minSpeedKmh = Double(lo) / 100
                    $0.maxSpeedKmh = Double(hi) / 100
                }
            } else if !usesVendor {
                mutate {
                    $0.minSpeedKmh = 0.5
                    $0.maxSpeedKmh = 12.0
                }
            }
            try ensureCurrent(epoch)
            try await transport.setNotify(Z1Constants.charControlPoint, enable: true)
            try ensureCurrent(epoch)

            mutate { $0.phase = .ready }
        } catch {
            guard epoch == linkEpoch.value else {
                // A newer connect() or a disconnect() owns the state now. If
                // nobody has started a new attempt yet, make sure this one
                // leaves no link behind; if one has, the transport is its to
                // manage and tearing it down here would cut it off.
                if status.phase == .disconnected || status.phase == .error {
                    await tearDownTransport()
                }
                throw CancellationError()
            }
            unlocked = false
            // Cleanup may deliver a disconnect callback; it is ours, so the
            // original failure must stay visible.
            await tearDownTransport()
            resetConnectionState()
            failAllWaiters(error)
            mutate {
                $0.phase = .error
                $0.errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Drop the BLE link. `stopBelt` defaults to false: disconnecting is not
    /// a reason to stop someone's walk — the pad keeps running under its own
    /// remote, exactly as it does when the app was never connected. The quit
    /// path that *does* want the belt stopped calls `sleep()` first.
    public func disconnect(stopBelt: Bool = false) async {
        linkEpoch.advance()
        if stopBelt, hasControl, unlocked {
            _ = try? await stop()
        }
        persistCalorieState(force: true)
        await tearDownTransport()
        resetConnectionState()
        failAllWaiters(Z1Error.notConnected)
        mutate {
            $0.phase = .disconnected
            $0.errorMessage = nil
        }
    }

    /// The transport reported that the link went away. Only a link we believed
    /// was up is "lost"; every other case is an echo that must not overwrite
    /// what the driver has since decided.
    private func handleTransportDisconnect(epoch: Int) {
        // A report from a link that has since been replaced or torn down.
        guard epoch == linkEpoch.value else { return }
        if ownDisconnectsInFlight > 0 { return }
        switch status.phase {
        case .ready:
            persistCalorieState(force: true)
            resetConnectionState()
            failAllWaiters(Z1Error.notConnected)
            mutate {
                $0.phase = .disconnected
                $0.errorMessage = "Connection lost"
            }
        case .scanning, .connecting:
            // connect() is mid-flight. Wake whatever it is waiting on so it
            // fails now instead of after the unlock timeout; its own catch
            // block reports the cause.
            failAllWaiters(Z1Error.notConnected)
        case .disconnected, .error:
            // Late callback from a link that was already torn down or that
            // never came up. The state published since is the newer truth;
            // "Connection lost" here would replace a real connect error.
            break
        }
    }

    private func resetConnectionState() {
        controlCommandEpoch += 1
        unlocked = false
        usesVendor = false
        hasControl = false
        startHoldUntil = nil
        startHoldExpiry?.cancel()
        startHoldExpiry = nil
        telemetry = Z1Protocol.TreadmillData()
        calorieStateRestored = false
        lastTelemetryInstant = nil
        mutate {
            $0.beltRunning = false
            $0.stopRequested = false
            $0.speedKmh = 0
            $0.hasTelemetry = false
        }
    }

    // MARK: - public control API

    public func start() async throws {
        let epoch = controlCommandEpoch
        try requireReady()
        try await ensureControl()
        guard epoch == controlCommandEpoch else { throw CancellationError() }
        // Skip only when the pad itself is already moving. Do not use last
        // reported speed: FTMS packets often omit the speed field, and we
        // then keep the previous value — a leftover 3 km/h after Stop made
        // Start a no-op and the belt never moved.
        if !status.beltRunning {
            calorieTracker.reset()
            try await controlCommand(Data([Z1Constants.opStartOrResume]), tunnelOp: 0x07, intentEpoch: epoch)
        }
        guard epoch == controlCommandEpoch else { throw CancellationError() }
        startHoldUntil = ContinuousClock.now + startHold
        mutate { $0.beltRunning = true; $0.stopRequested = false }
        scheduleStartHoldExpiry()
    }

    /// An accepted Start is not proof that the belt moves (a pad in standby
    /// acknowledges it and stays put). The hold that keeps the button on Stop
    /// until telemetry catches up must therefore end by itself: without this,
    /// a Start that did nothing leaves the app showing a running belt until
    /// some unrelated frame arrives, and none may ever come while the belt is
    /// still.
    private func scheduleStartHoldExpiry() {
        startHoldExpiry?.cancel()
        let wait = startHold + .milliseconds(50)
        startHoldExpiry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.startHoldElapsed()
        }
    }

    private func startHoldElapsed() {
        guard let until = startHoldUntil, ContinuousClock.now >= until else { return }
        startHoldUntil = nil
        emitStatus()
    }

    public func stop() async throws {
        controlCommandEpoch += 1
        try requireReady()
        try await ensureControl()
        try await controlCommand(
            Data([Z1Constants.opStopOrPause, Z1Constants.stopParamStop]), tunnelOp: 0x08, tunnelParams: Data([0x01])
        )
        startHoldUntil = nil
        mutate { $0.stopRequested = $0.beltRunning }
    }

    private var controlCommandEpoch = 0

    public func setSpeed(_ kmh: Double) async throws {
        try Task.checkCancellation()
        let epoch = controlCommandEpoch
        try requireReady()
        guard kmh >= status.minSpeedKmh, kmh <= status.maxSpeedKmh else {
            throw Z1Error.speedOutOfRange(kmh)
        }
        try await ensureControl()
        let value = UInt16((kmh * 100).rounded())
        let params = Data([UInt8(value & 0xFF), UInt8(value >> 8)])
        guard epoch == controlCommandEpoch else { throw CancellationError() }
        try await controlCommand(Data([Z1Constants.opSetTargetSpeed]) + params, tunnelOp: 0x02, tunnelParams: params, intentEpoch: epoch)
        guard epoch == controlCommandEpoch else { throw CancellationError() }
    }

    /// Sync the pad's own LED display units. Per the docs/protocol.md property
    /// table, property 1 is "units / screen language" and bit 1 (0x0002)
    /// selects miles vs km; all other bits are preserved from the cached
    /// SETTING_GET dump (default 0 if absent).
    public func setDisplayUnits(imperial: Bool) async throws {
        try requireReady()
        guard usesVendor else { return }
        let current = status.properties[1] ?? 0
        let value = Z1Units.displayUnitsValue(current: current, imperial: imperial)
        _ = try await vendorRoundtrip(
            Z1Protocol.propertyWriteFrame(propID: 1, value: UInt16(value)),
            pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x81 && $0.data.first == 1 }
        )
        mutate { $0.properties[1] = value }
    }

    /// Soft power-off: stop the belt (if running) and switch the pad to
    /// standby mode. Property 10 mode index 2 = sleep, per the
    /// docs/protocol.md property table (bits 5–7 hold the mode; preserved).
    /// Verified on hardware: 0x0200 (manual) <-> 0x0240 (sleep).
    public func sleep() async throws {
        try requireReady()
        if status.beltRunning {
            _ = try await stop()
        }
        guard usesVendor else { return }
        let current = status.properties[10] ?? 0
        let value = (current & ~0xE0) | (2 << 5)
        _ = try await vendorRoundtrip(
            Z1Protocol.propertyWriteFrame(propID: 10, value: UInt16(value)),
            pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x81 && $0.data.first == 10 }
        )
        mutate { $0.properties[10] = value }
    }

    // MARK: - telemetry

    private func handleNotification(_ uuidString: String, _ data: Data) {
        switch uuidString {
        case Z1Constants.charSupplementNotify.uuidString:
            guard let parsed = Z1Protocol.parseFrame(data) else { return }
            let frame = Frame(cmd0: parsed.cmd0, cmd1: parsed.cmd1, data: parsed.data)
            var matched: [Int] = []
            for (i, w) in vendorWaiters.enumerated() where w.pred(frame) {
                matched.append(i)
            }
            for i in matched.reversed() {
                let w = vendorWaiters.remove(at: i)
                w.waiter.timeout?.cancel()
                w.waiter.cont.resume(returning: frame)
            }
        case Z1Constants.charControlPoint.uuidString:
            // FTMS response = 0x80, request opcode, result. Late replies to
            // timed-out commands must not complete a different command.
            if data.count >= 3, data[data.startIndex] == 0x80,
               let i = cpWaiters.firstIndex(where: { $0.opcode == data[data.startIndex + 1] }) {
                let w = cpWaiters.remove(at: i).waiter
                w.timeout?.cancel()
                w.cont.resume(returning: data)
            }
        case Z1Constants.charTreadmillData.uuidString:
            handleTelemetry(data)
        case Z1Constants.charFitnessMachineStatus.uuidString:
            // belt-state events from the pad itself (the master): works even
            // when no treadmill-data frames flow (e.g. belt fully stopped)
            guard let op = data.first else { return }
            switch op {
            case 4:
                startHoldUntil = nil
                mutate { $0.beltRunning = true } // started
            case 1, 2:
                startHoldUntil = nil
                telemetry.speedKmh = 0
                mutate { $0.beltRunning = false; $0.speedKmh = 0; $0.stopRequested = false } // device confirms stop
            default: break
            }
        default:
            break
        }
    }

    private func handleTelemetry(_ data: Data) {
        let telemetryNow = ContinuousClock.now
        let prev = telemetry
        var parsed = Z1Protocol.parseTreadmillData(data)
        if !usesVendor { parsed.steps = nil } // bit 13 is KingSmith-specific
        // FTMS packets may omit counters. Preserve their last values rather
        // than treating omission as zero and later adding the whole session.
        if parsed.speedKmh == nil { parsed.speedKmh = prev.speedKmh }
        if parsed.distanceM == nil { parsed.distanceM = prev.distanceM }
        if parsed.elapsedS == nil { parsed.elapsedS = prev.elapsedS }
        let elapsedReset = (prev.elapsedS != nil && (parsed.elapsedS ?? prev.elapsedS!) < prev.elapsedS!)
        let distanceReset = (prev.distanceM != nil && (parsed.distanceM ?? prev.distanceM!) < prev.distanceM!)
        if parsed.steps == nil {
            // A new pad session often omits steps for a packet. Copying the
            // previous walk's total onto 50 m of a new session is how Today
            // jumps to 30,118.
            parsed.steps = (elapsedReset || distanceReset) ? 0 : prev.steps
        }
        if parsed.calories == nil { parsed.calories = prev.calories }
        telemetry = parsed
        if !calorieStateRestored {
            calorieStateRestored = true
            restoreCalorieState()
        }
        // Pad counter reset (Stop finalizes the pad session, or the pad's own
        // timer): the pad is the master, so its counters follow it down and the
        // calorie estimate restarts with them. The step register is not part of
        // this test. It is a u16 that wraps and nothing here displays it, and
        // a wrap in the middle of a walk must not wipe that walk's calories.
        let regressed = (prev.elapsedS != nil && telemetry.elapsedS! < prev.elapsedS!)
            || (prev.distanceM != nil && telemetry.distanceM! < prev.distanceM!)
        if regressed { calorieTracker.reset() }
        // Credit only normal live telemetry intervals. A long gap is a pause
        // or disconnect, not many minutes of walking at the last known speed.
        if let last = lastTelemetryInstant,
           let prevSpeed = prev.speedKmh, prevSpeed > 0,
           let currentSpeed = telemetry.speedKmh, currentSpeed > 0
        {
            let gap = telemetryNow - last
            let gapS = Double(gap.components.seconds)
                + Double(gap.components.attoseconds) / 1_000_000_000_000_000_000
            if gapS > 0, gapS <= 5 {
                calorieTracker.addSample(speedKmh: prevSpeed, elapsedS: gapS)
            }
        }
        lastTelemetryInstant = telemetryNow
        persistCalorieState()
        emitStatus()
    }

    // MARK: - calorie state persistence
    //
    // Calorie integration is client-side; the pad's own counters (elapsed,
    // distance) survive reconnects, so we persist the kcal total keyed
    // against them and restore on the next connection.

    private static let knownPeripheralKey = "z1.knownPeripheralID"

    /// Prefer re-adopting the peripheral macOS already knows (instant) over a
    /// fresh scan (seconds, and it wakes every BLE radio in the room). Returns
    /// the device name and whether it came from the remembered identifier.
    private func resolvePeripheral(scanTimeout: TimeInterval) async throws -> (name: String, adopted: Bool) {
        if let saved = defaults.string(forKey: Self.knownPeripheralKey),
           let identifier = UUID(uuidString: saved),
           let name = transport.adoptKnownPeripheral(
               identifier: identifier,
               namePrefix: Z1Constants.deviceNamePrefix
           )
        {
            return (name, true)
        }
        let name = try await transport.scanForTreadmill(timeout: scanTimeout)
        return (name, false)
    }

    private func rememberPeripheral() {
        guard let identifier = transport.peripheralIdentifier else { return }
        defaults.set(identifier.uuidString, forKey: Self.knownPeripheralKey)
        // Flushed deliberately: this is only worth anything on the *next*
        // launch, and an unsynchronised write is lost if the process is killed
        // rather than quit — which is precisely when you want the fast path.
        defaults.synchronize()
    }

    private func forgetPeripheral() {
        defaults.removeObject(forKey: Self.knownPeripheralKey)
        defaults.synchronize()
    }

    /// Drop the BLE link immediately, without awaiting anything. For process
    /// exit only.
    public nonisolated func cancelConnectionNow() {
        transport.cancelConnectionNow()
    }

    private static let calorieStateKey = "z1.calorieState"

    /// The saved total only has to survive a crash. A restore credits the time
    /// and distance the pad counted since the save at the walk's average speed,
    /// so a stale save costs almost nothing and a frequent one costs a
    /// preferences write for no gain. Disconnects and quits save immediately.
    public static let calorieStateSaveInterval: Duration = .seconds(30)

    private var lastPersistInstant: ContinuousClock.Instant?
    private func persistCalorieState(force: Bool = false) {
        if !force, let last = lastPersistInstant, ContinuousClock.now - last < Self.calorieStateSaveInterval { return }
        lastPersistInstant = ContinuousClock.now
        defaults.set(
            [
                "totalKcal": calorieTracker.totalKcal,
                "elapsedS": telemetry.elapsedS ?? 0,
                "distanceM": telemetry.distanceM ?? 0,
            ],
            forKey: Self.calorieStateKey
        )
    }

    private func restoreCalorieState() {
        guard let state = defaults.dictionary(forKey: Self.calorieStateKey) else { return }
        let savedElapsed = state["elapsedS"] as? Int ?? 0
        let savedDistance = state["distanceM"] as? Int ?? 0
        let curElapsed = telemetry.elapsedS ?? 0
        let curDistance = telemetry.distanceM ?? 0
        let plan = CounterRestorePlan.make(
            savedElapsed: savedElapsed,
            savedDistance: savedDistance,
            savedOffsetElapsed: state["offsetElapsed"] as? Int ?? 0,
            savedOffsetDistance: state["offsetDistance"] as? Int ?? 0,
            savedKcal: state["totalKcal"] as? Double ?? 0,
            currentElapsed: curElapsed,
            currentDistance: curDistance
        )
        calorieTracker.totalKcal = plan.totalKcal
        let gapS = plan.gapElapsed
        let gapD = plan.gapDistance
        if gapS > 0, gapD > 0 {
            calorieTracker.addSample(speedKmh: Double(gapD) / Double(gapS) * 3.6, elapsedS: Double(gapS))
        }
    }

    private var lastEmittedStatus: Status?
    private func emitStatus() {
        var s = status
        s.speedKmh = telemetry.speedKmh ?? 0
        let moving = s.speedKmh > 0
        if moving { startHoldUntil = nil }
        // hold beltRunning for 5s after Start so omitted-speed telemetry can't flip button back
        let holding = startHoldUntil.map { ContinuousClock.now < $0 } ?? false
        s.beltRunning = moving || holding
        if !s.beltRunning { s.stopRequested = false }
        s.distanceM = max(0, telemetry.distanceM ?? 0)
        s.elapsedS = max(0, telemetry.elapsedS ?? 0)
        s.steps = modelledSteps
        s.padSteps = telemetry.steps
        s.impliedStrideM = impliedStrideM
        s.caloriesKcal = calorieTracker.totalKcal
        s.hasTelemetry = lastTelemetryInstant != nil
        // perf: skip duplicate yields (telemetry may re-emit same values)
        if let last = lastEmittedStatus, last == s { return }
        lastEmittedStatus = s
        status = s
        statusYield.yield(s)
    }

    private func mutate(_ body: (inout Status) -> Void) {
        body(&status)
        // `emitStatus` skips frames equal to the last one published. A frame
        // published here counts as published, or an identical telemetry frame
        // after a reconnect would be swallowed and `hasTelemetry` would stay
        // false for it.
        lastEmittedStatus = status
        statusYield.yield(status)
    }

    // MARK: - vendor channel

    @discardableResult
    private func vendorRoundtrip(
        _ frame: Data,
        pred: @escaping @Sendable (Frame) -> Bool,
        timeout: TimeInterval = Z1Constants.vendorResponseTimeout,
        intentEpoch: Int? = nil
    ) async throws -> Frame {
        if let intentEpoch, intentEpoch != controlCommandEpoch { throw CancellationError() }
        let id = UUID()
        return try await withCheckedThrowingContinuation { cont in
            var waiter = Waiter<Frame>(id: id, cont: cont)
            waiter.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                await self.timeoutVendorWaiter(id)
            }
            vendorWaiters.append((waiter, pred))
            Task {
                do {
                    await paceVendor()
                    if let intentEpoch, intentEpoch != controlCommandEpoch { throw CancellationError() }
                    try await transport.write(Z1Constants.charSupplementWrite, frame, withResponse: false)
                } catch {
                    failVendorWaiter(id, error)
                }
            }
        }
    }

    private func timeoutVendorWaiter(_ id: UUID) {
        guard let i = vendorWaiters.firstIndex(where: { $0.waiter.id == id }) else { return }
        let w = vendorWaiters.remove(at: i)
        w.waiter.cont.resume(throwing: Z1Error.vendorTimeout)
    }

    private func failVendorWaiter(_ id: UUID, _ error: Error) {
        guard let i = vendorWaiters.firstIndex(where: { $0.waiter.id == id }) else { return }
        let w = vendorWaiters.remove(at: i)
        w.waiter.timeout?.cancel()
        w.waiter.cont.resume(throwing: error)
    }

    // MARK: - FTMS control point

    private func cpCommand(_ cmd: Data, intentEpoch: Int? = nil) async throws -> Data {
        try Task.checkCancellation()
        if let intentEpoch, intentEpoch != controlCommandEpoch { throw CancellationError() }
        let id = UUID()
        let resp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var waiter = Waiter<Data>(id: id, cont: cont)
            waiter.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Z1Constants.vendorResponseTimeout))
                guard !Task.isCancelled, let self else { return }
                await self.timeoutCPWaiter(id)
            }
            cpWaiters.append((cmd[cmd.startIndex], waiter))
            Task {
                do {
                    await paceControl()
                    if let intentEpoch, intentEpoch != controlCommandEpoch { throw CancellationError() }
                    try await transport.write(Z1Constants.charControlPoint, cmd, withResponse: true)
                } catch {
                    failCPWaiter(id, error)
                }
            }
        }
        // indication: 80 <request-op> <result> [params...]
        if resp.count >= 3, resp[resp.startIndex] == 0x80 {
            let result = resp[resp.startIndex + 2]
            guard result == 1 else {
                if result == 5 { hasControl = false } // re-request control next time
                throw Z1Error.controlRefused(op: resp[resp.startIndex + 1], result: result)
            }
        }
        return resp
    }

    /// 0x77 vendor control tunnel — fallback when the control point refuses
    /// (the pad sometimes transiently answers result 4 after a session; the
    /// tunnel is the documented alternate path, see docs/protocol.md).
    private func vendorControl(_ op: UInt8, params: Data = Data(), intentEpoch: Int? = nil) async throws {
        let reply = try await vendorRoundtrip(
            Z1Protocol.buildFrame(cmd0: 0x77, cmd1: 0x01, data: Data([op]) + params),
            pred: { $0.cmd0 == 0x77 && $0.cmd1 == 0x81 && $0.data.first == op },
            intentEpoch: intentEpoch
        )
        let status = reply.data.count >= 2 ? reply.data[reply.data.startIndex + 1] : 0xFF
        guard status == 0 || status == 0x81 else {
            throw Z1Error.controlRefused(op: op, result: status)
        }
    }

    /// Send a control command, retrying once after a transient refusal
    /// (result 4), then falling back to the 0x77 vendor tunnel.
    private func controlCommand(_ cpBytes: Data, tunnelOp: UInt8, tunnelParams: Data = Data(), intentEpoch: Int? = nil) async throws {
        do {
            _ = try await cpCommand(cpBytes, intentEpoch: intentEpoch)
        } catch Z1Error.controlRefused(_, 4) {
            try await Task.sleep(for: .seconds(3))
            do {
                _ = try await cpCommand(cpBytes, intentEpoch: intentEpoch)
            } catch Z1Error.controlRefused(_, 4) {
                if let intentEpoch, intentEpoch != controlCommandEpoch { throw CancellationError() }
                if usesVendor {
                    try await vendorControl(tunnelOp, params: tunnelParams, intentEpoch: intentEpoch)
                } else {
                    throw Z1Error.controlRefused(op: tunnelOp, result: 4)
                }
            }
        }
    }

    private func timeoutCPWaiter(_ id: UUID) {
        guard let i = cpWaiters.firstIndex(where: { $0.waiter.id == id }) else { return }
        let w = cpWaiters.remove(at: i).waiter
        w.timeout?.cancel()
        w.cont.resume(throwing: Z1Error.controlPointTimeout)
    }

    private func failCPWaiter(_ id: UUID, _ error: Error) {
        guard let i = cpWaiters.firstIndex(where: { $0.waiter.id == id }) else { return }
        let w = cpWaiters.remove(at: i).waiter
        w.timeout?.cancel()
        w.cont.resume(throwing: error)
    }

    private func ensureControl() async throws {
        if !hasControl {
            _ = try await cpCommand(Data([Z1Constants.opRequestControl]))
            hasControl = true
        }
    }

    private func failAllWaiters(_ error: Error) {
        let vendors = vendorWaiters
        vendorWaiters.removeAll()
        for w in vendors {
            w.waiter.timeout?.cancel()
            w.waiter.cont.resume(throwing: error)
        }
        let cps = cpWaiters
        cpWaiters.removeAll()
        for (_, w) in cps {
            w.timeout?.cancel()
            w.cont.resume(throwing: error)
        }
    }

    // MARK: - helpers

    private func requireReady() throws {
        guard status.phase == .ready, unlocked else { throw Z1Error.notConnected }
    }

    /// Space writes at least `interval` apart, whatever order callers arrive in.
    ///
    /// Two commands queued inside the same 400 ms window would both measure
    /// their wait from the same earlier write, wake together and break the
    /// spacing the firmware needs. So the slot is claimed before sleeping
    /// (`slotEnd`), and after waking the gap is topped up against the real
    /// previous write (`lastWrite`), because timer wake-up jitter can make two
    /// neighbouring slots land closer than `interval`.
    private static func claimSlot(after slotEnd: ContinuousClock.Instant?, interval: Duration) -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        return max(now, slotEnd.map { $0 + interval } ?? now)
    }

    private static func wait(until instant: ContinuousClock.Instant) async {
        if instant > ContinuousClock.now { try? await Task.sleep(until: instant, clock: .continuous) }
    }

    private func paceVendor() async {
        let slot = Self.claimSlot(after: vendorSlotEnd, interval: Z1Constants.vendorMinInterval)
        vendorSlotEnd = slot
        await Self.wait(until: slot)
        if let previous = lastVendorWrite { await Self.wait(until: previous + Z1Constants.vendorMinInterval) }
        lastVendorWrite = ContinuousClock.now
    }

    private func paceControl() async {
        let slot = Self.claimSlot(after: controlSlotEnd, interval: Z1Constants.controlMinInterval)
        controlSlotEnd = slot
        await Self.wait(until: slot)
        if let previous = lastControlWrite { await Self.wait(until: previous + Z1Constants.controlMinInterval) }
        lastControlWrite = ContinuousClock.now
    }
}
