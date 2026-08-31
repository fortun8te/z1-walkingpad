import CoreBluetooth
import Foundation

public enum Z1Error: Error, Equatable, LocalizedError {
    case notFound
    case notConnected
    case unlockTimeout
    case vendorTimeout
    case controlPointTimeout
    case controlRefused(op: UInt8, result: UInt8)
    case speedOutOfRange(Double)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Z1 treadmill not found (is it on and not connected to another app?)"
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

public struct SessionSummary: Sendable, Equatable {
    public var durationS: Int
    public var distanceM: Int
    public var steps: Int
    public var avgSpeedKmh: Double
    public var caloriesKcal: Double
    public var weightKgUsed: Double

    public init(durationS: Int, distanceM: Int, steps: Int, avgSpeedKmh: Double, caloriesKcal: Double, weightKgUsed: Double) {
        self.durationS = durationS
        self.distanceM = distanceM
        self.steps = steps
        self.avgSpeedKmh = avgSpeedKmh
        self.caloriesKcal = caloriesKcal
        self.weightKgUsed = weightKgUsed
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
///
/// Mirrors `client.py`.
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
        public var speedKmh = 0.0
        public var distanceM = 0
        public var elapsedS = 0
        public var steps = 0
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

    private let transport = BLETransport()
    private var notifyPump: Task<Void, Never>?

    private var telemetry = Z1Protocol.TreadmillData()
    // The pad is the master of counters: time/distance/steps are shown
    // exactly as the pad reports them (it resets them on Stop and on its
    // own schedule). Calories are computed client-side but follow the same
    // lifecycle — the tracker resets whenever the pad's counters do.
    //
    // Opt-out: when persistStats is on, regressions fold into statOffsets
    // (and the calorie tracker keeps going), so stats accumulate across
    // sessions until clearStats() is called.
    private var calorieTracker = CalorieTracker()
    private var statOffsets = (elapsed: 0, distance: 0, steps: 0)
    public private(set) var persistStats = false
    private var stepEstimator = StepEstimator()
    private var stepSession = StepSession()
    public private(set) var lastStepsDelta = 0.0
    public private(set) var lastStepSource = StepSource.unknown

    /// Optional 200-step calibration. Nil = speed-dependent gait model.
    public private(set) var strideOverrideM: Double?

    /// Belt metres ÷ modelled step length at this walk's average speed.
    /// Pad step register is never used.
    public var stepsDisplay: Int {
        let metres = displayStat(telemetry.distanceM, statOffsets.distance)
        let seconds = displayStat(telemetry.elapsedS, statOffsets.elapsed)
        let live = telemetry.speedKmh ?? 0
        let speed = live > 0.4
            ? live
            : (seconds > 0 ? Double(metres) / Double(seconds) * 3.6 : 3.0)
        return GaitModel.steps(
            distanceM: metres,
            speedKmh: speed,
            calibratedM: strideOverrideM
        )
    }

    /// Modelled (or calibrated) step length in metres.
    public var impliedStrideM: Double? {
        let metres = displayStat(telemetry.distanceM, statOffsets.distance)
        guard metres >= 10 else { return nil }
        let seconds = displayStat(telemetry.elapsedS, statOffsets.elapsed)
        let live = telemetry.speedKmh ?? 0
        let speed = live > 0.4
            ? live
            : (seconds > 0 ? Double(metres) / Double(seconds) * 3.6 : 3.0)
        return GaitModel.stepLengthM(speedKmh: speed, calibratedM: strideOverrideM)
    }

    public func setStrideOverride(_ metres: Double?) {
        if let metres, metres > 0.3, metres < 1.5 {
            strideOverrideM = metres
        } else {
            strideOverrideM = nil
        }
        emitStatus()
    }
    private var calorieStateRestored = false
    private var lastTargetSpeed: Double?
    /// After Start, keep beltRunning true for a beat so omitted-speed
    /// telemetry cannot flip the button back to Start before the belt moves.
    private var startHoldUntil: ContinuousClock.Instant?
    private var hasControl = false
    private var unlocked = false
    private var expectingDisconnect = false
    private var lastVendorWrite: ContinuousClock.Instant?
    private var lastControlWrite: ContinuousClock.Instant?
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
    private var cpWaiters: [Waiter<Data>] = []

    public init(weightKg: Double = Z1Metrics.defaultWeightKg) {
        var cont: AsyncStream<Status>.Continuation!
        statusUpdates = AsyncStream { cont = $0 }
        statusYield = cont
        calorieTracker = CalorieTracker(weightKg: weightKg)
    }

    private var pumpStarted = false

    /// Deferred out of `init`: actor initializers can't capture `self` in
    /// escaping closures. Called at the top of `connect()`.
    private func ensurePumpStarted() {
        guard !pumpStarted else { return }
        pumpStarted = true
        transport.onDisconnect = { [weak self] in
            guard let self else { return }
            Task { await self.handleTransportDisconnect() }
        }
        notifyPump = Task { [weak self] in
            guard let self else { return }
            for await (uuidString, data) in self.transport.notifications {
                await self.handleNotification(uuidString, data)
            }
        }
    }

    public var deviceName: String? { status.deviceName }

    /// Estimated calories for the current session (since last `start()`).
    public var caloriesKcal: Double { calorieTracker.totalKcal }

    public func setWeight(_ kg: Double) {
        guard kg > 0 else { return }
        calorieTracker.weightKg = kg
        emitStatus()
    }

    // MARK: - connection

    public func connect() async throws {
        guard status.phase == .disconnected || status.phase == .error else { return }
        ensurePumpStarted()
        mutate {
            $0.phase = .scanning
            $0.errorMessage = nil
            $0.hasTelemetry = false
        }
        do {
            try await transport.waitPoweredOn()
            let (name, adopted) = try await resolvePeripheral()
            mutate { $0.phase = .connecting; $0.deviceName = name }
            do {
                try await transport.connect(timeout: Z1Constants.connectTimeout)
            } catch {
                // A remembered peripheral that will not answer is stale (pad
                // re-paired, or a different Mac wrote the identifier) — forget
                // it so the next attempt falls back to a scan.
                if adopted { forgetPeripheral() }
                throw error
            }
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

            // 1. supplement notify FIRST — before any vendor write
            try await transport.setNotify(Z1Constants.charSupplementNotify, enable: true)
            // telemetry (informational; stays silent pre-unlock)
            try? await transport.setNotify(Z1Constants.charTreadmillData, enable: true)
            try? await transport.setNotify(Z1Constants.charFitnessMachineStatus, enable: true)

            // 2. unlock — write without response; success arrives as 71 80
            unlocked = false
            _ = try await vendorRoundtrip(
                Z1Protocol.unlockFrame(deviceName: name),
                pred: { $0.cmd0 == Z1Constants.vopUnlock && $0.cmd1 == 0x80 },
                timeout: Z1Constants.unlockTimeout
            )
            unlocked = true

            // 3. extension init (best-effort: pad still works if these time out)
            _ = try? await vendorRoundtrip(
                Z1Protocol.sysInfoFrame(unixTime: UInt32(Date().timeIntervalSince1970)),
                pred: { $0.cmd0 == Z1Constants.vopUnlock && $0.cmd1 == 0x81 }
            )
            if let reply = try? await vendorRoundtrip(
                Z1Protocol.settingGetFrame(),
                pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x80 }
            ) {
                let props = Z1Protocol.parsePropertyRecords(reply.data)
                mutate { $0.properties = props }
            }

            // FTMS statics + control point indications
            if let range = try? await transport.read(Z1Constants.charSupportedSpeedRange), range.count >= 4 {
                let lo = Int(range[range.startIndex]) | (Int(range[range.startIndex + 1]) << 8)
                let hi = Int(range[range.startIndex + 2]) | (Int(range[range.startIndex + 3]) << 8)
                mutate {
                    $0.minSpeedKmh = Double(lo) / 100
                    $0.maxSpeedKmh = Double(hi) / 100
                }
            }
            try await transport.setNotify(Z1Constants.charControlPoint, enable: true)

            mutate { $0.phase = .ready }
        } catch {
            unlocked = false
            await transport.disconnect()
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
        if stopBelt, hasControl, unlocked {
            _ = try? await stop()
        }
        persistCalorieState(force: true)
        expectingDisconnect = true
        await transport.disconnect()
        resetConnectionState()
        mutate { $0.phase = .disconnected }
    }

    private func handleTransportDisconnect() {
        if expectingDisconnect {
            expectingDisconnect = false
            return
        }
        persistCalorieState(force: true)
        resetConnectionState()
        failAllWaiters(Z1Error.notConnected)
        mutate {
            $0.phase = .disconnected
            $0.errorMessage = "Connection lost"
        }
    }

    private func resetConnectionState() {
        unlocked = false
        hasControl = false
        lastTargetSpeed = nil
        startHoldUntil = nil
        telemetry = Z1Protocol.TreadmillData()
        calorieStateRestored = false
        lastTelemetryInstant = nil
        stepSession = StepSession()
        mutate { $0.beltRunning = false }
    }

    // MARK: - public control API

    public func start() async throws {
        try requireReady()
        try await ensureControl()
        // Skip only when the pad itself is already moving. Do not use last
        // reported speed: FTMS packets often omit the speed field, and we
        // then keep the previous value — a leftover 3 km/h after Stop made
        // Start a no-op and the belt never moved.
        if !status.beltRunning {
            if !persistStats {
                statOffsets = (elapsed: 0, distance: 0, steps: 0)
                calorieTracker.reset()
            }
            try await controlCommand(Data([Z1Constants.opStartOrResume]), tunnelOp: 0x07)
        }
        lastTargetSpeed = nil // belt restarts at minimum speed
        startHoldUntil = ContinuousClock.now + .seconds(5)
        mutate { $0.beltRunning = true }
    }

    @discardableResult
    public func stop() async throws -> SessionSummary {
        try requireReady()
        try await ensureControl()
        // summary first: the pad resets its counters when Stop lands
        let summary = sessionSummary()
        try await controlCommand(
            Data([Z1Constants.opStopOrPause, Z1Constants.stopParamStop]), tunnelOp: 0x08, tunnelParams: Data([0x01])
        )
        telemetry.speedKmh = 0
        startHoldUntil = nil
        mutate { $0.beltRunning = false }
        return summary
    }

    public func pause() async throws {
        try requireReady()
        try await ensureControl()
        try await controlCommand(
            Data([Z1Constants.opStopOrPause, Z1Constants.stopParamPause]), tunnelOp: 0x08, tunnelParams: Data([0x02])
        )
        telemetry.speedKmh = 0
        startHoldUntil = nil
        mutate { $0.beltRunning = false }
    }

    public func setSpeed(_ kmh: Double) async throws {
        try requireReady()
        guard kmh >= status.minSpeedKmh, kmh <= status.maxSpeedKmh else {
            throw Z1Error.speedOutOfRange(kmh)
        }
        try await ensureControl()
        let value = UInt16((kmh * 100).rounded())
        let params = Data([UInt8(value & 0xFF), UInt8(value >> 8)])
        try await controlCommand(Data([Z1Constants.opSetTargetSpeed]) + params, tunnelOp: 0x02, tunnelParams: params)
        lastTargetSpeed = kmh
    }

    /// Nudge speed up; returns the new target.
    @discardableResult
    public func speedUp(deltaKmh: Double = 0.1) async throws -> Double {
        try await nudgeSpeed(deltaKmh)
    }

    /// Nudge speed down; returns the new target.
    @discardableResult
    public func speedDown(deltaKmh: Double = 0.1) async throws -> Double {
        try await nudgeSpeed(-deltaKmh)
    }

    private func nudgeSpeed(_ delta: Double) async throws -> Double {
        // prefer the last commanded target: telemetry lags ~1s
        let current = lastTargetSpeed ?? telemetry.speedKmh ?? status.minSpeedKmh
        // delta already snapped to 0.1 kmh by ViewModel; just add and snap
        var target = ((current + delta) * 10).rounded() / 10
        if target == current {
            // tiny delta rounded away — force exactly one pad step in delta direction
            let step = delta >= 0 ? 0.1 : -0.1
            target = ((current + step) * 10).rounded() / 10
        }
        target = max(status.minSpeedKmh, min(status.maxSpeedKmh, target))
        try await setSpeed(target)
        return target
    }

    /// Sync the pad's own LED display units. Per the docs/protocol.md property
    /// table, property 1 is "units / screen language" and bit 1 (0x0002)
    /// selects miles vs km; all other bits are preserved from the cached
    /// SETTING_GET dump (default 0 if absent).
    public func setDisplayUnits(imperial: Bool) async throws {
        try requireReady()
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
        let current = status.properties[10] ?? 0
        let value = (current & ~0xE0) | (2 << 5)
        _ = try await vendorRoundtrip(
            Z1Protocol.propertyWriteFrame(propID: 10, value: UInt16(value)),
            pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x81 && $0.data.first == 10 }
        )
        mutate { $0.properties[10] = value }
    }

