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
    private enum FailedCommand { case connection, start, stop, speed(Double) }
    @ObservationIgnored private var failedCommand: FailedCommand?
    @ObservationIgnored private var historyRetryAt: Date?
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
    /// Today, history plus the walk in progress. Changes with every frame
    /// while the belt moves; the Today card reads it.
    private(set) var today = DayTotals(day: Date())
    /// Today again, rounded to what a bar can show (whole minutes, 50 m).
    /// The week bars read this, so they redraw a few times a walk instead of
    /// every second.
    private(set) var todayCoarse = DayTotals(day: Date())
    /// Today at the resolution the Today card prints (whole minutes, 10 m), so
    /// the card redraws when its text can change, not on every telemetry frame.
    private(set) var todayShown = DayTotals(day: Date())
    /// Why start-at-login did not take, if it did not.
    private(set) var loginItemMessage: String?

    // MARK: persisted settings (UserDefaults, the same store @AppStorage uses)

    /// Body weight in kg, for the calorie figures in history and `live.json`.
    /// Not shown: it follows the latest weight the iPhone Shortcut saved
    /// (`HealthWeight`), else the stored or default value.
    var weightKg: Double {
        didSet {
            settingsDefaults.set(weightKg, forKey: Self.weightKey)
            if canCommand { Task { await treadmill.setWeight(weightKg) } }
            recomputeToday()
        }
    }

    /// Display units: true = Imperial (mph/mi/lb). Also syncs the pad's own
    /// display (best-effort).
    var unitsImperial: Bool {
        didSet {
            settingsDefaults.set(unitsImperial, forKey: Self.unitsKey)
            if canCommand { Task { try? await treadmill.setDisplayUnits(imperial: unitsImperial) } }
        }
    }

    /// Daily walking target in minutes (0 = no goal).
    var dailyGoalMinutes: Int {
        didSet {
            settingsDefaults.set(dailyGoalMinutes, forKey: Self.goalKey)
            publishLive()
        }
    }

    /// Quiet-day nudges, capped by `WalkReminderPolicy`.
    var remindersEnabled: Bool {
        didSet {
            settingsDefaults.set(remindersEnabled, forKey: Self.remindersKey)
            guard !Self.isPreview else { return }
            if remindersEnabled { notifier.requestAuthorizationIfNeeded() }
            armReminderTimer()
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard !Self.isPreview, launchAtLogin != LoginItem.isEnabled else { return }
            loginItemMessage = LoginItem.set(launchAtLogin)
            if loginItemMessage != nil { launchAtLogin = LoginItem.isEnabled }
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
    /// Armed only while reminders are on, for the next moment one could be due.
    @ObservationIgnored private var reminderTimer: Timer?
    @ObservationIgnored private var stepCounter = StepCounter()
    @ObservationIgnored var healthTracker: RemoteSessionTracker
    @ObservationIgnored let sessionStore: SessionStore
    /// `live.json` for Superapp. Nil in the harness, which must never write
    /// real files.
    @ObservationIgnored private let liveExport: LiveExport?
    @ObservationIgnored private let sleepBlocker = SleepBlocker()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let hotKey = GlobalHotKey()
    /// Guards against an old reconnect task clearing a newer one's handle.
    @ObservationIgnored private var reconnectGeneration = 0
    /// Coalesced speed target for rapid − / + taps, so `busy` drops none.
    /// Observed: until telemetry reaches it, it is what the readout shows, so
    /// a tap reads at once instead of after the belt has ramped.
    private var coalescedTargetKmh: Double?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedCommandInFlight = false
    @ObservationIgnored private var speedGeneration = 0
    @ObservationIgnored private var controlIntentGeneration = 0
    @ObservationIgnored private var activeOperations = 0
    /// Today from the store alone, without the open walk.
    @ObservationIgnored var storedToday = DayTotals(day: Date())
    @ObservationIgnored private var historySignature = HistorySignature()
    @ObservationIgnored private var lastTrackerSave = Date.distantPast

    static let weightKey = "weightKg"
    static let unitsKey = "unitsImperial"
    static let goalKey = "dailyGoalMinutes"
    static let remindersKey = "remindersEnabled"
    static let reminderLogKey = "z1.reminderLog"
    static let connectionLogKey = "z1.connectionLog"
    /// The open walk. The key predates the tracker's current name; renaming it
    /// would orphan a walk saved by an earlier build.
    static let healthTrackerKey = "z1.automaticHealthSession"

    private var settingsDefaults: UserDefaults { Self.settingsStore }
    static let settingsStore: UserDefaults = {
        guard isPreview else { return .standard }
        // A preview can be clicked freely without altering the installed app.
        return UserDefaults(suiteName: "dev.z1walkingpad.preview.\(ProcessInfo.processInfo.processIdentifier)")!
    }()

    init() {
        let defaults = Self.settingsStore
        let storedWeight = defaults.double(forKey: Self.weightKey)
        weightKg = storedWeight > 0 ? storedWeight : Z1Metrics.defaultWeightKg
        // The Z1 protocol and display are metric, so default to km/h.
        unitsImperial = defaults.object(forKey: Self.unitsKey) as? Bool ?? false
        dailyGoalMinutes = defaults.object(forKey: Self.goalKey) as? Int ?? 120
        remindersEnabled = defaults.object(forKey: Self.remindersKey) as? Bool ?? true
        launchAtLogin = LoginItem.isEnabled
        healthTracker = Self.restoreHealthTracker(from: defaults)
        sessionStore = Self.isPreview ? PreviewHarness.sessionStore() : SessionStore(openWalkStartedAt: healthTracker.openWalkTotals?.startedAt, hasPendingHistoryLogs: healthTracker.hasPendingLogs)
        liveExport = Self.isPreview ? nil : LiveExport()

        if Self.isPreview {
            refreshHistory()
            PreviewHarness.start(self)
            return
        }

        Task { await treadmill.setWeight(weightKg) }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await s in self.treadmill.statusUpdates {
                guard !Task.isCancelled else { break }
                self.receiveStatus(s)
            }
        }
        scheduleHealthFinalization()
        scheduleReconnect(after: 0.5)
        // The pad accepts one central at a time, so a link left up at exit is
        // what makes the next launch fail to connect. Drop it on the way out.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [treadmill] _ in
            treadmill.cancelConnectionNow()
        }
        refreshHistory()
        installSystemObservers()
        applyGlobalShortcut()
        if remindersEnabled { notifier.requestAuthorizationIfNeeded() }
        // First reminder check only after a settling period: being reminded
        // to walk thirty seconds after logging in is how reminders get turned off.
        armReminderTimer()
        applyHealthWeightIfAvailable()
    }

    // No deinit: this model lives as long as the process.

    /// Body weight changes a few times a week at most, so it is read when it
    /// can matter (launch, wake, the window coming forward, a walk ending),
    /// never on a timer.
    private func applyHealthWeightIfAvailable() {
        guard !Self.isPreview, let sample = HealthWeight.load() else { return }
        let rounded = (sample.kg * 10).rounded() / 10
        if abs(weightKg - rounded) >= 0.05 {
            weightKg = rounded
        }
    }

    var isConnected: Bool { live.isConnected }
    var isConnecting: Bool { live.isConnecting }

    // MARK: - display-unit helpers

    var speedUnitLabel: String { unitsImperial ? "mph" : "km/h" }

    /// Current belt speed in the display unit.
    var displaySpeed: Double {
        unitsImperial ? Z1Units.kmhToMph(live.speedKmh) : live.speedKmh
    }

    func formatDistance(_ meters: Int) -> String {
        if unitsImperial {
            let miles = Z1Units.metersToMiles(Double(meters))
            return miles < 0.1
                ? "\(Int(Z1Units.metersToFeet(Double(meters)).rounded())) ft"
                : "\(Self.decimal(miles, digits: 2)) mi"
        }
        // Always km in metric. Switching units at 1000 m made the number jump
        // between "940 m" and "1.02 km" mid-walk, which reads as a reset.
        return "\(Self.decimal(Double(meters) / 1000, digits: 2)) km"
    }

    /// A speed in the display unit, one decimal, in the user's number format
    /// (so "3,4" next to "3.120 steps" in a Dutch region, never a mix).
    func formatSpeed(_ value: Double) -> String {
        Self.decimal(value, digits: 1)
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
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

    // MARK: - actions

    /// The harness has no pad: actions are inert there, and touching
    /// `treadmill` would create a Bluetooth central.
    private var canCommand: Bool { !Self.isPreview }

    func connectTapped() {
        guard canCommand, !busy else { return }
        run(retry: .connection) {
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
        guard canCommand, isConnected else { return }
        // Latch the intent at tap. Re-reading beltRunning inside `run` races
        // telemetry: a leftover speed from the last walk made Start send Stop.
        let stopping = status.beltRunning || status.stopRequested || pendingVerb == "Starting…"
        guard stopping ? pendingVerb != "Stopping…" : !busy else { return }
        controlIntentGeneration += 1
        let intent = controlIntentGeneration
        cancelSpeedCommands()
        pendingVerb = stopping ? "Stopping…" : "Starting…"
        run(retry: stopping ? .stop : .start) {
            defer { if self.controlIntentGeneration == intent { self.pendingVerb = nil } }
            guard self.controlIntentGeneration == intent else { throw CancellationError() }
            if stopping {
                _ = try await self.treadmill.stop()
            } else {
                try await self.treadmill.start()
                guard self.controlIntentGeneration == intent else { throw CancellationError() }
                // A speed picked at a standstill is applied as soon as the belt
                // moves: the pad always starts at its minimum.
                if let pending = self.pendingTargetKmh {
                    self.pendingTargetKmh = nil
                    // Held as the target so the readout stays on the queued
                    // speed while the belt ramps up to it.
                    self.coalescedTargetKmh = pending
                    do {
                        try await self.treadmill.setSpeed(pending)
                    } catch {
                        self.coalescedTargetKmh = nil
                        throw error
                    }
                }
            }
        }
    }

    /// Jump straight to a speed, in the current display unit.
    ///
    /// The pad only accepts speed changes while the belt moves, so a value
    /// picked at a standstill is remembered and applied right after Start.
    func setSpeed(_ displayValue: Double) {
        guard canCommand, isConnected, !busy, displayValue.isFinite else { return }
        let kmh = unitsImperial ? Z1Units.mphToKmh(displayValue) : displayValue
        let clamped = (min(max(kmh, status.minSpeedKmh), status.maxSpeedKmh) * 10).rounded() / 10
        guard status.beltRunning else {
            if pendingTargetKmh != clamped { pendingTargetKmh = clamped }
            return
        }
        scheduleSpeedTarget(clamped)
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

    /// − / +: exactly 0.1 of the display unit per tap (0.1 mph or 0.1 km/h).
    func speedUpTapped() { nudge(byDisplay: 0.1) }
    func speedDownTapped() { nudge(byDisplay: -0.1) }

    /// ↑ / ↓: half a unit at a time.
    func bigSpeedUpTapped() { nudge(byDisplay: 0.5) }
    func bigSpeedDownTapped() { nudge(byDisplay: -0.5) }

    /// The pad speed `delta` display units away from `kmh`.
    ///
    /// The step is taken in the display unit, from the tenth the readout
    /// shows, and only the result is converted and snapped to the pad's
    /// 0.1 km/h grid. A fixed km/h step cannot do this in mph: 0.1 mph is
    /// 0.161 km/h, which rounds to 0.2 and skips every other reading. The
    /// grid is finer than 0.1 mph (0.062), so each tap lands on the next
    /// tenth, and the belt is never more than 0.03 mph from the number shown.
    private func steppedKmh(from kmh: Double, byDisplay delta: Double) -> Double {
        let shown = unitsImperial ? Z1Units.kmhToMph(kmh) : kmh
        let target = (shown * 10).rounded() / 10 + delta
        let targetKmh = unitsImperial ? Z1Units.mphToKmh(target) : target
        let clamped = min(max(targetKmh, status.minSpeedKmh), status.maxSpeedKmh)
        return (clamped * 10).rounded() / 10
    }

    /// While walking a nudge goes to the pad; at a standstill it moves the
    /// speed the next Start will use, so the speed can be set before walking.
    private func nudge(byDisplay delta: Double) {
        guard canCommand, isConnected, !busy, delta.isFinite else { return }
        if status.beltRunning {
            enqueueSpeedChange(deltaDisplay: delta)
            return
        }
        let next = steppedKmh(from: pendingTargetKmh ?? status.minSpeedKmh, byDisplay: delta)
        if pendingTargetKmh != next { pendingTargetKmh = next }
    }

    /// Harness only: a speed queued for Start, to show the standstill flow.
    func previewQueueSpeed(_ kmh: Double) {
        guard Self.isPreview else { return }
        pendingTargetKmh = kmh
    }

    /// The speed the controls point at: while the belt moves, the one last
    /// asked for until the belt reaches it, else the belt's own; at a
    /// standstill, the one queued for Start.
    var targetDisplaySpeed: Double? {
        guard live.beltRunning else { return pendingTargetDisplaySpeed }
        guard let requested = coalescedTargetKmh else { return displaySpeed }
        return unitsImperial ? Z1Units.kmhToMph(requested) : requested
    }

    /// Keep the latest requested target until the pad confirms it. Telemetry
    /// may lag a successful command, so it must not reset the next tap's base.
    private func enqueueSpeedChange(deltaDisplay: Double) {
        let base = coalescedTargetKmh ?? status.speedKmh
        scheduleSpeedTarget(steppedKmh(from: base, byDisplay: deltaDisplay))
    }

    private func scheduleSpeedTarget(_ target: Double) {
        guard target.isFinite else { return }
        coalescedTargetKmh = target
        if speedCommandInFlight { return }
        speedTask?.cancel()
        speedGeneration += 1
        let generation = speedGeneration
        speedTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.speedGeneration == generation {
                    self.speedTask = nil
                    self.speedCommandInFlight = false
                }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
                guard self.speedGeneration == generation, !self.busy,
                      self.isConnected, self.status.beltRunning,
                      let next = self.coalescedTargetKmh else { return }
                self.speedCommandInFlight = true
                do {
                    try await self.treadmill.setSpeed(next)
                    guard !Task.isCancelled, self.speedGeneration == generation else { return }
                    self.clearCommandError()
                    self.speedCommandInFlight = false
                    if self.coalescedTargetKmh == next { return }
                } catch {
                    guard !Task.isCancelled, self.speedGeneration == generation else { return }
                    self.commandError = error.localizedDescription
                    self.failedCommand = .speed(next)
                    self.coalescedTargetKmh = nil
                    return
                }
            }
        }
    }

    private func cancelSpeedCommands() {
        speedGeneration += 1
        speedTask?.cancel()
        speedTask = nil
        speedCommandInFlight = false
        // Runs on every idle frame; an observed write notifies even when equal.
        if coalescedTargetKmh != nil { coalescedTargetKmh = nil }
    }

    // MARK: - quitting

    enum QuitMode {
        /// Leave the belt exactly as it is; only free the pad's BLE slot.
        case leaveBelt
        /// Stop the belt and put the pad to sleep first.
        case stopBelt
    }

    /// Set by Walk ▸ Stop Pad and Quit, so the terminate check does not ask
    /// a question the user just answered.
    @ObservationIgnored private(set) var requestedQuit: QuitMode?

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
        cancelSpeedCommands()
        sleepBlocker.setActive(false)
        hotKey.unregister()
        persistHealthTracker()
        guard !Self.isPreview else { return }
        // Readers of live.json must not see a walk that nobody is recording.
        var gone = status
        gone.phase = .disconnected
        gone.beltRunning = false
        publishLive(gone)
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

    private func run(retry: FailedCommand, _ op: @MainActor @escaping () async throws -> Void) {
        activeOperations += 1
        busy = true
        Task {
            defer {
                activeOperations -= 1
                busy = activeOperations > 0
            }
            do {
                try await op()
                clearCommandError()
            } catch {
                // Surface command failures on screen: a silent retry loop is
                // how "I hit Start and nothing happens" happens.
                guard !(error is CancellationError) else { return }
                commandError = error.localizedDescription
                failedCommand = retry
                NSLog("Z1App: \(error.localizedDescription)")
            }
        }
    }

    private func clearCommandError() {
        if commandError != nil { commandError = nil }
        failedCommand = nil
    }

    func retryFailedCommand() {
        if Self.isPreview {
            // A UI fixture only: dismiss the simulated failure without BLE.
            clearCommandError()
            return
        }
        guard let failedCommand else { return }
        switch failedCommand {
        case .connection: if !isConnected { connectTapped() } else { clearCommandError() }
        case .start: if !status.beltRunning { startStopTapped() } else { clearCommandError() }
        case .stop: if status.beltRunning { startStopTapped() } else { clearCommandError() }
        case .speed(let kmh):
            guard isConnected, status.beltRunning, !busy else { return }
            scheduleSpeedTarget(kmh)
        }
    }

    func previewSetCommandError(_ message: String) {
        guard Self.isPreview else { return }
        commandError = message
    }

    // MARK: - global shortcut

    /// ⌃⌥W, always on: starts or stops the belt, or looks for the pad when
    /// there is none. Silent either way; the app makes no sounds.
    private func applyGlobalShortcut() {
        guard !Self.isPreview else { return }
        hotKey.register { [weak self] in
            guard let self else { return }
            if self.isConnected {
                self.startStopTapped()
            } else if !self.isConnecting {
                self.connectTapped()
            }
        }
    }

    // MARK: - telemetry

    private func receiveStatus(_ newStatus: Z1Treadmill.Status) {
        let previousPhase = status.phase
        if newStatus.phase != .ready || !newStatus.beltRunning {
            cancelSpeedCommands()
        } else if !speedCommandInFlight, speedTask == nil,
                  let target = coalescedTargetKmh, abs(newStatus.speedKmh - target) < 0.05 {
            coalescedTargetKmh = nil
        }
        if newStatus.phase == .ready, newStatus.hasTelemetry,
           newStatus.distanceM < status.distanceM || newStatus.elapsedS < status.elapsedS {
            stepCounter.reset()
        }
        // The driver models the whole run at the current speed, which would
        // rewrite steps already taken whenever the speed changes. The counter
        // keeps them and adds only new metres; the driver's figure seeds it.
        stepCounter.strideM = newStatus.impliedStrideM
            ?? GaitModel.stepLengthM(speedKmh: max(0.8, newStatus.speedKmh))
        stepCounter.ingest(reportedSteps: newStatus.steps, distanceM: newStatus.distanceM)
        var next = newStatus
        next.steps = Int(stepCounter.steps.rounded(.down))
        setStatus(next)
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
            // A run cut off by the drop gets its own short deadline; without
            // this it would wait for the next frame or launch to be recorded.
            scheduleHealthFinalization(deadline: healthTracker.finalizationDeadline)
            scheduleReconnect(after: newStatus.phase == .error ? 10 : 1)
        }
        if newStatus.phase == .ready, newStatus.hasTelemetry {
            observeWalk()
        } else {
            publishLive()
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
        sessionStore.setOpenWalkStartedAt(healthTracker.openWalkTotals?.startedAt)
        sessionStore.setPendingHistoryLogs(healthTracker.hasPendingLogs)
        persistHealthTracker(throttled: true)
        logCompletedWalks(observation.completed)
        scheduleHealthFinalization(deadline: observation.finalizationDeadline)
        recomputeToday()
    }

    /// Hands Superapp (and anything else reading `live.json`) the current
    /// frame and today's totals. The writer caps itself at 1 Hz and writes a
    /// disconnect at once.
    private func publishLive(_ frame: Z1Treadmill.Status? = nil) {
        guard let liveExport else { return }
        do {
            try liveExport.publish(status: frame ?? status, today: today, goalProgress: goalProgress(for: today))
        } catch {
            NSLog("Z1App: live.json not written: \(error.localizedDescription)")
        }
    }

    private func scheduleHealthFinalization(deadline: Date? = nil) {
        healthFinalizeTask?.cancel()
        let target = deadline ?? healthTracker.finalizationDeadline
        if healthTracker.hasPendingLogs {
            let delay = max(0, historyRetryAt?.timeIntervalSinceNow ?? 0)
            healthFinalizeTask = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
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
        sessionStore.setOpenWalkStartedAt(healthTracker.openWalkTotals?.startedAt)
        sessionStore.setPendingHistoryLogs(healthTracker.hasPendingLogs)
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
        settingsDefaults.set(data, forKey: Self.healthTrackerKey)
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
        var log = settingsDefaults.stringArray(forKey: Self.connectionLogKey) ?? []
        log.append(line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
        settingsDefaults.set(log, forKey: Self.connectionLogKey)
    }

    // MARK: - walk reminders

    /// One timer, armed for the next moment a reminder could be due
    /// (`WalkReminderPolicy.nextCheck`) and only while reminders are on, so an
    /// idle app sleeps for hours between looks and wakes for nothing else.
    private func armReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard remindersEnabled, !Self.isPreview else { return }
        let when = WalkReminderPolicy.nextCheck(
            after: Date(), lastWalkEnd: sessionStore.sessions.last?.endedAt, reminders: reminderLog
        )
        let timer = Timer(fire: when, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkWalkReminder() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    private var reminderLog: [Date] {
        settingsDefaults.array(forKey: Self.reminderLogKey) as? [Date] ?? []
    }

    private func checkWalkReminder(now: Date = Date()) {
        defer { armReminderTimer() }
        guard remindersEnabled, !status.beltRunning, healthTracker.openWalkTotals == nil else { return }
        var log = reminderLog
        guard WalkReminderPolicy.isDue(
            now: now, lastWalkEnd: sessionStore.sessions.last?.endedAt, reminders: log
        ) else { return }

        let lines = [
            "The belt has been quiet for a while.",
            "A short walk would round the day off.",
            "Still \(max(0, dailyGoalMinutes - today.activeDurationS / 60)) min to today's goal.",
            "The pad is right there.",
        ]
        let body = lines[Int(now.timeIntervalSince1970 / 60) % lines.count]
        notifier.post(title: "Time for a walk?", body: body, identifier: "reminder-\(Int(now.timeIntervalSince1970))")
        log.append(now)
        if log.count > 20 { log.removeFirst(log.count - 20) }
        settingsDefaults.set(log, forKey: Self.reminderLogKey)
    }

    // MARK: - history

    /// Record every finished walk in local history.
    private func logCompletedWalks(_ walks: [CompletedWalk]) {
        guard !walks.isEmpty else { return }
        applyHealthWeightIfAvailable()
        if let historyRetryAt, historyRetryAt > Date() {
            // A second walk may finish during backoff. Publish its pending
            // display state without attempting an early disk retry.
            refreshHistory()
            return
        }
        historyRetryAt = nil
        for walk in walks {
            // A failed save stays in the tracker's log and is retried.
            if !sessionStore.record(walk, weightKg: weightKg, tracker: &healthTracker) {
                historyRetryAt = Date().addingTimeInterval(30)
            }
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
        var pendingWalks: [CompletedWalk] = []
        var day = Date.distantPast
        var loaded = false
    }

    /// Runs on launch, after each recorded walk, on wake and at midnight, and
    /// every two minutes while connected or a walk is open. Each write is a
    /// redraw for whoever reads it, so only write what changed.
    func refreshHistory() {
        let calendar = Calendar.current
        let signature = HistorySignature(
            sessions: sessionStore.sessions,
            pendingWalks: healthTracker.pendingCompletedWalks,
            day: calendar.startOfDay(for: Date()),
            loaded: true
        )
        guard signature != historySignature else { return }
        historySignature = signature
        storedToday = sessionStore.totals()
        historyRevision += 1
        recomputeToday()
    }

    // MARK: - today

    /// Rebuilds `today` and `todayCoarse` from saved, pending and open walks,
    /// writing each only when it changed.
    func recomputeToday() {
        var next = storedToday
        let calendar = Calendar.current
        if !calendar.isDateInToday(next.day) {
            next = sessionStore.totals()
            storedToday = next
        }
        next = displayTotals(addingTo: next)
        if next != today { today = next }
        let coarse = Self.coarse(next)
        if coarse != todayCoarse { todayCoarse = coarse }
        var shown = DayTotals(day: next.day)
        shown.walks = next.walks
        shown.activeDurationS = next.activeDurationS / 60 * 60
        shown.distanceM = next.distanceM / 10 * 10
        if shown != todayShown { todayShown = shown }
        publishLive()
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

    // MARK: - system events

    /// Everything that changes with the clock or the machine arrives as a
    /// notification, so an idle app has nothing to poll.
    private func installSystemObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Waking is the best moment to retry: the pad is usually right
            // there and the backoff would otherwise idle for 30 s.
            Task { @MainActor in
                self?.refreshHistory()
                self?.applyHealthWeightIfAvailable()
                self?.armReminderTimer()
                self?.scheduleReconnect(after: 1, force: true)
            }
        }
        // Rolls Today over at midnight.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHistory() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyHealthWeightIfAvailable() }
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
