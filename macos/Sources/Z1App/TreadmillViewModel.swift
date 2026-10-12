import AppKit
import Foundation
import Observation
import SwiftUI
import Z1Core

/// The bridge between the `Z1Treadmill` actor and the window.
///
/// Observable, so a view redraws only for the properties it actually read.
/// Live telemetry sits in `live`, one field per number; history and today's
/// totals change far less often and are published here, each only when its
/// value really changed.
///
/// All BLE-facing values stay metric (km/h, metres, kg: the wire protocol
/// requires it); conversion to the user's display units happens here.
@MainActor
@Observable
final class TreadmillViewModel {
    let live = LiveState()

    /// The last full frame, for logic. Views read `live`.
    @ObservationIgnored private(set) var status = Z1Treadmill.Status()
    private(set) var busy = false
    /// Last failed command, shown until the next success. Kept apart from
    /// the status stream, which replaces its own error every second.
    private(set) var commandError: String?
    /// How many scan/connect attempts have failed in a row. One failure is
    /// normal (the pad sleeps); a run of them means it is not there at all.
    private(set) var failedAttempts = 0
    /// Which transition the button is mid-way through, latched at tap time so
    /// telemetry arriving early cannot flip the label to the wrong verb.
    private(set) var pendingVerb: String?
    /// Speed picked while the belt was stopped (km/h); applied on the next Start.
    private(set) var pendingTargetKmh: Double?

    // MARK: history (published only on change)

    /// Bumps whenever the session store's contents change. Anything computed
    /// from the store reads it, so it redraws exactly then.
    private(set) var historyRevision = 0
    private(set) var recentWalks: [WalkSession] = []
    private(set) var highScores = HighScores()
    private(set) var achievements: [Achievement] = []
    /// Today, history plus the walk in progress. Changes with every frame
    /// while the belt moves; the numbers under the almanac read it.
    private(set) var today = DayTotals(day: Date())
    /// Today again, rounded to what a chart can show (whole minutes, 50 m,
    /// 50 steps). Bars and cells read this, so they redraw a few times a walk
    /// instead of every second.
    private(set) var todayCoarse = DayTotals(day: Date())
    /// Why start-at-login did not take, if it did not.
    private(set) var loginItemMessage: String?

    // MARK: persisted settings (UserDefaults, the same store @AppStorage uses)

    /// Body weight, always stored in kg; displayed and edited in the current
    /// unit. Fed to the calorie maths in kg.
    var weightKg: Double {
        didSet {
            UserDefaults.standard.set(weightKg, forKey: Self.weightKey)
            if canCommand { Task { await treadmill.setWeight(weightKg) } }
            recomputeToday()
        }
    }

    /// Display units: true = Imperial (mph/mi/lb). Also syncs the pad's own
    /// display (best-effort).
    var unitsImperial: Bool {
        didSet {
            UserDefaults.standard.set(unitsImperial, forKey: Self.unitsKey)
            if canCommand { Task { try? await treadmill.setDisplayUnits(imperial: unitsImperial) } }
        }
    }

    /// − / + nudge size, in the current display unit.
    var speedStep: Double {
        didSet { UserDefaults.standard.set(speedStep, forKey: Self.stepKey) }
    }

    /// Optional hand-measured stride in metres. 0 = gait model from speed.
    var strideOverrideM: Double {
        didSet {
            UserDefaults.standard.set(strideOverrideM, forKey: Self.strideKey)
            if canCommand { Task { await treadmill.setStrideOverride(strideOverrideM > 0 ? strideOverrideM : nil) } }
        }
    }

    /// Accumulate stats across pad restarts until cleared. Off = pad is master.
    var persistStats: Bool {
        didSet {
            UserDefaults.standard.set(persistStats, forKey: Self.persistKey)
            if canCommand { Task { await treadmill.setPersistStats(persistStats) } }
        }
    }

    /// Daily walking target in minutes (0 = no goal).
    var dailyGoalMinutes: Int {
        didSet { UserDefaults.standard.set(dailyGoalMinutes, forKey: Self.goalKey) }
    }

    /// Measure the day in steps instead of minutes.
    var goalIsSteps: Bool {
        didSet { UserDefaults.standard.set(goalIsSteps, forKey: Self.goalKindKey) }
    }

