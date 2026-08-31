import AppKit
import SwiftUI
import Z1Core

@MainActor
struct MenuBarView: View {
    @ObservedObject var viewModel: TreadmillViewModel

    /// The speed the dial is showing. Tracks the pad while untouched, and
    /// stops tracking while you are dragging or typing so telemetry cannot
    /// yank the control out from under you.
    @State private var speedDraft = 0.0
    @State private var isPickingSpeed = false
    @State private var isTypingSpeed = false
    @FocusState private var speedFieldFocused: Bool
    @State private var showHistory = false
    @State private var showSettings = false

    /// The almanac card's range, and which day inside it is selected.
    /// nil selection = today. Every popover open starts fresh on today.
    enum AlmanacLens { case week, month }
    @State private var almanacLens: AlmanacLens = .week
    @State private var selectedDay: Date?
    @State private var weather: WeatherSnapshot? = nil
    @State private var kp: Double = 0
    @State private var showHighScores = false
    @AppStorage("z1.hasSeenIntro") private var hasSeenIntro = false

    var body: some View {
        ZStack {
            if !hasSeenIntro {
                OnboardingView(onContinue: { hasSeenIntro = true })
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                mainPopover
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.28), value: hasSeenIntro)
    }

    private var mainPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                header
                hero
                dialRow
                actionButton
                if viewModel.status.beltRunning {
                    statsRow
                }
                footer
                if let error = viewModel.commandError ?? viewModel.status.errorMessage {
                    Text(error)
                        .font(Z1Type.regular(11))
                        .foregroundStyle(Z1.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            updateRow
            rule
            HStack(spacing: 10) {
                sectionToggle("History", $showHistory)
                sectionToggle("Records", $showHighScores)
                sectionToggle("Settings", $showSettings)
                Spacer(minLength: 6)
                Button("Quit") { viewModel.quit() }
                    .buttonStyle(HairlineButtonStyle())
                    .font(Z1Type.regular(11))
                    .fixedSize()
                    .keyboardShortcut("q")
                    .help("Quit and leave the belt exactly as it is")
            }
            if showHistory {
                dropdownPanel { historyBody }
            }
            if showHighScores {
                dropdownPanel { highScoreBody }
            }
            if showSettings {
                dropdownPanel { settingsBody }
            }
        }
        .padding(14)
        .frame(width: 300)
        .frame(maxHeight: popoverMaxHeight, alignment: .top)
        .background {
            SkyField(intensity: viewModel.goalProgress ?? 0, weather: weather, kp: kp)
                .ignoresSafeArea()
        }
        // Belt state must not implicitly animate this stack: the Start/Stop
        // snap, the stats slot, and AuraCard's own animation would fight.
        .animation(nil, value: viewModel.status.beltRunning)
        .animation(.smooth(duration: 0.35), value: viewModel.isConnected)
        .onAppear {
            syncSpeedDraft()
            viewModel.checkForUpdate()
        }
        .onChange(of: viewModel.displaySpeed) { _, _ in syncSpeedDraft() }
        .onChange(of: viewModel.unitsImperial) { _, _ in syncSpeedDraft() }
    }