    /// Current session metrics: the pad's own counters plus our kcal.
    /// With persistStats on, totals accumulate across sessions since the
    /// last clearStats().
    public func sessionSummary() -> SessionSummary {
        let durationS = displayStat(telemetry.elapsedS, statOffsets.elapsed)
        let distanceM = displayStat(telemetry.distanceM, statOffsets.distance)
        let avg: Double = (durationS > 0 && distanceM > 0)
            ? (Double(distanceM) / Double(durationS) * 3.6 * 100).rounded() / 100
            : 0
        return SessionSummary(
            durationS: durationS,
            distanceM: distanceM,
            steps: stepsDisplay,
            avgSpeedKmh: avg,
            caloriesKcal: (calorieTracker.totalKcal * 10).rounded() / 10,
            weightKgUsed: calorieTracker.weightKg
        )
    }

    // MARK: - stats persistence

    public func setPersistStats(_ on: Bool) {
        persistStats = on
        if !on {
            // back to pad-as-master: drop the accumulated offsets
            statOffsets = (elapsed: 0, distance: 0, steps: 0)
        }
        emitStatus()
    }

    /// Zero all accumulated stats (offsets + calorie estimate) and the
    /// on-disk calorie state, so nothing restores old totals later.
    public func clearStats() {
        statOffsets = (elapsed: 0, distance: 0, steps: 0)
        calorieTracker.reset()
        UserDefaults.standard.removeObject(forKey: Self.calorieStateKey)
        persistCalorieState(force: true)
        emitStatus()
    }