    /// Step goal; 8,000 is where the mortality-risk curve plateaus for
    /// under-60s in the step-count meta-analyses.
    var dailyGoalSteps: Int {
        didSet { UserDefaults.standard.set(dailyGoalSteps, forKey: Self.goalStepsKey) }
    }

    /// Quiet-day nudges. Strictly capped: work hours, weekdays, at most two a day.
    var remindersEnabled: Bool {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: Self.remindersKey) }
    }

    var reminderGapHours: Int {
        didSet { UserDefaults.standard.set(reminderGapHours, forKey: Self.reminderGapKey) }
    }

    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsKey)
            if notificationsEnabled { notifier.requestAuthorizationIfNeeded() }
        }
    }

    /// ⌃⌥W starts or stops the belt from anywhere.
    var globalShortcutEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalShortcutEnabled, forKey: Self.globalShortcutKey)
            applyGlobalShortcut()
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            loginItemMessage = LoginItem.set(launchAtLogin)
            if loginItemMessage != nil { launchAtLogin = LoginItem.isEnabled }
        }
    }

    /// Pull the latest Health body-mass sample from the iCloud Shortcuts file.
    var useHealthWeight: Bool {
        didSet {
            UserDefaults.standard.set(useHealthWeight, forKey: Self.useHealthWeightKey)
            if useHealthWeight { applyHealthWeightIfAvailable() }
        }
    }

    // MARK: machinery (not observed)

    /// Lazy so a preview build (`Z1_PREVIEW=1`) never creates a
    /// CBCentralManager: an unsigned harness binary is killed by TCC the
    /// moment it touches Bluetooth, and a second central would fight the real
    /// app for the single-connection pad.
    @ObservationIgnored private(set) lazy var treadmill = Z1Treadmill()

    /// Set by the UI preview harness only. Skips BLE, timers, notifications.
    static var isPreview: Bool { ProcessInfo.processInfo.environment["Z1_PREVIEW"] == "1" }

    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var automaticConnectionEnabled = true
    @ObservationIgnored private var healthFinalizeTask: Task<Void, Never>?
    @ObservationIgnored private var reminderTimer: Timer?
    @ObservationIgnored private var weightTimer: Timer?
    @ObservationIgnored private var liveStepTimer: Timer?
    @ObservationIgnored private var stepSmoother = StepSmoother()
    @ObservationIgnored private var lastStepPacketAt = Date()
    @ObservationIgnored private var highestDisplayedSteps = 0
    @ObservationIgnored var healthTracker: RemoteSessionTracker
    @ObservationIgnored let sessionStore: SessionStore
    @ObservationIgnored private let sleepBlocker = SleepBlocker()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Guards against an old reconnect task clearing a newer one's handle.
    @ObservationIgnored private var reconnectGeneration = 0
    /// Coalesced speed target for rapid − / + taps, so `busy` drops none.
    @ObservationIgnored private var coalescedTargetKmh: Double?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    /// Today from the store alone, without the open walk.
    @ObservationIgnored var storedToday = DayTotals(day: Date())
    @ObservationIgnored private var historySignature = HistorySignature()
    @ObservationIgnored private var lastTrackerSave = Date.distantPast

    static let weightKey = "weightKg"
    static let unitsKey = "unitsImperial"
    static let stepKey = "speedStep"
    static let persistKey = "persistStats"
    static let goalKey = "dailyGoalMinutes"
    static let goalKindKey = "goalIsSteps"
    static let remindersKey = "remindersEnabled"
    static let reminderGapKey = "reminderGapHours"
    static let reminderLogKey = "z1.reminderLog"
    static let goalStepsKey = "dailyGoalSteps"
    static let notificationsKey = "notificationsEnabled"
    static let strideKey = "z1.calibratedStrideM"
    static let globalShortcutKey = "z1.globalShortcut"
    static let loginStatusKey = "loginItemStatus"
    static let connectionLogKey = "z1.connectionLog"
    static let healthTrackerKey = "z1.automaticHealthSession"
    static let useHealthWeightKey = "z1.useHealthWeight"

    init() {
        let defaults = UserDefaults.standard
        let storedWeight = defaults.double(forKey: Self.weightKey)
        weightKg = storedWeight > 0 ? storedWeight : Z1Metrics.defaultWeightKg
        // The Z1 protocol and display are metric, so default to km/h.
        unitsImperial = defaults.object(forKey: Self.unitsKey) as? Bool ?? false
        let storedStep = defaults.double(forKey: Self.stepKey)
        speedStep = storedStep > 0 ? storedStep : 0.1
        persistStats = defaults.bool(forKey: Self.persistKey)
        strideOverrideM = defaults.double(forKey: Self.strideKey)
        dailyGoalMinutes = defaults.object(forKey: Self.goalKey) as? Int ?? 120
        goalIsSteps = defaults.bool(forKey: Self.goalKindKey)
        remindersEnabled = defaults.object(forKey: Self.remindersKey) as? Bool ?? true
        reminderGapHours = defaults.object(forKey: Self.reminderGapKey) as? Int ?? 3
        dailyGoalSteps = defaults.object(forKey: Self.goalStepsKey) as? Int ?? 8_000
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        launchAtLogin = LoginItem.isEnabled
        globalShortcutEnabled = defaults.object(forKey: Self.globalShortcutKey) as? Bool ?? true
        useHealthWeight = defaults.object(forKey: Self.useHealthWeightKey) as? Bool ?? true
        healthTracker = Self.restoreHealthTracker(from: defaults)
        sessionStore = Self.isPreview ? PreviewHarness.sessionStore() : SessionStore()

        if Self.isPreview {
            refreshHistory()
            PreviewHarness.start(self)
            return
        }

        Task { await treadmill.setWeight(weightKg) }
        Task { await treadmill.setPersistStats(persistStats) }
        if strideOverrideM > 0 {
            Task { await treadmill.setStrideOverride(strideOverrideM) }
        }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await s in self.treadmill.statusUpdates {
                guard !Task.isCancelled else { break }
                self.receiveStatus(s)
            }
        }
        scheduleHealthFinalization()
        scheduleReconnect(after: 0.5)
        // First check only after a settling period: being reminded to walk
        // thirty seconds after logging in is how reminders get turned off.
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWalkReminder() }
        }
        reminderTimer?.tolerance = 60
        // The pad accepts one central at a time, so a link left up at exit is
        // what makes the next launch fail to connect. Drop it on the way out.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [treadmill] _ in
            treadmill.cancelConnectionNow()
        }
        undoAutomaticLoginItem()
        refreshHistory()
        installPowerObservers()
        startHousekeeping()
        applyGlobalShortcut()
        if notificationsEnabled { notifier.requestAuthorizationIfNeeded() }
        applyHealthWeightIfAvailable()
        // Body weight changes a few times a week at most.
        weightTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyHealthWeightIfAvailable() }
        }
        weightTimer?.tolerance = 60
    }

    // No deinit: this model lives as long as the process.

    func applyHealthWeightIfAvailable() {
        guard useHealthWeight, let sample = HealthWeight.load() else { return }
        let rounded = (sample.kg * 10).rounded() / 10
        if abs(weightKg - rounded) >= 0.05 {
            weightKg = rounded
        }
    }

    var isConnected: Bool { live.isConnected }
    var isConnecting: Bool { live.isConnecting }

    // MARK: - display-unit helpers

    var speedUnitLabel: String { unitsImperial ? "mph" : "km/h" }
    var weightUnitLabel: String { unitsImperial ? "lb" : "kg" }

    /// Current belt speed in the display unit.
    var displaySpeed: Double {
        unitsImperial ? Z1Units.kmhToMph(live.speedKmh) : live.speedKmh
    }

    /// − / + nudge in km/h for the wire protocol, snapped to the pad's 0.1 grid.
    private var speedStepKmh: Double {
        let raw = unitsImperial ? Z1Units.mphToKmh(speedStep) : speedStep
        return max(0.1, (raw * 10).rounded() / 10)
    }

    func formatDistance(_ meters: Int) -> String {
        if unitsImperial {
            let miles = Z1Units.metersToMiles(Double(meters))
            return miles < 0.1
                ? "\(Int(Z1Units.metersToFeet(Double(meters)).rounded())) ft"
                : String(format: "%.2f mi", miles)
        }
        // Always km in metric. Switching units at 1000 m made the number jump
        // between "940 m" and "1.02 km" mid-walk, which reads as a reset.
        return String(format: "%.2f km", Double(meters) / 1000)
    }

    func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, sec = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Compact duration for summaries: "1h 12m" / "34m".
    func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var strideLabel: String {
        guard let stride = live.impliedStrideM else { return "—" }
        return "\(Int((stride * 100).rounded())) cm modelled"
    }

    // MARK: - actions

    /// The harness has no pad: actions are inert there, and touching
    /// `treadmill` would create a Bluetooth central.
    private var canCommand: Bool { !Self.isPreview }

    func connectTapped() {
        guard canCommand, !busy else { return }
        run {
            if self.isConnected {
                self.automaticConnectionEnabled = false
                self.reconnectTask?.cancel()
                await self.treadmill.disconnect()
            } else {
                self.automaticConnectionEnabled = true
                try await self.treadmill.connect()
                // If the pad's own display units disagree with the setting,
                // push ours down (best-effort).
                let props = await self.treadmill.status.properties
                let padImperial = Z1Units.propertyIndicatesImperial(props[1] ?? 0)
                if padImperial != self.unitsImperial {
                    try? await self.treadmill.setDisplayUnits(imperial: self.unitsImperial)
                }
            }
        }
    }

    func startStopTapped() {
        guard canCommand, !busy, isConnected else { return }
        // Latch the intent at tap. Re-reading beltRunning inside `run` races
        // telemetry: a leftover speed from the last walk made Start send Stop.
        let stopping = status.beltRunning
        pendingVerb = stopping ? "Stopping…" : "Starting…"
        run {
            defer { self.pendingVerb = nil }
            if stopping {
                _ = try await self.treadmill.stop()
            } else {
                try await self.treadmill.start()
                // A speed picked at a standstill is applied as soon as the belt
                // moves: the pad always starts at its minimum.
                if let pending = self.pendingTargetKmh {
                    self.pendingTargetKmh = nil
                    try await self.treadmill.setSpeed(pending)
                }
            }
        }
    }

    /// Jump straight to a speed, in the current display unit.
    ///
    /// The pad only accepts speed changes while the belt moves, so a value
    /// picked at a standstill is remembered and applied right after Start.
    func setSpeed(_ displayValue: Double) {
        guard canCommand, isConnected else { return }
        let kmh = unitsImperial ? Z1Units.mphToKmh(displayValue) : displayValue
        let clamped = (min(max(kmh, status.minSpeedKmh), status.maxSpeedKmh) * 10).rounded() / 10
        guard status.beltRunning else {
            if pendingTargetKmh != clamped { pendingTargetKmh = clamped }
            return
        }
        // Dial commits go out at once, not through the − / + queue.
        coalescedTargetKmh = nil
        speedTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.treadmill.setSpeed(clamped)
                self.clearCommandError()
            } catch {
                self.commandError = error.localizedDescription
            }
        }
    }

    /// Selectable speed range in display units, converted exactly.
    var speedRange: ClosedRange<Double> {
        let low = unitsImperial ? Z1Units.kmhToMph(live.minSpeedKmh) : live.minSpeedKmh
        let high = unitsImperial ? Z1Units.kmhToMph(live.maxSpeedKmh) : live.maxSpeedKmh
        guard low < high else { return 1.6...6.4 }
        return low ... high
    }

    /// A speed chosen at a standstill, waiting for the next Start.
    var pendingTargetDisplaySpeed: Double? {
        guard let pendingTargetKmh else { return nil }
        return unitsImperial ? Z1Units.kmhToMph(pendingTargetKmh) : pendingTargetKmh
    }

    func speedUpTapped() { nudge(byKmh: speedStepKmh) }
    func speedDownTapped() { nudge(byKmh: -speedStepKmh) }

    /// ↑ / ↓: half a unit at a time.
    func bigSpeedUpTapped() { nudge(byKmh: halfUnitKmh) }
    func bigSpeedDownTapped() { nudge(byKmh: -halfUnitKmh) }

    private var halfUnitKmh: Double { unitsImperial ? Z1Units.mphToKmh(0.5) : 0.5 }

    /// While walking a nudge goes to the pad; at a standstill it moves the
    /// speed the next Start will use, so the speed can be set before walking.
    private func nudge(byKmh delta: Double) {
        guard canCommand, isConnected else { return }
        if status.beltRunning {
            enqueueSpeedChange(deltaKmh: delta)
            return
        }
        let base = pendingTargetKmh ?? status.minSpeedKmh
        let next = (min(max(base + delta, status.minSpeedKmh), status.maxSpeedKmh) * 10).rounded() / 10
        if pendingTargetKmh != next { pendingTargetKmh = next }
    }

    /// Harness only: a speed queued for Start, to show the standstill flow.
    func previewQueueSpeed(_ kmh: Double) {
        guard Self.isPreview else { return }
        pendingTargetKmh = kmh
    }

    /// The speed the readout should point at: the belt's while it moves, the
    /// one queued for Start while it does not.
    var targetDisplaySpeed: Double? {
        live.beltRunning ? displaySpeed : pendingTargetDisplaySpeed
    }

    /// Rapid taps accumulate and go out once, 120 ms after the last.
    private func enqueueSpeedChange(deltaKmh: Double) {
        let base = coalescedTargetKmh ?? status.speedKmh
        let next = min(max(base + deltaKmh, status.minSpeedKmh), status.maxSpeedKmh)
        coalescedTargetKmh = (next * 10).rounded() / 10
        speedTask?.cancel()
        speedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let target = self.coalescedTargetKmh else { return }
            self.coalescedTargetKmh = nil
            do {
                try await self.treadmill.setSpeed(target)
                self.clearCommandError()
            } catch {
                self.commandError = error.localizedDescription
            }
        }
    }

    func clearStatsTapped() {
        guard canCommand else { return }
        Task { await treadmill.clearStats() }
    }

    // MARK: - quitting

    enum QuitMode {
        /// Leave the belt exactly as it is; only free the pad's BLE slot.
        case leaveBelt
        /// Stop the belt and put the pad to sleep first.
        case stopBelt
    }

    /// Set by the in-window Quit buttons, so the terminate check does not ask
    /// a question the user just answered.
    @ObservationIgnored private(set) var requestedQuit: QuitMode?

    func quit() {
        requestedQuit = .leaveBelt
        NSApp.terminate(nil)
    }

    func stopBeltAndQuit() {
        requestedQuit = .stopBelt
        NSApp.terminate(nil)
    }

    /// The terminate was cancelled: forget the request.
    func quitCancelled() {
        requestedQuit = nil
    }

    /// Everything that must happen before the process exits, capped at 3 s
    /// so a pad that does not answer can never hang the quit.
    func shutdown(_ mode: QuitMode) async {
        automaticConnectionEnabled = false
        reconnectTask?.cancel()
        sleepBlocker.setActive(false)
        hotKey.unregister()
        persistHealthTracker()
        guard !Self.isPreview else { return }
        let treadmill = self.treadmill
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if mode == .stopBelt { try? await treadmill.sleep() }
                await treadmill.disconnect()
            }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func run(_ op: @MainActor @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await op()
                clearCommandError()
            } catch {
                // Surface command failures on screen: a silent retry loop is
                // how "I hit Start and nothing happens" happens.
                commandError = error.localizedDescription
                NSLog("Z1App: \(error.localizedDescription)")
            }
        }
    }

    private func clearCommandError() {
        if commandError != nil { commandError = nil }
    }

    // MARK: - global shortcut

    private func applyGlobalShortcut() {
        guard !Self.isPreview else { return }
        if globalShortcutEnabled {
            hotKey.register { [weak self] in
                guard let self else { return }
                if self.isConnected {
                    self.startStopTapped()
                } else {
                    NSSound.beep()
                }
            }
        } else {
            hotKey.unregister()
        }
    }

    // MARK: - telemetry

    private func receiveStatus(_ newStatus: Z1Treadmill.Status) {
        let previousPhase = status.phase
        stepSmoother.speedKmh = newStatus.speedKmh
        stepSmoother.strideM = newStatus.impliedStrideM
            ?? GaitModel.stepLengthM(speedKmh: max(0.8, newStatus.speedKmh))
        stepSmoother.ingest(reportedSteps: newStatus.steps, distanceM: newStatus.distanceM)
        lastStepPacketAt = Date()
        let packetDisplay = Int(stepSmoother.displaySteps.rounded(.down))
        highestDisplayedSteps = max(highestDisplayedSteps, healthTracker.openWalkTotals?.steps ?? 0, packetDisplay)
        var next = newStatus
        next.steps = highestDisplayedSteps
        setStatus(next)
        updateLiveStepTimer()
        if newStatus.phase != previousPhase {
            recordConnectionChange(newStatus)
            if newStatus.phase == .error {
                failedAttempts += 1
            } else if newStatus.phase == .ready, failedAttempts != 0 {
                failedAttempts = 0
            }
        }
        // Hold off idle sleep for exactly as long as the belt moves, so a long
        // walk cannot be cut short by the Mac dozing off.
        sleepBlocker.setActive(newStatus.beltRunning)
        if newStatus.phase == .disconnected || newStatus.phase == .error {
            healthTracker.markConnectionDrop()
            persistHealthTracker()
            scheduleReconnect(after: newStatus.phase == .error ? 10 : 1)
        }
        if newStatus.phase == .ready, newStatus.hasTelemetry {
            observeWalk()
        }
    }

    /// The one place a status frame lands: the logic copy, then the
    /// per-field live copy the views read.
    func setStatus(_ next: Z1Treadmill.Status) {
        guard next != status else { return }
        status = next
        live.apply(next)
    }

    func observeWalk() {
        let observation = healthTracker.observe(status)
        persistHealthTracker(throttled: true)
        logCompletedWalks(observation.completed)
        scheduleHealthFinalization(deadline: observation.finalizationDeadline)
        recomputeToday()
    }

    /// The step interpolation timer runs only while it could do anything:
    /// connected, streaming, belt moving. An idle app wakes for nothing.
    private func updateLiveStepTimer() {
        let needed = status.phase == .ready && status.hasTelemetry
            && (status.speedKmh > 0.3 || status.beltRunning)
        if needed, liveStepTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickLiveSteps() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            liveStepTimer = timer
        } else if !needed, let timer = liveStepTimer {
            timer.invalidate()
            liveStepTimer = nil
        }
    }

    /// The pad's counters arrive in visible chunks. Fill the quiet gaps with
    /// at most three modelled steps, then snap to the next real packet. The
    /// same value goes to the open-walk tracker so the live row and Today
    /// tick together.
    private func tickLiveSteps() {
        guard status.phase == .ready, status.hasTelemetry,
              status.speedKmh > 0.3 || status.beltRunning
        else { return }
        stepSmoother.interpolate(secondsSincePacket: Date().timeIntervalSince(lastStepPacketAt))
        let candidate = Int(stepSmoother.displaySteps.rounded(.down))
        highestDisplayedSteps = max(highestDisplayedSteps, candidate)
        guard highestDisplayedSteps != status.steps else { return }
        var next = status
        next.steps = highestDisplayedSteps
        setStatus(next)
        observeWalk()
    }

    private func scheduleHealthFinalization(deadline: Date? = nil) {
        healthFinalizeTask?.cancel()
        let target = deadline ?? healthTracker.finalizationDeadline
        if healthTracker.hasPendingLogs {
            healthFinalizeTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                self?.finalizeHealthIfDue()
            }
            return
        }
        guard let target else { return }
        let delay = max(0, target.timeIntervalSinceNow)
        healthFinalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.finalizeHealthIfDue()
        }
    }

    private func finalizeHealthIfDue() {
        let observation = healthTracker.finalizeIfDue()
        persistHealthTracker()
        logCompletedWalks(observation.completed)
        scheduleHealthFinalization(deadline: observation.finalizationDeadline)
        recomputeToday()
    }

    /// Saves the open walk so a crash or kill loses at most a few seconds of
    /// it. Mid-walk frames save every 10 s; drops, finished walks and quitting
    /// save at once.
    private func persistHealthTracker(throttled: Bool = false) {
        guard !Self.isPreview else { return }
        let now = Date()
        if throttled, now.timeIntervalSince(lastTrackerSave) < 10 { return }
        guard let data = try? JSONEncoder().encode(healthTracker) else { return }
        UserDefaults.standard.set(data, forKey: Self.healthTrackerKey)
        lastTrackerSave = now
    }

    private static func restoreHealthTracker(from defaults: UserDefaults) -> RemoteSessionTracker {
        guard !isPreview,
              let data = defaults.data(forKey: healthTrackerKey),
              let tracker = try? JSONDecoder().decode(RemoteSessionTracker.self, from: data)
        else { return RemoteSessionTracker() }
        return tracker
    }

    /// A short, durable trail of connection changes.
    ///
    /// The pad only streams telemetry while the belt moves, so an idle app that
    /// is connected and an app that never connected look alike from outside.
    /// This is the app saying which one it is.
    private func recordConnectionChange(_ newStatus: Z1Treadmill.Status) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var line = "\(stamp) \(String(describing: newStatus.phase))"
        if let name = newStatus.deviceName { line += " \(name)" }
        if let error = newStatus.errorMessage { line += " — \(error)" }
        var log = UserDefaults.standard.stringArray(forKey: Self.connectionLogKey) ?? []
        log.append(line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
        UserDefaults.standard.set(log, forKey: Self.connectionLogKey)
    }

    /// One build briefly registered a login item on the user's behalf. Reverse
    /// exactly that, once, and then never touch it again: start-at-login is
    /// the toggle in Settings and nothing else.
    private func undoAutomaticLoginItem() {
        let defaults = UserDefaults.standard
        defer { defaults.set(LoginItem.statusDescription, forKey: Self.loginStatusKey) }
        guard defaults.object(forKey: "launchAtLoginConfigured") != nil else { return }
        defaults.removeObject(forKey: "launchAtLoginConfigured")
        _ = LoginItem.set(false)
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - walk reminders

    private func checkWalkReminder(now: Date = Date()) {
        guard remindersEnabled, notificationsEnabled else { return }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        guard (9..<18).contains(hour), (2...6).contains(weekday) else { return }
        guard !status.beltRunning, healthTracker.openWalkTotals == nil else { return }

        let lastEnd = sessionStore.sessions.last?.endedAt ?? .distantPast
        let quietHours = now.timeIntervalSince(lastEnd) / 3600
        guard quietHours >= Double(max(1, reminderGapHours)) else { return }

        // At most two per day, and never two inside one gap window.
        var log = (UserDefaults.standard.array(forKey: Self.reminderLogKey) as? [Date]) ?? []
        let todays = log.filter { calendar.isDate($0, inSameDayAs: now) }
        guard todays.count < 2 else { return }
        if let last = todays.last, now.timeIntervalSince(last) / 3600 < Double(reminderGapHours) {
            return
        }

        let body: String
        if goalIsSteps {
            body = "Quiet for \(Int(quietHours))h. \(max(0, dailyGoalSteps - today.steps)) steps to go today."
        } else {
            let lines = [
                "The belt has been quiet for a while.",
                "A short walk would round the day off.",
                "Still \(max(0, dailyGoalMinutes - today.activeDurationS / 60)) min to today's goal.",
                "The pad is right there.",
            ]
            body = lines[Int(now.timeIntervalSince1970 / 60) % lines.count]
        }
        notifier.post(title: "Time for a walk?", body: body, identifier: "reminder-\(Int(now.timeIntervalSince1970))")
        log.append(now)
        if log.count > 20 { log.removeFirst(log.count - 20) }
        UserDefaults.standard.set(log, forKey: Self.reminderLogKey)
    }

    // MARK: - history

    /// Record every finished walk in local history.
    private func logCompletedWalks(_ walks: [CompletedWalk]) {
        guard !walks.isEmpty else { return }
        for walk in walks {
            // Stepping on the belt for a moment is not a walk. Drain the log
            // entry so it is not offered again, but keep it out of history.
            guard walk.activeDurationS >= 120 else {
                healthTracker.acknowledgeLog(sessionID: walk.id)
                continue
            }
            let kcal = Z1Metrics.kcalPerMinute(walk.avgSpeedKmh, weightKg: weightKg)
                * Double(walk.activeDurationS) / 60
            let session = WalkSession(
                id: walk.id,
                startedAt: walk.startedAt,
                endedAt: walk.endedAt,
                activeDurationS: walk.activeDurationS,
                distanceM: walk.distanceM,
                steps: walk.steps,
                caloriesKcal: (kcal * 10).rounded() / 10,
                exportedToHealth: false
            )
            let added = sessionStore.append(session)
            healthTracker.acknowledgeLog(sessionID: walk.id)
            guard added, notificationsEnabled else { continue }
            let minutes = max(1, walk.activeDurationS / 60)
            let body = "\(minutes) min · \(formatDistance(walk.distanceM)) · \(walk.steps) steps est."
            notifier.post(title: "Walk recorded", body: body, identifier: walk.id)
        }
        persistHealthTracker()
        refreshHistory()
    }

    func refreshHistoryFromDisk() {
        sessionStore.reload()
        refreshHistory()
    }

    /// What the store held, and on which day, at the last refresh. A change
    /// in either means everything computed from it must redraw.
    private struct HistorySignature: Equatable {
        var sessions: [WalkSession] = []
        var day = Date.distantPast
        var loaded = false
    }

    /// Runs on launch, after each recorded walk, and every two minutes (which
    /// is what rolls Today over at midnight). Each write is a redraw for
    /// whoever reads it, so only write what changed.
    func refreshHistory() {
        let calendar = Calendar.current
        let signature = HistorySignature(
            sessions: sessionStore.sessions,
            day: calendar.startOfDay(for: Date()),
            loaded: true
        )
        guard signature != historySignature else { return }
        historySignature = signature
        storedToday = sessionStore.totals()
        let recent = sessionStore.mostRecent(30)
        if recent != recentWalks { recentWalks = recent }
        let scores = sessionStore.highScores
        if scores != highScores { highScores = scores }
        let badges = sessionStore.achievements
        if badges != achievements { achievements = badges }
        historyRevision += 1
        recomputeToday()
    }

    // MARK: - today

    /// Rebuilds `today` and `todayCoarse` from the store plus the open walk,
    /// writing each only when it changed.
    func recomputeToday() {
        var next = storedToday
        let calendar = Calendar.current
        if !calendar.isDateInToday(next.day) {
            next = sessionStore.totals()
            storedToday = next
        }
        if let open = openWalk, !sessionStore.contains(id: open.id) {
            // A walk that resumes within the store's merge gap folds into the
            // last stored walk, so it is not a new walk in the count.
            let last = sessionStore.sessions.last { calendar.isDateInToday($0.startedAt) }
            let sameWalk = last.map {
                SessionStore.shouldMerge($0, WalkSession(
                    id: open.id,
                    startedAt: open.startedAt,
                    endedAt: open.endedAt.timeIntervalSince1970 > 0 ? open.endedAt : Date(),
                    activeDurationS: open.activeDurationS,
                    distanceM: open.distanceM,
                    steps: open.steps,
                    caloriesKcal: 0,
                    exportedToHealth: false
                ))
            } ?? false
            next.addOpenWalk(open, weightKg: weightKg)
            if !sameWalk { next.walks += 1 }
        }
        if next != today { today = next }
        let coarse = Self.coarse(next)
        if coarse != todayCoarse { todayCoarse = coarse }
    }

    /// Rounded to what a bar or a calendar cell can show.
    private static func coarse(_ totals: DayTotals) -> DayTotals {
        var c = DayTotals(day: totals.day)
        c.walks = totals.walks
        c.activeDurationS = totals.activeDurationS / 60 * 60
        c.distanceM = totals.distanceM / 50 * 50
        c.steps = totals.steps / 50 * 50
        c.caloriesKcal = (totals.caloriesKcal / 5).rounded(.down) * 5
        return c
    }

    // MARK: - power management

    private func installPowerObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Waking is the best moment to retry: the pad is usually right
            // there and the backoff would otherwise idle for 30 s.
            Task { @MainActor in self?.scheduleReconnect(after: 1, force: true) }
        }
    }

    private func startHousekeeping() {
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.refreshHistory()
            }
        }
    }

    // Connecting only scans, unlocks telemetry and reads settings; it never
    // starts or changes belt motion. Unexpected drops retry in the background.
    private func scheduleReconnect(after delay: TimeInterval, force: Bool = false) {
        guard automaticConnectionEnabled else { return }
        if reconnectTask != nil {
            guard force else { return }
            reconnectTask?.cancel()
        }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.reconnectGeneration == generation { self.reconnectTask = nil } }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            // Backoff, not a fixed poll: retry hard right after a drop, then
            // ease off so a pad switched off for the day costs nothing.
            var attempt = 0
            while !Task.isCancelled, self.automaticConnectionEnabled {
                if self.status.phase == .ready { return }
                if !self.busy,
                   self.status.phase == .disconnected || self.status.phase == .error
                {
                    try? await self.treadmill.connect()
                    if self.status.phase == .ready { return }
                }
                attempt += 1
                let backoff = min(30, pow(2, Double(min(attempt, 5))))
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }
}
