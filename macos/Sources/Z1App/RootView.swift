import AppKit
import SwiftUI
import Z1Core

enum Page: String, CaseIterable, Identifiable {
    case now, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Now"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    /// ⌘1…⌘3, owned by the View menu.
    var shortcut: String {
        switch self {
        case .now: "1"
        case .history: "2"
        case .settings: "3"
        }
    }
}

/// Which page the window shows. Shared by the tab bar and the View menu.
@MainActor
@Observable
final class Navigation {
    private(set) var page: Page = PreviewHarness.page ?? .now

    func show(_ target: Page, model: TreadmillViewModel) {
        if target != .now { model.refreshHistoryFromDisk() }
        if page != target { page = target }
    }
}

/// The window's whole content.
///
/// One fixed frame. Pages swap inside it and snap: no crossfades, no
/// resizing, no slot that appears or disappears. The top line shares the
/// transparent title bar with the traffic lights.
struct RootView: View {
    /// Tall enough for Now on the same 12 pt rhythm top to bottom; the
    /// other pages scroll.
    static let size = CGSize(width: 320, height: 414)

    let model: TreadmillViewModel
    let navigation: Navigation
    /// Height of the title bar the content runs under.
    var titlebarHeight: CGFloat
    /// Where the traffic lights end, from the window's left edge.
    var titlebarLeading: CGFloat

    @AppStorage("z1.hasSeenIntro", store: TreadmillViewModel.settingsStore) private var hasSeenIntro = false

    var body: some View {
        VStack(spacing: 0) {
            TitleLine(model: model, page: hasSeenIntro ? navigation.page : nil)
                .padding(.leading, max(0, titlebarLeading - Theme.outer))
                .frame(height: titlebarHeight)
            if hasSeenIntro {
                Group {
                    switch navigation.page {
                    case .now: NowPage(model: model)
                    case .history: HistoryPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // A page that scrolls stops at the bar: nothing passes under
                // it, so the glass never sits on content.
                .clipped()
                TabBar(model: model, navigation: navigation)
            } else {
                IntroPage(globalShortcutAvailable: model.globalShortcutAvailable) { hasSeenIntro = true }
            }
        }
        .padding(.horizontal, Theme.outer)
        .padding(.bottom, Theme.inner)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.ground)
        .ignoresSafeArea()
        // Content swaps snap. Crossfades on state read as glitches.
        .transaction { $0.animation = nil }
        .tint(Theme.ink)
    }
}

// MARK: - Title line

/// The line beside the traffic lights: the pad's state on Now, the page's
/// name elsewhere. Text only; the title bar keeps it draggable.
private struct TitleLine: View {
    let model: TreadmillViewModel
    let page: Page?

