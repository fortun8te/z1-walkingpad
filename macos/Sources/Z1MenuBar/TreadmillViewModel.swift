import AppKit
import Combine
import Foundation
import SwiftUI
import Z1Core

/// ObservableObject bridge between the `Z1Treadmill` actor and SwiftUI.
///
/// All BLE-facing values stay metric (km/h, meters, kg — the wire protocol
/// requires it); conversion to the user's display units happens here.
@MainActor
final class TreadmillViewModel: ObservableObject {
    @Published private(set) var status = Z1Treadmill.Status()
    @Published private(set) var busy = false
    @Published private(set) var lastSummary: SessionSummary?
    /// Last failed command, shown until the next success. Kept separate
    /// from `status` because the status stream replaces it every second.
    @Published private(set) var commandError: String?

    /// How many scan/connect attempts have failed in a row. A single failure
    /// is normal (the pad sleeps); a run of them means it is not there at all,
    /// and the app should say so rather than showing "scanning" forever.
    @Published private(set) var failedAttempts = 0

    /// Walk history, aggregated for the popover.
    @Published private(set) var todayTotals = DayTotals(day: Date())
    @Published private(set) var recentWalks: [WalkSession] = []
    @Published private(set) var weekDays: [DayTotals] = []
    @Published private(set) var monthDays: [DayTotals] = []
    @Published private(set) var highScores = HighScores()
    @Published private(set) var achievements: [Achievement] = []
    /// Why start-at-login did not take, if it did not.
    @Published private(set) var loginItemMessage: String?

    let updater = AppUpdater()
    var updatePhase: UpdatePhase { updater.phase }
    private var updaterBag = Set<AnyCancellable>()

    // MARK: - persisted settings (UserDefaults — the same store @AppStorage uses)

    /// Body weight, always stored in kg (canonical); displayed/edited in the
    /// current unit via `weightBinding`. Fed to the calorie math in kg.
    @Published var weightKg: Double {
        didSet {
            UserDefaults.standard.set(weightKg, forKey: Self.weightKey)
            Task { await treadmill.setWeight(weightKg) }
        }
    }

    /// Display units: true = Imperial (mph/mi/lb), false = Metric. Changing it
    /// also syncs the pad's own LED display (best-effort).
    @Published var unitsImperial: Bool {
        didSet {
            UserDefaults.standard.set(unitsImperial, forKey: Self.unitsKey)
            Task { try? await treadmill.setDisplayUnits(imperial: unitsImperial) }
        }
    }

    /// +/- stepper nudge size, in the CURRENT display unit (mph or km/h).
    @Published var speedStep: Double {
        didSet {
            UserDefaults.standard.set(speedStep, forKey: Self.stepKey)
        }
    }

    /// Hand stride in metres. 0 = pad session count. Not used unless set.
    @Published var strideOverrideM: Double {
        didSet {
            UserDefaults.standard.set(strideOverrideM, forKey: Self.strideKey)
            Task { await treadmill.setStrideOverride(strideOverrideM > 0 ? strideOverrideM : nil) }
        }
    }

    /// Accumulate stats across sessions (ignore the pad's counter resets)
    /// until manually cleared. Off = pad-as-master.
    @Published var persistStats: Bool {
        didSet {
            UserDefaults.standard.set(persistStats, forKey: Self.persistKey)
            Task { await treadmill.setPersistStats(persistStats) }
        }
    }

    /// What rides in the menu bar beside the icon.
    @Published var menuBarReadout: MenuBarReadout {
        didSet { UserDefaults.standard.set(menuBarReadout.rawValue, forKey: Self.readoutKey) }
    }

    /// Show the readout even when the belt is stopped.
    @Published var menuBarAlwaysVisible: Bool {
        didSet { UserDefaults.standard.set(menuBarAlwaysVisible, forKey: Self.alwaysVisibleKey) }
    }

    /// Daily walking target in minutes (0 = no goal).
    @Published var dailyGoalMinutes: Int {
        didSet { UserDefaults.standard.set(dailyGoalMinutes, forKey: Self.goalKey) }
    }