    /// Hang under the menu bar with a little margin; never a full-screen
    /// window. Tight screens shrink the History/Settings panel first.
    private var popoverMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 48
    }

    /// Grow with the section until it would shove the popover off-screen,
    /// then scroll. Never clip a control in the middle of a row.
    private var dropdownMaxHeight: CGFloat {
        max(280, popoverMaxHeight - 320)
    }

    private func dropdownPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(minHeight: 120, maxHeight: dropdownMaxHeight, alignment: .top)
        .transition(.opacity)
    }

    /// One colour truth for the popover, taken from the sky itself.
    private var skyAccent: Color { SkyField.accent(weather: weather) }

    /// What is falling, honouring the sky simulator so rehearsed weather
    /// splashes too.
    private var effectivePrecip: WeatherSnapshot.PrecipStyle {
        switch UserDefaults.standard.string(forKey: "z1.skySimWeather") {
        case "drizzle": return .drizzle
        case "rain", "sunshower": return .rain
        case "downpour", "storm": return .downpour
        case "snow": return .snow
        case .some: return .none
        case nil: return weather?.precipStyle ?? .none
        }
    }

    private var splashStrip: some View {
        ZStack(alignment: .bottom) {
            SkyLayers.RainSplash(style: effectivePrecip)
            SkyLayers.SnowCap(style: effectivePrecip)
        }
        .frame(height: 10)
        .allowsHitTesting(false)
    }

    /// Condensation on the hero glass in fog or steady rain.
    private var dewStrength: Double {
        if UserDefaults.standard.string(forKey: "z1.skySimWeather") == "fog" { return 1 }
        guard let weather else { return 0 }
        if weather.isFoggy { return 1 }
        switch weather.precipStyle {
        case .rain: return 0.5
        case .downpour: return 0.8
        default: return 0
        }
    }

    private var rule: some View {
        Rectangle().fill(Z1.hairline).frame(height: 0.7)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch viewModel.updater.phase {
        case .available(let feed):
            Button(action: viewModel.installUpdate) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available")
                            .font(Z1Type.medium(11))
                            .foregroundStyle(Z1.ink)
                        Text(feed.notes?.isEmpty == false ? feed.notes! : "Build \(feed.version)")
                            .font(Z1Type.regular(10))
                            .foregroundStyle(Z1.faint)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Install")
                        .font(Z1Type.medium(11))
                }
            }
            .buttonStyle(HairlineButtonStyle())
            .disabled(viewModel.updater.isBusy)
        case .downloading:
            Text("Downloading update…")
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.dim)
        case .installing:
            Text("Restarting…")
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.dim)
        case .failed(let message):
            Button(action: viewModel.checkForUpdate) {
                Text(message)
                    .font(Z1Type.regular(10))
                    .foregroundStyle(Z1.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
        case .idle, .checking:
            EmptyView()
        }
    }

    // MARK: - speed plumbing

    private func syncSpeedDraft() {
        guard !isPickingSpeed, !speedFieldFocused else { return }
        let live = viewModel.displaySpeed
        speedDraft = live > 0
            ? live
            : (viewModel.pendingTargetDisplaySpeed ?? viewModel.speedRange.lowerBound)
    }

    private func commitSpeedDraft() {
        let range = viewModel.speedRange
        let clamped = min(max(speedDraft, range.lowerBound), range.upperBound)
        speedDraft = (clamped * 10).rounded() / 10
        viewModel.setSpeed(speedDraft)
    }

    private var speedText: String {
        let shown = isPickingSpeed ? speedDraft : viewModel.displaySpeed
        return String(format: "%.1f", shown)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(viewModel.isConnected ? Z1.live : (viewModel.isConnecting ? Z1.ink.opacity(0.6) : Z1.faint))
                    .frame(width: 7, height: 7)
                    .scaleEffect(viewModel.isConnecting ? 1.18 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: viewModel.isConnecting)
                if viewModel.isConnecting {
                    Circle()
                        .strokeBorder(Z1.ink.opacity(0.25), lineWidth: 0.7)
                        .frame(width: 14, height: 14)
                        .opacity(0.9)
                }
            }
            .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.status.deviceName ?? "WalkingPad Z1")
                    .font(Z1Type.medium(13))
                    .foregroundStyle(Z1.ink)
                    .lineLimit(1)
                if !viewModel.isConnected {
                    Text(phaseLabel)
                        .font(Z1Type.regular(10))
                        .foregroundStyle(viewModel.failedAttempts >= 2 ? Z1.ink.opacity(0.7) : Z1.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.opacity)
                } else if viewModel.status.beltRunning {
                    Text("Walk in progress — controls live")
                        .font(Z1Type.regular(10))
                        .foregroundStyle(Z1.live.opacity(0.9))
                        .lineLimit(1)
                } else {
                    Text("Ready — tap Start or use remote")
                        .font(Z1Type.regular(10))
                        .foregroundStyle(Z1.faint)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button(action: { viewModel.connectTapped() }) {
                Group {
                    if viewModel.isConnecting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Z1.ink)
                            .frame(width: 28, height: 22)
                    } else {
                        Text(viewModel.isConnected ? "Disconnect" : "Connect")
                            .font(Z1Type.medium(11))
                    }
                }
            }
            .buttonStyle(HairlineButtonStyle())
            .fixedSize()
            .disabled(viewModel.busy && !viewModel.isConnecting)
            .animation(.smooth(duration: 0.2), value: viewModel.isConnecting)
            .animation(.smooth(duration: 0.2), value: viewModel.isConnected)
        }
    }

    private var phaseLabel: String {
        if viewModel.failedAttempts >= 3 {
            return "Pad off or busy — power on, close phone app"
        }
        if viewModel.failedAttempts == 2 {
            return "Still looking — is pad on? (one connection only)"
        }
        switch viewModel.status.phase {
        case .disconnected: return "Tap Connect to link"
        case .scanning: return "Finding your Z1…"
        case .connecting: return "Handshaking — unlocking pad"
        case .ready: return "Connected"
        case .error: return viewModel.status.errorMessage ?? "No pad found — tap retry"
        }
    }

    // MARK: - hero

    /// Speed lives here, centred in a card lit from its own edge.
    /// Blue while the belt moves, dark when not.
    private var hero: some View {
        AuraCard(colour: skyAccent, active: viewModel.status.beltRunning, radius: 16) {
            HStack(alignment: .center, spacing: 8) {
                if isTypingSpeed {
                    TextField("", value: $speedDraft, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.plain)
                        .font(Z1Type.light(30))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Z1.ink)
                        .frame(width: 88)
                        .focused($speedFieldFocused)
                        .onSubmit {
                            commitSpeedDraft()
                            isTypingSpeed = false
                        }
                        .onExitCommand { isTypingSpeed = false }
                } else {
                    DotMatrixText(
                        text: speedText,
                        dot: 3.5,
                        gap: 1.7,
                        color: Z1.ink,
                        lit: viewModel.isConnected
                    )
                    .onTapGesture {
                        guard viewModel.isConnected else { return }
                        isTypingSpeed = true
                        speedFieldFocused = true
                    }
                    .help("Click to type an exact speed")
                }
                Text(viewModel.speedUnitLabel)
                    .font(Z1Type.regular(11))
                    .foregroundStyle(Z1.dim)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: 62)
        }
        .overlay(alignment: .top) { splashStrip.offset(y: -3) }
        .overlay {
            SkyLayers.Dew(strength: dewStrength)
                .clipShape(.rect(cornerRadius: 16))
        }
    }

    // MARK: - dial

    private var dialRow: some View {
        HStack(spacing: 10) {
            nudge("minus", action: viewModel.speedDownTapped)
            SpeedDial(
                range: viewModel.speedRange,
                value: $speedDraft,
                enabled: viewModel.isConnected,
                onEditingChanged: { isPickingSpeed = $0 },
                onCommit: commitSpeedDraft
            )
            nudge("plus", action: viewModel.speedUpTapped)
        }
    }

    private func nudge(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.status.beltRunning ? Z1.ink : Z1.faint)
        .background(Circle().strokeBorder(Z1.hairline, lineWidth: 0.7))
        .disabled(!viewModel.status.beltRunning || viewModel.busy)
        .help(
            viewModel.status.beltRunning
                ? "Nudge the speed"
                : "The pad only accepts speed changes while the belt is moving"
        )
    }

    // MARK: - action

    /// Honest label. The destination-verb trick showed Stop the instant you
    /// tapped Start, before the belt moved — it looked like Start was broken.
    private var actionLabel: String {
        viewModel.status.beltRunning ? "Stop" : "Start"
    }

    private var actionButton: some View {
        Button(action: viewModel.startStopTapped) {
            Text(actionLabel)
                .font(Z1Type.medium(12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                // The label is state, not decoration: it must snap, never
                // morph — the crossfading glyphs were the "glitch".
                .contentTransition(.identity)
                .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Z1.ink)
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop the belt. Space does the same while this window is open.")
        .z1LiquidGlass(radius: Z1.radius)
        .z1Card(radius: Z1.radius, lit: true)
        .opacity(viewModel.isConnected ? 1 : 0.3)
        // `startStopTapped` already no-ops while `busy`; disabling here would
        // grey the chrome for the round-trip and read as a flicker.
        .disabled(!viewModel.isConnected)
        .animation(nil, value: actionLabel)
        .animation(nil, value: viewModel.pendingVerb)
    }

    // MARK: - stats

    /// This walk. Boxed tiles made these compete with the day's totals below
    /// for the same attention; as a plain row they read as a caption to the
    /// hero, which is what they are. Two of the four are measured and two are
    /// modelled, and they are still not allowed to look alike.
    private var statsRow: some View {
        let st = viewModel.status
        return HStack(spacing: 0) {
            walkStat(viewModel.formatDuration(st.elapsedS), "Elapsed")
            divider
            walkStat(viewModel.formatDistance(st.distanceM), "Distance")
            divider
            walkStat(st.steps.formatted(.number), "Steps", measured: false)
            divider
            walkStat("\(Int(st.caloriesKcal.rounded()))", "kcal", measured: false)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Z1.hairline)
            .frame(width: 0.7, height: 22)
    }

    private func walkStat(_ value: String, _ label: String, measured: Bool = true) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Z1Type.medium(16))
                .foregroundStyle(Z1.ink)
                .contentTransition(.numericText())
                .lineLimit(1)
            Text(measured ? label : "\(label) est.")
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.faint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// The day's standing, as one object: how far through the goal, then the
    /// three totals underneath it. Everything here is *today*, which is what
    /// separates it from the walk row above.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            todayCard
            strideLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todayCard: some View {
        let day = selectedDay ?? Calendar.current.startOfDay(for: Date())
        let totals = viewModel.totals(for: day)
        return VStack(alignment: .leading, spacing: 9) {
            Button {
                almanacLens = almanacLens == .week ? .month : .week
                selectedDay = nil
            } label: {
                HStack(spacing: 5) {
                    Text(dayTitle(day))
                        .font(Z1Type.medium(16))
                        .foregroundStyle(Z1.ink)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Z1.faint)
                    Spacer()
                    Text(viewModel.goalText(for: totals))
                        .font(Z1Type.regular(12))
                        .foregroundStyle(Z1.ink.opacity(0.55))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            dayGoalLine(totals)
            kcalSparkline(for: day)
            tileStrip
            HStack(spacing: 0) {
                walkStat(viewModel.formatDistance(totals.distanceM), "Distance")
                divider
                walkStat(viewModel.formatDuration(totals.activeDurationS), "Time")
                divider
                walkStat(totals.steps.formatted(.number), "Steps", measured: false)
                divider
                walkStat("\(Int(totals.caloriesKcal.rounded()))", "kcal", measured: false)
            }
            Text(almanacFooter(totals))
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.ink.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(12)
        .z1LiquidGlass(radius: 12)
        .overlay(alignment: .top) { splashStrip.offset(y: -3) }
        .z1InnerGlow(Z1.live, radius: 12, strength: 0.34, width: 10)
        .z1Card(radius: 12)
    }

    private func kcalSparkline(for day: Date) -> some View {
        let bins = viewModel.hourlyKcal(for: day)
        let peak = max(bins.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                Capsule()
                    .fill(bins[hour] > 0 ? Z1.ink.opacity(0.85) : Z1.unlit)
                    .frame(height: max(2, 28 * bins[hour] / peak))
            }
        }
        .frame(height: 28)
        .help("kcal by hour")
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func dayGoalLine(_ totals: DayTotals) -> some View {
        let progress = viewModel.goalProgress(for: totals)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Z1.unlit)
                Capsule()
                    .fill(Z1.ink.opacity(0.85))
                    .frame(width: max(2, geometry.size.width * progress))
                    .shadow(color: .white.opacity(0.5), radius: 3)
            }
        }
        .frame(height: 2.5)
    }

    /// The range, every day a little sky, every sky clickable. Selecting a
    /// day swaps the stats and footer below it in place — the card never
    /// changes size, the interface never moves.
    ///
    /// Fill height is the day's progress, not an opacity wash: today is ink,
    /// the rest are quieter, empty days stay unlit.
    private var tileStrip: some View {
        let days = almanacLens == .week ? viewModel.weekDays : viewModel.monthDays
        let labelled = almanacLens == .week
        let selected = selectedDay ?? Calendar.current.startOfDay(for: Date())
        let barHeight: CGFloat = labelled ? 32 : 44
        let corner: CGFloat = labelled ? 4 : 2
        return HStack(spacing: labelled ? 3 : 1.5) {
            ForEach(days) { day in
                let progress = min(1, max(0, viewModel.goalProgress(for: day)))
                let isSelected = Calendar.current.isDate(day.day, inSameDayAs: selected)
                let isToday = Calendar.current.isDateInToday(day.day)
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Z1.unlit)
                        if !day.isEmpty {
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(isToday ? Z1.ink.opacity(0.88) : Z1.ink.opacity(0.28))
                                .frame(height: max(3, barHeight * CGFloat(progress)))
                        }
                    }
                    .frame(height: barHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? Z1.ink.opacity(0.7)
                                    : (isToday ? Z1.ink.opacity(0.35) : Z1.hairline),
                                lineWidth: isSelected ? 1 : 0.7
                            )
                    )
                    if labelled {
                        Text(day.day, format: .dateTime.weekday(.narrow))
                            .font(Z1Type.regular(9))
                            .foregroundStyle(isToday ? Z1.ink : Z1.faint)
                    }
                }
                .contentShape(.rect)
                .onTapGesture {
                    selectedDay = Calendar.current.isDateInToday(day.day) ? nil : day.day
                }
                .help(dayHelp(day))
            }
        }
        .frame(height: 44)
    }

    private func dayHelp(_ day: DayTotals) -> String {
        day.isEmpty
            ? "No walk"
            : "\(day.activeDurationS / 60) min · \(viewModel.formatDistance(day.distanceM)) · \(day.steps) steps"
    }

    private func almanacFooter(_ totals: DayTotals) -> String {
        if almanacLens == .month, selectedDay == nil, totals.distanceM == 0 {
            return Equivalence.journeyLine(totalMeters: viewModel.lifetimeDistanceM)
        }
        return Equivalence.caption(
            distanceM: totals.distanceM,
            kcal: totals.caloriesKcal,
            minutes: totals.activeDurationS / 60
        )
    }

    /// What the numbers imply per step. Shown because it is the one figure you
    /// can check by hand, and the only way to find out whether the pad's step
    /// sensor is telling the truth.
    private var strideLine: some View {
        HStack {
            Text("Stride")
                .font(Z1Type.regular(12))
                .foregroundStyle(Z1.dim)
            Spacer()
            Text(viewModel.strideLabel)
                .font(Z1Type.regular(12))
                .foregroundStyle(Z1.ink.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - records

    private var highScoreBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            let hs = viewModel.highScores
            if hs.totalWalks == 0 {
                Text("No records yet — a walk of two minutes or more lands here.")
                    .font(Z1Type.regular(11))
                    .foregroundStyle(Z1.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("\(hs.totalWalks) walks")
                        .font(Z1Type.medium(11))
                        .foregroundStyle(Z1.ink)
                    Spacer()
                    Text(viewModel.formatDistance(hs.totalDistanceM))
                        .font(Z1Type.regular(11))
                        .foregroundStyle(Z1.faint)
                }
                recordSection("Walk") {
                    ForEach(highScoreRows, id: \.label) { row in
                        recordLine(row.label, row.value, systemName: row.systemName)
                    }
                }
                recordSection("Day") {
                    if let d = hs.mostStepsDay {
                        recordLine("Steps", "\(d.steps.formatted())", date: d.day, systemName: "shoeprints.fill")
                    }
                    if let d = hs.mostDistanceDay {
                        recordLine("Distance", viewModel.formatDistance(d.distanceM), date: d.day, systemName: "ruler")
                    }
                    if let d = hs.mostKcalDay {
                        recordLine("kcal", "\(Int(d.caloriesKcal.rounded()))", date: d.day, systemName: "flame")
                    }
                    if let d = hs.longestDayTime {
                        recordLine("Time", viewModel.formatDuration(d.activeDurationS), date: d.day, systemName: "timer")
                    }
                    if hs.bestStreakDays > 1 {
                        recordLine("Streak", "\(hs.bestStreakDays) days", systemName: "repeat")
                    }
                }
                recordSection(
                    "Badges  \(viewModel.achievements.filter(\.unlocked).count)/\(viewModel.achievements.count)"
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], spacing: 6) {
                        ForEach(viewModel.achievements) { ach in
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: ach.kind.systemName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ach.unlocked ? Z1.ink : Z1.faint)
                                    .frame(height: 14)
                                Text(ach.kind.title)
                                    .font(Z1Type.medium(10))
                                    .foregroundStyle(ach.unlocked ? Z1.ink : Z1.faint)
                                    .lineLimit(1)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Z1.unlit)
                                        Capsule()
                                            .fill(ach.unlocked ? Z1.ink : Z1.faint.opacity(0.5))
                                            .frame(width: max(2, geo.size.width * CGFloat(ach.progress)))
                                    }
                                }
                                .frame(height: 2)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(ach.unlocked ? Z1.hairlineLit : Z1.hairline, lineWidth: 0.7)
                            )
                            .help(ach.kind.description)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func recordSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Z1Type.medium(11))
                .foregroundStyle(Z1.ink)
            content()
        }
    }

    private func recordLine(
        _ label: String,
        _ value: String,
        date: Date? = nil,
        systemName: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Z1.faint)
                    .frame(width: 14)
            }
            Text(label)
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.dim)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(Z1Type.medium(11))
                    .foregroundStyle(Z1.ink)
                    .multilineTextAlignment(.trailing)
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(Z1Type.regular(9))
                        .foregroundStyle(Z1.faint)
                }
            }
        }
    }

    private var highScoreRows: [(systemName: String, label: String, value: String)] {
        let hs = viewModel.highScores
        var rows: [(String,String,String)] = []
        if let w = hs.longestWalk { rows.append(("timer","Longest walk", viewModel.formatDuration(w.activeDurationS) + " · " + viewModel.formatDistance(w.distanceM))) }
        if let w = hs.farthestWalk { rows.append(("ruler","Farthest", viewModel.formatDistance(w.distanceM) + " · " + viewModel.formatDuration(w.activeDurationS))) }
        if let w = hs.mostStepsWalk { rows.append(("shoeprints.fill","Most steps", "\(w.steps.formatted())")) }
        if let w = hs.mostKcalWalk { rows.append(("flame.fill","Most kcal", "\(Int(w.caloriesKcal.rounded())) kcal")) }
        return rows
    }

    // MARK: - history

    private func sectionToggle(_ title: String, _ open: Binding<Bool>) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                if open.wrappedValue {
                    open.wrappedValue = false
                } else {
                    showHistory = false
                    showHighScores = false
                    showSettings = false
                    open.wrappedValue = true
                    viewModel.refreshHistoryFromDisk()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text(title)
                    .font(Z1Type.regular(13))
            }
            .foregroundStyle(open.wrappedValue ? Z1.ink : Z1.dim)
            .fixedSize()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
    }

    private var historyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.recentWalks.isEmpty {
                Text("Nothing recorded yet")
                    .font(Z1Type.regular(11))
                    .foregroundStyle(Z1.faint)
            } else {
                ForEach(viewModel.recentWalks) { walk in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(walk.startedAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                .foregroundStyle(Z1.faint)
                            Spacer()
                            Text(viewModel.formatDuration(walk.activeDurationS))
                                .foregroundStyle(Z1.ink)
                        }
                        Text(
                            "\(viewModel.formatDistance(walk.distanceM))  ·  \(walk.steps.formatted()) steps  ·  \(Int(walk.caloriesKcal.rounded())) kcal"
                        )
                        .foregroundStyle(Z1.dim)
                    }
                    .font(Z1Type.regular(11))
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - settings

    private var settingsBody: some View {
        Group {
            // Split into chunks on purpose: one 200-line ViewBuilder body sends
            // the Swift type checker into a memory spiral and the build gets
            // killed rather than failing with an error.
            VStack(alignment: .leading, spacing: 10) {
                unitsSettings
                displaySettings
                systemSettings
                Rectangle().fill(Z1.hairline).frame(height: 0.7)
                strideSettings
                Rectangle().fill(Z1.hairline).frame(height: 0.7)
                leavingSettings
            }
            .padding(.top, 8)
        }
    }

    private var unitsSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Units", selection: $viewModel.unitsImperial) {
                Text("Imperial").tag(true)
                Text("Metric").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)

            settingRow("Body weight") {
                TextField(
                    "weight",
                    value: viewModel.weightBinding,
                    format: .number.precision(.fractionLength(0...1))
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                Text(viewModel.weightUnitLabel).foregroundStyle(Z1.faint)
            }
            check("Use latest Apple Health weight", $viewModel.useHealthWeight)
            if let stamp = viewModel.healthWeightStamp {
                Text(stamp)
                    .font(Z1Type.regular(10))
                    .foregroundStyle(Z1.faint)
            } else if viewModel.useHealthWeight {
                Text("This Mac app cannot open HealthKit. Health → profile photo → Export All Health Data. Drop export.xml in iCloud Drive, Downloads, Desktop, or Application Support/Z1 WalkingPad. Weight is the latest BodyMass sample. Walks stay on this Mac.")
                    .font(Z1Type.regular(10))
                    .foregroundStyle(Z1.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingRow("Speed per −/+") {
                Picker("", selection: $viewModel.speedStep) {
                    Text("0.1").tag(0.1)
                    Text("0.2").tag(0.2)
                    Text("0.5").tag(0.5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 108)
            }
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow("Menu bar") {
                Picker("", selection: $viewModel.menuBarReadout) {
                    ForEach(MenuBarReadout.allCases) { readout in
                        Text(readout.label).tag(readout)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 118)
            }

            check("Show even when stopped", $viewModel.menuBarAlwaysVisible)
                .disabled(viewModel.menuBarReadout == .none)

                settingRow("Daily goal") {
                    Picker("", selection: $viewModel.goalIsSteps) {
                        Text("min").tag(false)
                        Text("steps").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 88)
                    if viewModel.goalIsSteps {
                        TextField("goal", value: $viewModel.dailyGoalSteps, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.mini)
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                    } else {
                        TextField("goal", value: $viewModel.dailyGoalMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.mini)
                            .frame(width: 40)
                            .multilineTextAlignment(.trailing)
                    }
                }
        }
    }

    private var systemSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Build \(viewModel.updater.currentShortVersion) (\(viewModel.updater.currentVersion))")
                .font(Z1Type.regular(10))
                .foregroundStyle(Z1.faint)
                .fixedSize(horizontal: false, vertical: true)
            check("Install updates automatically", $viewModel.autoUpdate)
            check("Show in Dock", $viewModel.showInDock)
            check("Start at login", $viewModel.launchAtLogin)
            if let message = viewModel.loginItemMessage {
                Text(message)
                    .font(Z1Type.regular(10))
                    .foregroundStyle(Z1.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            check("Notify when a walk is recorded", $viewModel.notificationsEnabled)
            HStack {
                check("Remind me on quiet days", $viewModel.remindersEnabled)
                Spacer()
                Picker("", selection: $viewModel.reminderGapHours) {
                    Text("2h").tag(2)
                    Text("3h").tag(3)
                    Text("4h").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 88)
                .disabled(!viewModel.remindersEnabled)
            }
        }
    }

    private var strideSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps from belt distance and speed. Pad step count and a fixed stride are ignored.")
                .font(Z1Type.regular(10))
                .foregroundStyle(Z1.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                check("Persist stats across sessions", $viewModel.persistStats)
                Spacer()
                Button("Clear") { viewModel.clearStatsTapped() }
                    .buttonStyle(HairlineButtonStyle())
                    .disabled(!viewModel.persistStats)
            }
        }
    }

    private var leavingSettings: some View {
        HStack {
            Text("Leaving").font(Z1Type.regular(11)).foregroundStyle(Z1.dim)
            Spacer()
            Button("Quit & sleep pad") { viewModel.stopBeltAndQuit() }
                .buttonStyle(HairlineButtonStyle())
                .help("Stop the belt, put the pad in standby, then quit")
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.dim)
            Spacer()
            content()
        }
        .font(Z1Type.regular(10))
    }

    private func check(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.checkbox)
            .font(Z1Type.regular(11))
            .foregroundStyle(Z1.dim)
    }
}