    var body: some View {
        HStack(spacing: Theme.related) {
            switch page {
            case .now?:
                StatusDot(state: dotState)
                title(stateWord)
            case let other?:
                title(other.title)
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Theme.bodyMedium)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
    }

    /// A failed command outranks everything: "Walking" over a Stop that did
    /// not land would be the one lie this window must never tell.
    private var stateWord: String {
        let live = model.live
        if model.commandError != nil { return "Check pad" }
        if live.stopRequested || model.pendingVerb == "Stopping…" { return "Stopping" }
        if model.pendingVerb == "Starting…" { return "Starting" }
        if live.beltRunning { return "Walking" }
        if live.isConnecting { return "Connecting" }
        return live.isConnected ? "Ready" : "Offline"
    }

    private var dotState: StatusDot.Kind {
        let live = model.live
        if live.phase == .error || model.failedAttempts >= 3 || model.commandError != nil {
            return .trouble
        }
        if live.beltRunning { return .live }
        if live.isConnecting { return .connecting }
        return .idle
    }
}

// MARK: - Tab bar

/// The window's one piece of chrome: Liquid Glass on macOS 26, a flat
/// surface before it. Everything above it stays matte.
private struct TabBar: View {
    let model: TreadmillViewModel
    let navigation: Navigation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { target in
                let chosen = navigation.page == target
                Button {
                    navigation.show(target, model: model)
                } label: {
                    // Same weight chosen or not: a weight change would shift
                    // the label's width on every click.
                    Text(target.title)
                        .font(Theme.captionMedium)
                        .foregroundStyle(chosen ? Theme.ink : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if chosen { Capsule().fill(Theme.selection) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(target.title) (⌘\(target.shortcut))")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .chromeCapsule()
        .frame(height: 32)
        .padding(.top, Theme.inner)
    }
}

// MARK: - Now

/// What matters while walking, and nothing else: the speed, the control that
/// sets it, Start/Stop, this walk's numbers, and today against the goal. The
/// week lives on History.
struct NowPage: View {
    let model: TreadmillViewModel

    /// The speed the ruler points at. Tracks the pad's target (or the speed
    /// queued for Start) while untouched, and stops tracking while you drag
    /// or type, so telemetry cannot yank the control.
    @State private var speedDraft = 0.0
    @State private var isPickingSpeed = false
    @State private var isTypingSpeed = false
    @State private var typedSpeed = ""
    @FocusState private var speedFieldFocused: Bool

    var body: some View {
        VStack(spacing: Theme.inner) {
            hero
            primary
            LiveSlot(model: model)
            TodayCard(model: model)
        }
        .background { ArrowKeys(model: model).disabled(isTypingSpeed || !nudgeEnabled) }
        .onAppear {
            syncSpeedDraft()
            if let typed = PreviewHarness.typedSpeed {
                typedSpeed = Self.digits(typed)
                isTypingSpeed = true
            }
        }
        .onChange(of: model.targetDisplaySpeed) { _, _ in syncSpeedDraft() }
        .onChange(of: model.speedRange) { _, _ in syncSpeedDraft() }
        .onChange(of: nudgeEnabled) { _, enabled in
            guard !enabled else { return }
            isPickingSpeed = false
            closeSpeedField(commit: false)
        }
        .onChange(of: speedFieldFocused) { _, focused in
            // Clicking away mid-edit drops the half-typed value.
            guard !focused, isTypingSpeed else { return }
            closeSpeedField(commit: false)
        }
    }

    private var running: Bool { model.live.beltRunning }

    // MARK: hero

    private var hero: some View {
        Card(padding: 14) {
            VStack(spacing: 14) {
                speedReadout
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                HStack(alignment: .top, spacing: 10) {
                    IconButton(
                        symbol: "minus",
                        size: 40,
                        enabled: nudgeEnabled,
                        help: "Slower (← \(model.formatSpeed(0.1)), ↓ \(model.formatSpeed(0.5)))",
                        key: isTypingSpeed ? nil : .leftArrow,
                        action: model.speedDownTapped
                    )
                    .accessibilityLabel("Slower")
                    SpeedDial(
                        range: model.speedRange,
                        value: $speedDraft,
                        belt: running ? model.displaySpeed : nil,
                        enabled: nudgeEnabled,
                        format: model.formatSpeed,
                        onEditingChanged: { isPickingSpeed = $0 },
                        onCommit: commitSpeedDraft,
                        height: 40
                    )
                    IconButton(
                        symbol: "plus",
                        size: 40,
                        enabled: nudgeEnabled,
                        help: "Faster (→ \(model.formatSpeed(0.1)), ↑ \(model.formatSpeed(0.5)))",
                        key: isTypingSpeed ? nil : .rightArrow,
                        action: model.speedUpTapped
                    )
                    .accessibilityLabel("Faster")
                }
            }
        }
    }

    private var nudgeEnabled: Bool { model.isConnected && !model.busy }

    /// While walking the readout shows the speed last asked for until the belt
    /// gets there (the ruler's blue ticks show where the belt actually is); at
    /// a standstill it shows the belt: 0,0.
    private var readoutValue: Double {
        if isPickingSpeed { return speedDraft }
        return running ? (model.targetDisplaySpeed ?? model.displaySpeed) : model.displaySpeed
    }

    /// The digits sit dead centre; the unit hangs off their right edge, so
    /// the number, not the number-plus-unit, is what is centred.
    private var speedReadout: some View {
        panel
            .overlay(alignment: .bottomTrailing) {
                Text(model.speedUnitLabel)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize()
                    .alignmentGuide(.trailing) { $0[.leading] - 8 }
                    .alignmentGuide(.bottom) { $0[.bottom] + 1 }
            }
    }

    /// Lit only for a number it really has: the pad's reported speed, or one
    /// being picked. Connected with no telemetry yet, it stays dark rather
    /// than show a 0,0 nobody measured.
    private var panelLit: Bool {
        isTypingSpeed || isPickingSpeed || (model.isConnected && model.live.hasTelemetry)
    }

    private var panel: some View {
        ZStack {
            // Typing keeps the panel: digits land on the dot grid as they are
            // typed. The field itself only takes the keys; it is all but
            // transparent rather than hidden, because a hidden view cannot
            // hold focus.
            DotMatrixText(
                text: isTypingSpeed ? typedReadout : model.formatSpeed(readoutValue),
                dot: 5.6,
                gap: 2.3,
                lit: panelLit
            )
            .accessibilityHidden(true)
            if isTypingSpeed {
                TextField("Speed", text: $typedSpeed)
                    .textFieldStyle(.plain)
                    .opacity(0.011)
                    .frame(width: 1, height: 1)
                    .focused($speedFieldFocused)
                    .onAppear { speedFieldFocused = true }
                    .onChange(of: typedSpeed) { _, text in
                        let clean = Self.digits(text)
                        if clean != text { typedSpeed = clean }
                    }
                    .onSubmit { closeSpeedField(commit: true) }
                    .onExitCommand { closeSpeedField(commit: false) }
            }
        }
        .overlay(alignment: .bottom) {
            // The one sign of edit mode: a rule under the panel.
            if isTypingSpeed {
                Rectangle().fill(Theme.ink).frame(height: 1.5).offset(y: 6)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: beginSpeedEntry)
        .help("Click and type a speed: 3 then 5 is \(model.formatSpeed(3.5)). Return sets it, Esc cancels.")
        .accessibilityElement(children: isTypingSpeed ? .contain : .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(isTypingSpeed ? "Editing" : panelLit
            ? "\(model.formatSpeed(readoutValue)) \(model.speedUnitLabel)" : "Not available")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { beginSpeedEntry() }
    }

    private func beginSpeedEntry() {
        guard nudgeEnabled, !isTypingSpeed else { return }
        typedSpeed = ""
        isTypingSpeed = true
    }

    /// The typed speed on the panel's own template, one digit, the decimal
    /// separator, one digit, with dark cells for the digits still to come, so
    /// the panel never changes width.
    private var typedReadout: String {
        let typed = Array(typedSpeed)
        let separator = Locale.current.decimalSeparator == "," ? "," : "."
        return "\(typed.first.map(String.init) ?? "_")\(separator)\(typed.dropFirst().first.map(String.init) ?? "_")"
    }

    /// Up to two digits; the separator is implied, so "35" is 3.5.
    private static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(2))
    }

    private func closeSpeedField(commit: Bool) {
        let typed = typedSpeed.compactMap(\.wholeNumberValue)
        if commit, let whole = typed.first {
            speedDraft = Double(whole) + Double(typed.count > 1 ? typed[1] : 0) / 10
            commitSpeedDraft()
        }
        isTypingSpeed = false
        typedSpeed = ""
        syncSpeedDraft()
    }

    // MARK: primary

    /// One button, one verb. Disconnected it connects; connected it starts
    /// and stops. Space presses it.
    private var primary: some View {
        PrimaryButton(title: primaryTitle, height: 44, action: primaryAction)
            .keyboardShortcut(isTypingSpeed ? nil : KeyboardShortcut(.space, modifiers: []))
            .disabled(model.isConnecting || model.pendingVerb == "Stopping…"
                      || (model.busy && !running && !model.live.stopRequested && model.pendingVerb != "Starting…"))
            .help(model.isConnected
                ? (model.globalShortcutAvailable
                   ? "Start or stop the belt. Space here, \(GlobalHotKey.display) anywhere."
                   : "Start or stop the belt. Space works in this window; the global shortcut is unavailable.")
                : "Look for the pad now")
    }

    private var primaryTitle: String {
        // A pending Start can be cancelled before any motion telemetry arrives.
        if model.pendingVerb == "Starting…" { return "Stop" }
        if running && model.pendingVerb != "Stopping…" {
            return model.live.stopRequested ? "Stop Again" : "Stop"
        }
        if let verb = model.pendingVerb { return verb }
        if model.isConnecting { return "Connecting…" }
        if !model.isConnected { return "Connect" }
        if model.live.stopRequested { return "Stop Again" }
        return "Start"
    }

    private func primaryAction() {
        if model.isConnected {
            model.startStopTapped()
        } else {
            model.connectTapped()
        }
    }

    // MARK: speed plumbing

    private func syncSpeedDraft() {
        guard !isPickingSpeed, !isTypingSpeed else { return }
        speedDraft = model.targetDisplaySpeed ?? model.speedRange.lowerBound
    }

    private func commitSpeedDraft() {
        guard speedDraft.isFinite else { syncSpeedDraft(); return }
        let range = model.speedRange
        // The ruler already snaps display tenths while preserving exact
        // imperial endpoints; only the model snaps to the pad's km/h grid.
        speedDraft = min(max(speedDraft, range.lowerBound), range.upperBound)
        model.setSpeed(speedDraft)
    }
}

/// ↑ / ↓ move the speed half a unit. ← / → sit on the − / + buttons. These
/// buttons have no size and no look; they only carry the shortcuts.
private struct ArrowKeys: View {
    let model: TreadmillViewModel

    var body: some View {
        ZStack {
            Button("Faster by half", action: model.bigSpeedUpTapped)
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Slower by half", action: model.bigSpeedDownTapped)
                .keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Today

/// Today against the goal: ticks, the number, and the distance. One line
/// while walking is all the history the Now page needs. It reads the totals
/// at printed resolution, so it redraws about once a walk-minute rather than
/// once a second.
private struct TodayCard: View {
    let model: TreadmillViewModel

    var body: some View {
        let today = model.todayShown
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today")
                        .font(Theme.bodyMedium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: Theme.related)
                    Text(model.goalText(for: today))
                        .font(Theme.bodyMedium.monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("· \(model.formatDistance(today.distanceM))")
                        .font(Theme.body.monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                TickLine(progress: model.goalProgress(for: today), tint: Theme.accent)
                    .frame(height: 10)
                    .accessibilityLabel("Daily goal")
                    .accessibilityValue("\(Int((min(1, model.goalProgress(for: today)) * 100).rounded())) percent")
                if model.hasPendingSave(on: today.day) {
                    Text("Awaiting save. Your walk is kept for retry.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Live slot

/// Always 36 pt, whatever it holds, so nothing below it ever moves. While the
/// belt moves it holds this walk's time and distance, each in its own view so
/// only the one that changed redraws. A failed command takes it over.
/// Otherwise one quiet line about the connection.
private struct LiveSlot: View {
    let model: TreadmillViewModel

    var body: some View {
        Group {
            if let error = model.commandError {
                ErrorLine(model: model, message: error)
            } else if model.live.beltRunning {
                HStack(spacing: 0) {
                    LiveCell(model: model, kind: .elapsed)
                    LiveCell(model: model, kind: .distance)
                }
                .padding(.horizontal, 4)
            } else {
                StatusLine(model: model)
            }
        }
        .frame(height: 36)
    }
}

private struct LiveCell: View {
    enum Kind { case elapsed, distance }

    let model: TreadmillViewModel
    let kind: Kind

    var body: some View {
        let live = model.live
        switch kind {
        case .elapsed:
            StatCell(value: model.formatElapsed(live.elapsedS), label: "Time")
        case .distance:
            StatCell(value: model.formatDistance(live.distanceM), label: "Distance", alignment: .trailing)
        }
    }
}

/// A command that did not land, in the trouble colour, with one way out.
private struct ErrorLine: View {
    let model: TreadmillViewModel
    let message: String

    var body: some View {
        HStack(spacing: Theme.related) {
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(Theme.trouble)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message)
                .accessibilityLabel("Control failed: \(message)")
            Button { model.retryFailedCommand() } label: {
                Text("Retry")
                    .font(Theme.captionMedium)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .contentShape(Capsule())
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.pendingVerb != nil)
        }
        .padding(.horizontal, 4)
    }
}

/// One quiet line: what Start will do, or where the connection stands.
private struct StatusLine: View {
    let model: TreadmillViewModel

    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.dim)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
    }

    private var text: String {
        if model.isConnected {
            if let pending = model.pendingTargetDisplaySpeed {
                return "Starts at \(model.formatSpeed(pending)) \(model.speedUnitLabel)"
            }
            return model.globalShortcutAvailable
                ? "Space or \(GlobalHotKey.display) to start"
                : "Space to start. Global shortcut unavailable."
        }
        if model.failedAttempts >= 3 { return "Pad not found. Is the phone app closed?" }
        switch model.live.phase {
        case .scanning, .connecting: return "Looking for the pad…"
        case .error: return model.live.errorMessage ?? "Pad not found."
        default: return "Not connected"
        }
    }
}