    private func displayStat(_ cur: Int?, _ offset: Int) -> Int {
        max(0, (cur ?? 0) + offset)
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
            if !cpWaiters.isEmpty {
                let w = cpWaiters.removeFirst()
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
                mutate { $0.beltRunning = false } // safety-key / user stop or pause
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
        _ = stepSession.ingest(
            pad: telemetry.steps ?? 0,
            previousPad: prev.steps,
            elapsedReset: elapsedReset,
            distanceReset: distanceReset,
            distanceM: telemetry.distanceM ?? 0,
            lastGoodStrideM: UserDefaults.standard.object(forKey: "z1.lastGoodStrideM") as? Double
        )
        if let implied = impliedStrideM, (0.35...0.85).contains(implied) {
            UserDefaults.standard.set(implied, forKey: "z1.lastGoodStrideM")
        }

        if !calorieStateRestored {
            calorieStateRestored = true
            restoreCalorieState()
        }
        let firstCounters = prev.distanceM == nil || prev.steps == nil
        // pad counter reset (Stop finalizes the pad session, or the pad's
        // own timer). Default: the pad is the master — stats follow it down.
        // With persistStats on: fold the final values into the offsets and
        // keep accumulating instead.
        let regressed = (prev.elapsedS != nil && telemetry.elapsedS! < prev.elapsedS!)
            || (prev.distanceM != nil && telemetry.distanceM! < prev.distanceM!)
            || (prev.steps != nil && telemetry.steps! < prev.steps!)
        if regressed {
            // Disconnect / pad counter reset is not a new walk. Carry the
            // previous totals; calories stay. User Start on a stopped belt
            // is what zeros this.
            statOffsets.elapsed += prev.elapsedS ?? 0
            statOffsets.distance += prev.distanceM ?? 0
            statOffsets.steps += stepSession.display(pad: prev.steps ?? 0)
            lastStepsDelta = 0
            lastStepSource = .unknown
        } else {
            let result = stepEstimator.feed(
                previous: prev,
                current: telemetry,
                intervalSpeedKmh: prev.speedKmh
            )
            lastStepsDelta = firstCounters ? 0 : result.delta
            lastStepSource = result.source
        }
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
    private func resolvePeripheral() async throws -> (name: String, adopted: Bool) {
        if let saved = UserDefaults.standard.string(forKey: Self.knownPeripheralKey),
           let identifier = UUID(uuidString: saved),
           let name = transport.adoptKnownPeripheral(
               identifier: identifier,
               namePrefix: Z1Constants.deviceNamePrefix
           )
        {
            return (name, true)
        }
        let name = try await transport.scan(
            namePrefix: Z1Constants.deviceNamePrefix,
            timeout: Z1Constants.scanTimeout
        )
        return (name, false)
    }

    private func rememberPeripheral() {
        guard let identifier = transport.peripheralIdentifier else { return }
        UserDefaults.standard.set(identifier.uuidString, forKey: Self.knownPeripheralKey)
        // Flushed deliberately: this is only worth anything on the *next*
        // launch, and an unsynchronised write is lost if the process is killed
        // rather than quit — which is precisely when you want the fast path.
    }

    private func forgetPeripheral() {
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralKey)
    }

    /// Drop the BLE link immediately, without awaiting anything. For process
    /// exit only.
    public nonisolated func cancelConnectionNow() {
        transport.cancelConnectionNow()
    }

    private static let calorieStateKey = "z1.calorieState"

    private var lastPersistInstant: ContinuousClock.Instant?
    private func persistCalorieState(force: Bool = false) {
        // throttle UserDefaults writes — not every 1Hz telemetry tick needs a flush
        if !force, let last = lastPersistInstant, ContinuousClock.now - last < .seconds(5) { return }
        lastPersistInstant = ContinuousClock.now
        UserDefaults.standard.set(
            [
                "totalKcal": calorieTracker.totalKcal,
                "elapsedS": telemetry.elapsedS ?? 0,
                "distanceM": telemetry.distanceM ?? 0,
                "offsetElapsed": statOffsets.elapsed,
                "offsetDistance": statOffsets.distance,
            ],
            forKey: Self.calorieStateKey
        )
    }

    private func restoreCalorieState() {
        guard let state = UserDefaults.standard.dictionary(forKey: Self.calorieStateKey) else { return }
        let savedElapsed = state["elapsedS"] as? Int ?? 0
        let savedDistance = state["distanceM"] as? Int ?? 0
        let curElapsed = telemetry.elapsedS ?? 0
        let curDistance = telemetry.distanceM ?? 0
        statOffsets.elapsed = state["offsetElapsed"] as? Int ?? statOffsets.elapsed
        statOffsets.distance = state["offsetDistance"] as? Int ?? statOffsets.distance
        calorieTracker.totalKcal = state["totalKcal"] as? Double ?? calorieTracker.totalKcal
        if curElapsed < savedElapsed || curDistance < savedDistance {
            // Pad reset while this walk is still the same walk.
            statOffsets.elapsed += savedElapsed
            statOffsets.distance += savedDistance
            return
        }
        let gapS = curElapsed - savedElapsed
        let gapD = curDistance - savedDistance
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
        s.distanceM = displayStat(telemetry.distanceM, statOffsets.distance)
        s.elapsedS = displayStat(telemetry.elapsedS, statOffsets.elapsed)
        s.steps = stepsDisplay
        s.impliedStrideM = impliedStrideM
        s.caloriesKcal = calorieTracker.totalKcal
        s.hasTelemetry = true
        // perf: skip duplicate yields (telemetry may re-emit same values)
        if let last = lastEmittedStatus, last == s { return }
        lastEmittedStatus = s
        status = s
        statusYield.yield(s)
    }

    private func mutate(_ body: (inout Status) -> Void) {
        body(&status)
        statusYield.yield(status)
    }

    // MARK: - vendor channel

    @discardableResult
    private func vendorRoundtrip(
        _ frame: Data,
        pred: @escaping @Sendable (Frame) -> Bool,
        timeout: TimeInterval = Z1Constants.vendorResponseTimeout
    ) async throws -> Frame {
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

    private func cpCommand(_ cmd: Data) async throws -> Data {
        let id = UUID()
        let resp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var waiter = Waiter<Data>(id: id, cont: cont)
            waiter.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Z1Constants.vendorResponseTimeout))
                guard !Task.isCancelled, let self else { return }
                await self.timeoutCPWaiter(id)
            }
            cpWaiters.append(waiter)
            Task {
                do {
                    await paceControl()
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
    private func vendorControl(_ op: UInt8, params: Data = Data()) async throws {
        let reply = try await vendorRoundtrip(
            Z1Protocol.buildFrame(cmd0: 0x77, cmd1: 0x01, data: Data([op]) + params),
            pred: { $0.cmd0 == 0x77 && $0.cmd1 == 0x81 && $0.data.first == op }
        )
        let status = reply.data.count >= 2 ? reply.data[reply.data.startIndex + 1] : 0xFF
        guard status == 0 || status == 0x81 else {
            throw Z1Error.controlRefused(op: op, result: status)
        }
    }

    /// Send a control command, retrying once after a transient refusal
    /// (result 4), then falling back to the 0x77 vendor tunnel.
    private func controlCommand(_ cpBytes: Data, tunnelOp: UInt8, tunnelParams: Data = Data()) async throws {
        do {
            _ = try await cpCommand(cpBytes)
        } catch Z1Error.controlRefused(_, 4) {
            try await Task.sleep(for: .seconds(3))
            do {
                _ = try await cpCommand(cpBytes)
            } catch Z1Error.controlRefused(_, 4) {
                try await vendorControl(tunnelOp, params: tunnelParams)
            }
        }
    }

    private func timeoutCPWaiter(_ id: UUID) {
        guard let i = cpWaiters.firstIndex(where: { $0.id == id }) else { return }
        let w = cpWaiters.remove(at: i)
        w.cont.resume(throwing: Z1Error.controlPointTimeout)
    }

    private func failCPWaiter(_ id: UUID, _ error: Error) {
        guard let i = cpWaiters.firstIndex(where: { $0.id == id }) else { return }
        let w = cpWaiters.remove(at: i)
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
        for w in cps {
            w.timeout?.cancel()
            w.cont.resume(throwing: error)
        }
    }

    // MARK: - helpers

    private func requireReady() throws {
        guard status.phase == .ready, unlocked else { throw Z1Error.notConnected }
    }

    private func paceVendor() async {
        if let last = lastVendorWrite {
            let remaining = Z1Constants.vendorMinInterval - (ContinuousClock.now - last)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        lastVendorWrite = ContinuousClock.now
    }

    private func paceControl() async {
        if let last = lastControlWrite {
            let remaining = Z1Constants.controlMinInterval - (ContinuousClock.now - last)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        lastControlWrite = ContinuousClock.now
    }
}