    /// Quiet-day nudges. Strictly capped: work hours, weekdays, at most two
    /// a day — a window does not nag.
    @Published var remindersEnabled: Bool {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: Self.remindersKey) }
    }

    @Published var reminderGapHours: Int {
        didSet { UserDefaults.standard.set(reminderGapHours, forKey: Self.reminderGapKey) }
    }

    /// Measure the day in steps instead of minutes.
    @Published var goalIsSteps: Bool {
        didSet { UserDefaults.standard.set(goalIsSteps, forKey: Self.goalKindKey) }
    }

    /// Step goal; 8,000 is where the mortality-risk curve plateaus for
    /// under-60s in the step-count meta-analyses.
    @Published var dailyGoalSteps: Int {
        didSet { UserDefaults.standard.set(dailyGoalSteps, forKey: Self.goalStepsKey) }
    }

    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsKey)
            if notificationsEnabled { notifier.requestAuthorizationIfNeeded() }
        }
    }

    /// Show a Dock icon as well as the menu-bar item.
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: Self.dockKey)
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            loginItemMessage = LoginItem.set(launchAtLogin)
            if loginItemMessage != nil { launchAtLogin = LoginItem.isEnabled }
        }
    }

    /// When on, a newer feed build downloads and relaunches without a click.
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: Self.autoUpdateKey) }
    }

    let treadmill = Z1Treadmill()
    private var pumpTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var automaticConnectionEnabled = true
    private var healthFinalizeTask: Task<Void, Never>?
    private var reminderTimer: Timer?
    private var healthTracker: RemoteSessionTracker
    private let sessionStore = SessionStore()
    private let sleepBlocker = SleepBlocker()
    private let notifier = Notifier()
    private var housekeepingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Guards against an old reconnect task clearing a newer one's handle.
    private var reconnectGeneration = 0
    /// Speed picked while the belt was stopped; applied on the next Start.
    private var pendingTargetKmh: Double?
    /// Coalesced speed target for rapid +/- taps — avoids busy dropping taps.
    private var coalescedTargetKmh: Double?
    private var speedTask: Task<Void, Never>?
    @Published private(set) var speedBusy = false

    static let weightKey = "weightKg"
    static let unitsKey = "unitsImperial"
    static let stepKey = "speedStep"
    static let persistKey = "persistStats"
    static let readoutKey = "menuBarReadout"
    static let alwaysVisibleKey = "menuBarAlwaysVisible"
    static let goalKey = "dailyGoalMinutes"
    static let goalKindKey = "goalIsSteps"
    static let remindersKey = "remindersEnabled"
    static let reminderGapKey = "reminderGapHours"
    static let reminderLogKey = "z1.reminderLog"
    static let goalStepsKey = "dailyGoalSteps"
    static let notificationsKey = "notificationsEnabled"
    static let strideKey = "strideOverrideM"
    static let dockKey = "showInDock"
    static let autoUpdateKey = "z1.autoUpdate"
    static let loginStatusKey = "loginItemStatus"
    static let connectionLogKey = "z1.connectionLog"
    static let healthTrackerKey = "z1.automaticHealthSession"

    init() {
        let defaults = UserDefaults.standard
        let storedWeight = defaults.double(forKey: Self.weightKey)
        weightKg = storedWeight > 0 ? storedWeight : Z1Metrics.defaultWeightKg
        // The Z1 protocol and display are metric, so default to km/h. Respect
        // an existing user's explicit choice.
        unitsImperial = defaults.object(forKey: Self.unitsKey) as? Bool ?? false
        let storedStep = defaults.double(forKey: Self.stepKey)
        speedStep = storedStep > 0 ? storedStep : 0.1
        persistStats = defaults.bool(forKey: Self.persistKey)
        strideOverrideM = defaults.double(forKey: Self.strideKey)
        menuBarReadout = MenuBarReadout(rawValue: defaults.string(forKey: Self.readoutKey) ?? "")
            ?? .speed
        menuBarAlwaysVisible = defaults.bool(forKey: Self.alwaysVisibleKey)
        dailyGoalMinutes = defaults.object(forKey: Self.goalKey) as? Int ?? 120
        goalIsSteps = defaults.bool(forKey: Self.goalKindKey)
        remindersEnabled = defaults.object(forKey: Self.remindersKey) as? Bool ?? true
        reminderGapHours = defaults.object(forKey: Self.reminderGapKey) as? Int ?? 3
        dailyGoalSteps = defaults.object(forKey: Self.goalStepsKey) as? Int ?? 8_000
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        launchAtLogin = LoginItem.isEnabled
        showInDock = defaults.object(forKey: Self.dockKey) as? Bool ?? true
        autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        healthTracker = Self.restoreHealthTracker(from: defaults)
        updater.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &updaterBag)

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
        // First check only after a settling period — being reminded to walk
        // thirty seconds after logging in is how reminders get turned off.
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWalkReminder() }
        }
        // The pad accepts one central at a time, so a link left up at exit is
        // what makes the *next* launch fail to connect. Drop it on the way out.
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
        if notificationsEnabled { notifier.requestAuthorizationIfNeeded() }
        Task { await checkForUpdateAndMaybeInstall() }
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdateAndMaybeInstall() }
        }
    }

    // No deinit: this view model is the app's single long-lived @StateObject
    // and outlives every other object, so the wake observer and housekeeping
    // task are torn down by process exit.

    var isConnected: Bool { status.phase == .ready }
    var isConnecting: Bool { status.phase == .scanning || status.phase == .connecting }

    // MARK: - display-unit helpers

    var speedUnitLabel: String { unitsImperial ? "mph" : "km/h" }
    var weightUnitLabel: String { unitsImperial ? "lb" : "kg" }

    /// Current belt speed in the display unit (for the readout + menu bar).
    var displaySpeed: Double {
        unitsImperial ? Z1Units.kmhToMph(status.speedKmh) : status.speedKmh
    }

    /// Weight field binding: shows/edits in the current unit, stores kg.
    var weightBinding: Binding<Double> {
        Binding(
            get: { self.unitsImperial ? Z1Units.kgToLb(self.weightKg) : self.weightKg },
            set: { self.weightKg = self.unitsImperial ? Z1Units.lbToKg($0) : $0 }
        )
    }

    /// Speed-step nudge expressed in km/h for the wire protocol — snapped to 0.1 kmh grid.
    private var speedStepKmh: Double {
        let raw = unitsImperial ? Z1Units.mphToKmh(speedStep) : speedStep
        // snap to 0.1 kmh pad grid but keep at least one pad step
        let snapped = (raw * 10).rounded() / 10
        return max(0.1, snapped)
    }

    func formatDistance(_ meters: Int) -> String {
        if unitsImperial {
            let miles = Z1Units.metersToMiles(Double(meters))
            return miles < 0.1
                ? "\(Int(Z1Units.metersToFeet(Double(meters)).rounded())) ft"
                : String(format: "%.2f mi", miles)
        }
        // Always km in metric. Switching units at 1000 m made the tile jump
        // between "940 m" and "1.02 km" mid-walk, which reads as the number
        // resetting rather than growing.
        return String(format: "%.2f km", Double(meters) / 1000)
    }

    // MARK: - actions

    func connectTapped() {
        guard !busy else { return }
        run {
            if self.isConnected {
                self.automaticConnectionEnabled = false
                self.reconnectTask?.cancel()
                await self.treadmill.disconnect()
            } else {
                self.automaticConnectionEnabled = true
                try await self.treadmill.connect()
                // If the pad's own display units disagree with the persisted
                // setting, push our setting down (best-effort).
                let props = await self.treadmill.status.properties
                let padImperial = Z1Units.propertyIndicatesImperial(props[1] ?? 0)
                if padImperial != self.unitsImperial {
                    try? await self.treadmill.setDisplayUnits(imperial: self.unitsImperial)
                }
            }
        }
    }

    /// Which transition the button is mid-way through, latched at tap time so
    /// telemetry arriving early cannot flip the label to the wrong verb.
    @Published private(set) var pendingVerb: String?

    func startStopTapped() {
        guard !busy, isConnected else { return }
        // Latch the intent at tap. Re-reading beltRunning inside `run` races
        // telemetry: a leftover speed from the last walk made Start send Stop.
        let stopping = status.beltRunning
        pendingVerb = stopping ? "Stopping…" : "Starting…"
        run {
            defer { self.pendingVerb = nil }
            if stopping {
                let summary = try await self.treadmill.stop()
                self.lastSummary = summary
            } else {
                self.lastSummary = nil
                try await self.treadmill.start()
                // A speed picked while the belt was stopped is applied as soon
                // as it is moving — the pad always starts at its minimum.
                if let pending = self.pendingTargetKmh {
                    self.pendingTargetKmh = nil
                    try await self.treadmill.setSpeed(pending)
                }
            }
        }
    }

    /// Jump straight to a speed, in the current display unit.
    ///
    /// The pad only accepts speed changes while the belt is moving, so a value
    /// picked at a standstill is remembered and applied right after Start.
    func setSpeed(_ displayValue: Double) {
        guard isConnected else { return }
        let kmh = unitsImperial ? Z1Units.mphToKmh(displayValue) : displayValue
        let clamped = (min(max(kmh, status.minSpeedKmh), status.maxSpeedKmh) * 10).rounded() / 10
        guard status.beltRunning else {
            pendingTargetKmh = clamped
            return
        }
        // dial commits should be immediate, not coalesced with +/- queue
        coalescedTargetKmh = nil
        speedTask?.cancel()
        speedBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.speedBusy = false }
            do {
                try await self.treadmill.setSpeed(clamped)
                self.commandError = nil
            } catch {
                self.commandError = error.localizedDescription
            }
        }
    }

    /// Selectable speed range in display units — exact conversion, no rounding loss.
    var speedRange: ClosedRange<Double> {
        let low = unitsImperial ? Z1Units.kmhToMph(status.minSpeedKmh) : status.minSpeedKmh
        let high = unitsImperial ? Z1Units.kmhToMph(status.maxSpeedKmh) : status.maxSpeedKmh
        guard low < high else { return 1.6...6.4 }
        // Keep full precision; SpeedDial snaps internally to 0.1 kmh.
        // Imperial dial still shows 0.1 mph ticks via its own step.
        return low ... high
    }

    /// A speed chosen at a standstill, waiting for the next Start.
    var pendingTargetDisplaySpeed: Double? {
        guard let pendingTargetKmh else { return nil }
        return unitsImperial ? Z1Units.kmhToMph(pendingTargetKmh) : pendingTargetKmh
    }

    func speedUpTapped() {
        guard isConnected, status.beltRunning else { return }
        enqueueSpeedChange(deltaKmh: speedStepKmh)
    }

    func speedDownTapped() {
        guard isConnected, status.beltRunning else { return }
        enqueueSpeedChange(deltaKmh: -speedStepKmh)
    }

    private func enqueueSpeedChange(deltaKmh: Double) {
        // coalesce rapid taps: accumulate delta and fire once
        let base = coalescedTargetKmh ?? status.speedKmh
        let next = min(max(base + deltaKmh, status.minSpeedKmh), status.maxSpeedKmh)
        coalescedTargetKmh = (next * 10).rounded() / 10
        // debounce: wait 120ms for more taps, then send
        speedTask?.cancel()
        speedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let target = self.coalescedTargetKmh else { return }
            self.coalescedTargetKmh = nil
            self.speedBusy = true
            defer { self.speedBusy = false }
            do {
                try await self.treadmill.setSpeed(target)
                self.commandError = nil
            } catch {
                self.commandError = error.localizedDescription
            }
        }
    }

    func clearStatsTapped() {
        Task { await treadmill.clearStats() }
    }

    /// Leave without touching the belt — for when you are still walking and
    /// just want the app (and the pad's single BLE slot) out of the way.
    func quit() {
        automaticConnectionEnabled = false
        reconnectTask?.cancel()
        sleepBlocker.setActive(false)
        let treadmill = self.treadmill
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await treadmill.disconnect() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.terminate(nil)
        }
    }

    /// Quit without waiting on BLE so the helper can swap the bundle and
    /// reopen. The belt is left running, same as Quit.
    func quitForUpdate() {
        automaticConnectionEnabled = false
        reconnectTask?.cancel()
        sleepBlocker.setActive(false)
        treadmill.cancelConnectionNow()
        NSApp.terminate(nil)
    }

    func checkForUpdate() {
        Task { await checkForUpdateAndMaybeInstall(force: true) }
    }

    func installUpdate() {
        Task { await applyAvailableUpdate() }
    }

    func checkForUpdateAndMaybeInstall(force: Bool = false) async {
        await updater.check(force: force)
        if autoUpdate { await applyAvailableUpdate() }
    }

    private func applyAvailableUpdate() async {
        guard case .available = updater.phase else { return }
        let ready = await updater.installAndPrepareRelaunch()
        if ready { quitForUpdate() }
    }

    /// Stop the belt, put the pad in standby, then quit — never hanging more
    /// than 3s if BLE does not answer.
    func stopBeltAndQuit() {
        automaticConnectionEnabled = false
        reconnectTask?.cancel()
        sleepBlocker.setActive(false)
        let treadmill = self.treadmill
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await treadmill.sleep()
                    await treadmill.disconnect()
                }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.terminate(nil)
        }
    }

    private func run(_ op: @MainActor @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await op()
                commandError = nil
            } catch {
                // surface command failures in the popover — a silent retry
                // loop is how "I hit Start and nothing happens" happens
                commandError = error.localizedDescription
                NSLog("Z1MenuBar: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - physical-remote session tracking

    private func receiveStatus(_ newStatus: Z1Treadmill.Status) {
        let previousPhase = status.phase
        status = newStatus
        if newStatus.phase != previousPhase {
            recordConnectionChange(newStatus)
            if newStatus.phase == .error {
                failedAttempts += 1
            } else if newStatus.phase == .ready {
                failedAttempts = 0
            }
        }
        // Hold off idle sleep for exactly as long as the belt moves, so a long
        // walk cannot be truncated by the Mac dozing off mid-session.
        sleepBlocker.setActive(newStatus.beltRunning)
        if newStatus.phase == .disconnected || newStatus.phase == .error {
            scheduleReconnect(after: newStatus.phase == .error ? 10 : 1)
        }
        guard newStatus.phase == .ready, newStatus.hasTelemetry else { return }

        let observation = healthTracker.observe(newStatus)
        persistHealthTracker()
        logCompletedWalks(observation.completed)
        scheduleHealthFinalization(deadline: observation.finalizationDeadline)
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
    }

    private func persistHealthTracker() {
        guard let data = try? JSONEncoder().encode(healthTracker) else { return }
        UserDefaults.standard.set(data, forKey: Self.healthTrackerKey)
    }

    private static func restoreHealthTracker(from defaults: UserDefaults) -> RemoteSessionTracker {
        guard let data = defaults.data(forKey: healthTrackerKey),
              let tracker = try? JSONDecoder().decode(RemoteSessionTracker.self, from: data)
        else { return RemoteSessionTracker() }
        return tracker
    }

    /// A short, durable trail of connection changes.
    ///
    /// The pad only streams telemetry while the belt moves, so an idle app that
    /// is connected and an app that never connected look identical from the
    /// outside. This is the app saying which one it is.
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
    /// exactly that, once, and then never touch it again — start-at-login is
    // MARK: - walk reminders

    private func checkWalkReminder(now: Date = Date()) {
        guard remindersEnabled, notificationsEnabled else { return }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        guard (9..<18).contains(hour), (2...6).contains(weekday) else { return }
        guard !status.beltRunning, openWalk == nil else { return }

        // Quiet long enough?
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
            body = "Quiet for \(Int(quietHours))h — \(max(0, dailyGoalSteps - todaySteps)) steps to go today."
        } else {
            let lines = [
                "The belt has been quiet for a while.",
                "A short walk would round the day off.",
                "Still \(max(0, dailyGoalMinutes - todayActiveMinutes)) min to today's goal.",
                "The pad is right there.",
            ]
            body = lines[Int(now.timeIntervalSince1970 / 60) % lines.count]
        }
        notifier.post(title: "Time for a walk?", body: body, identifier: "reminder-\(Int(now.timeIntervalSince1970))")
        log.append(now)
        if log.count > 20 { log.removeFirst(log.count - 20) }
        UserDefaults.standard.set(log, forKey: Self.reminderLogKey)
    }

    /// the toggle in Settings and nothing else.
    private func undoAutomaticLoginItem() {
        let defaults = UserDefaults.standard
        defer { defaults.set(LoginItem.statusDescription, forKey: Self.loginStatusKey) }
        guard defaults.object(forKey: "launchAtLoginConfigured") != nil else { return }
        defaults.removeObject(forKey: "launchAtLoginConfigured")
        _ = LoginItem.set(false)
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - history

    /// Record every finished walk in local history.
    private func logCompletedWalks(_ walks: [CompletedWalk]) {
        guard !walks.isEmpty else { return }
        for walk in walks {
            // Stepping on the belt for a moment is not a walk. Drain the log
            // entry so it is not offered again, but keep it out of the history.
            guard walk.activeDurationS >= 120 else {
                healthTracker.acknowledgeLog(sessionID: walk.id)
                continue
            }
            let kcal = Z1Metrics.kcalPerMinute(walk.avgSpeedKmh, weightKg: weightKg)
                * Double(walk.activeDurationS) / 60
            let added = sessionStore.append(
                WalkSession(
                    id: walk.id,
                    startedAt: walk.startedAt,
                    endedAt: walk.endedAt,
                    activeDurationS: walk.activeDurationS,
                    distanceM: walk.distanceM,
                    steps: walk.steps,
                    caloriesKcal: (kcal * 10).rounded() / 10,
                    exportedToHealth: false
                )
            )
            healthTracker.acknowledgeLog(sessionID: walk.id)
            guard added, notificationsEnabled else { continue }
            let minutes = max(1, walk.activeDurationS / 60)
            let body = "\(minutes) min · \(formatDistance(walk.distanceM)) · \(walk.steps) steps"
            notifier.post(title: "Walk recorded", body: body, identifier: walk.id)
        }
        persistHealthTracker()
        refreshHistory()
    }

    func refreshHistoryFromDisk() {
        sessionStore.reload()
        refreshHistory()
    }

    private func refreshHistory() {
        todayTotals = sessionStore.totals()
        recentWalks = sessionStore.mostRecent(12)
        weekDays = sessionStore.recentDays(7)
        monthDays = sessionStore.recentDays(30)
        highScores = sessionStore.highScores
        achievements = sessionStore.achievements
    }

    /// Today's active minutes, including a walk still in progress (which does
    /// not reach the history until its ten-minute grace period expires).
    private var openWalk: CompletedWalk? { healthTracker.openWalkTotals }

    /// A walk is running or inside its stop-grace window.
    var hasOpenWalk: Bool { healthTracker.openWalkTotals != nil }

    /// Totals for any calendar day, with the open walk folded into today so
    /// the almanac's "Today" agrees with reality mid-walk.
    func totals(for day: Date) -> DayTotals {
        var totals = sessionStore.totals(on: day)
        if Calendar.current.isDateInToday(day), let open = openWalk,
           !sessionStore.contains(id: open.id)
        {
            totals.activeDurationS += open.activeDurationS
            totals.distanceM += open.distanceM
            totals.steps += StepSanity.steps(open.steps, distanceM: open.distanceM)
            totals.caloriesKcal += Z1Metrics.kcalPerMinute(open.avgSpeedKmh, weightKg: weightKg)
                * Double(open.activeDurationS) / 60
        }
        return totals
    }

    var todayActiveMinutes: Int {
        (todayTotals.activeDurationS + (openWalk?.activeDurationS ?? 0)) / 60
    }

    /// What the live numbers imply per step, for comparison with a hand count.
    var strideLabel: String {
        guard let stride = status.impliedStrideM else { return "—" }
        let cm = Int((stride * 100).rounded())
        return "\(cm) cm"
    }

    /// Today's steps, including the walk still in progress.
    ///
    /// A walk does not reach the history until its ten-minute grace period
    /// expires, so all three "Today" figures fold in the live session — they
    /// must agree with each other, or the row reads "54 min · 0 m · 0 steps"
    /// while you are visibly walking.
    var todaySteps: Int {
        totals(for: Date()).steps
    }

    var todayDistanceM: Int {
        todayTotals.distanceM + (openWalk?.distanceM ?? 0)
    }

    /// Everything ever recorded, for the lifetime journey line.
    var lifetimeDistanceM: Int {
        sessionStore.sessions.reduce(0) { $0 + $1.distanceM }
    }

    var todayKcal: Int {
        let live = openWalk.map {
            Z1Metrics.kcalPerMinute($0.avgSpeedKmh, weightKg: weightKg)
                * Double($0.activeDurationS) / 60
        } ?? 0
        return Int((todayTotals.caloriesKcal + live).rounded())
    }

    /// Goal progress for an arbitrary day's totals, honouring the goal kind.
    func goalProgress(for totals: DayTotals) -> Double {
        if goalIsSteps {
            return min(1, Double(totals.steps) / Double(max(1, dailyGoalSteps)))
        }
        return min(1, Double(totals.activeDurationS) / Double(max(1, dailyGoalMinutes * 60)))
    }

    /// "173/8000" or "96/120 min" for a day.
    func goalText(for totals: DayTotals) -> String {
        goalIsSteps
            ? "\(totals.steps)/\(dailyGoalSteps)"
            : "\(totals.activeDurationS / 60)/\(dailyGoalMinutes) min"
    }

    /// 0...1 against the daily goal, or nil when no goal is set.
    var goalProgress: Double? {
        guard goalIsSteps || dailyGoalMinutes > 0 else { return nil }
        return goalProgress(for: totals(for: Date()))
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

    // MARK: - menu bar

    /// The text beside the menu-bar icon, or nil for icon-only.
    var menuBarText: String? {
        guard menuBarReadout != .none else { return nil }
        guard status.beltRunning || menuBarAlwaysVisible else { return nil }
        switch menuBarReadout {
        case .none: return nil
        case .speed: return String(format: "%.1f", displaySpeed)
        case .elapsed: return formatElapsed(status.elapsedS)
        case .distance: return formatDistance(status.distanceM)
        case .steps: return status.steps.formatted(.number)
        case .calories: return "\(Int(status.caloriesKcal.rounded()))"
        case .todayTime:
            return dailyGoalMinutes > 0
                ? goalText(for: totals(for: Date()))
                : "\(todayActiveMinutes)m"
        case .todaySteps:
            return todaySteps.formatted(.number)
        }
    }

    // MARK: - power management

    private func installPowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Waking is the single best moment to retry: the pad is usually
            // right there and the backoff would otherwise idle for 30s.
            Task { @MainActor in self?.scheduleReconnect(after: 1, force: true) }
        }
    }

    /// Rolls "Today" over at midnight without polling the session store on
    /// every telemetry frame.
    private func startHousekeeping() {
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.refreshHistory()
            }
        }
    }

    // Connecting only scans, unlocks telemetry, and reads settings; it never
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
            // Backoff, not a fixed 10s poll: retry hard right after a drop
            // (the pad is usually still there), then ease off so a pad that is
            // switched off for the day costs nothing.
            var attempt = 0
            while !Task.isCancelled, self.automaticConnectionEnabled {
                if self.status.phase == .ready { return }
                if !self.busy,
                   (self.status.phase == .disconnected || self.status.phase == .error)
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
