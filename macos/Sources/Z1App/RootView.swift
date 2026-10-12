import AppKit
import SwiftUI
import Z1Core

enum Page: String, CaseIterable, Identifiable {
    case now, history, records, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Now"
        case .history: "History"
        case .records: "Records"
        case .settings: "Settings"
        }
    }

    /// ⌘1…⌘4, owned by the View menu.
    var shortcut: String {
        switch self {
        case .now: "1"
        case .history: "2"
        case .records: "3"
        case .settings: "4"
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
    static let size = CGSize(width: 320, height: 432)

    let model: TreadmillViewModel
    let navigation: Navigation
    /// Height of the title bar the content runs under.
    var titlebarHeight: CGFloat
    /// Where the traffic lights end, from the window's left edge.
    var titlebarLeading: CGFloat

    @AppStorage("z1.hasSeenIntro") private var hasSeenIntro = false

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
                    case .records: RecordsPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                TabBar(model: model, navigation: navigation)
            } else {
                IntroPage { hasSeenIntro = true }
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
            case .records?:
                title("Records")
                Spacer(minLength: Theme.related)
                let hs = model.highScores
                if hs.totalWalks > 0 {
                    Text("\(hs.totalWalks) walks · \(model.formatDistance(hs.totalDistanceM))")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
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

    private var stateWord: String {
        let live = model.live
        if live.beltRunning { return "Walking" }
        if live.isConnecting { return "Connecting" }
        return live.isConnected ? "Ready" : "Offline"
    }

    private var dotState: StatusDot.Kind {
        let live = model.live
        if live.beltRunning { return .live }
        if live.isConnecting { return .connecting }
        if live.phase == .error || model.failedAttempts >= 3 || model.commandError != nil {
            return .trouble
        }
        return .idle
    }
}

// MARK: - Tab bar

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
                    Text(target.title)
                        .font(chosen ? Theme.captionMedium : Theme.caption)
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
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: Theme.edgeWidth))
        .frame(height: 32)
        .padding(.top, Theme.inner)
    }
}

// MARK: - Now

/// What matters while walking, and nothing else: the speed, the control that
/// sets it, Start/Stop, this walk's numbers, and today against the goal. The
/// almanac lives on History.
struct NowPage: View {
    let model: TreadmillViewModel

    /// The speed the ruler shows. Tracks the pad (or the speed queued for
    /// Start) while untouched, and stops tracking while you drag or type, so
    /// telemetry cannot yank the control.
    @State private var speedDraft = 0.0
    @State private var isPickingSpeed = false
    @State private var isTypingSpeed = false
    @FocusState private var speedFieldFocused: Bool

    var body: some View {
        VStack(spacing: Theme.inner) {
            hero
            primary
            LiveSlot(model: model)
            TodayCard(model: model)
        }
        .background { ArrowKeys(model: model) }
        .onAppear(perform: syncSpeedDraft)
        .onChange(of: model.displaySpeed) { _, _ in syncSpeedDraft() }
        .onChange(of: model.pendingTargetKmh) { _, _ in syncSpeedDraft() }
        .onChange(of: model.unitsImperial) { _, _ in syncSpeedDraft() }
        .onChange(of: speedFieldFocused) { _, focused in
            // Clicking away mid-edit: drop the half-typed value and follow
            // the pad again.
            guard !focused, isTypingSpeed else { return }
            isTypingSpeed = false
            resyncSpeedDraftAfterFieldCloses()
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
                        help: "Slower (← 0.1, ↓ 0.5)",
                        key: .leftArrow,
                        action: model.speedDownTapped
                    )
                    SpeedDial(
                        range: model.speedRange,
                        value: $speedDraft,
                        enabled: model.isConnected,
                        onEditingChanged: { isPickingSpeed = $0 },
                        onCommit: commitSpeedDraft,
                        height: 40,
                        live: running
                    )
                    IconButton(
                        symbol: "plus",
                        size: 40,
                        enabled: nudgeEnabled,
                        help: "Faster (→ 0.1, ↑ 0.5)",
                        key: .rightArrow,
                        action: model.speedUpTapped
                    )
                }
            }
        }
    }

    private var nudgeEnabled: Bool { model.isConnected && !model.busy }

    @ViewBuilder
    private var speedReadout: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isTypingSpeed {
                TextField("", value: $speedDraft, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 44, weight: .light).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 120, height: 56)
                    .focused($speedFieldFocused)
                    // Focus must be requested once the field exists.
                    .onAppear { speedFieldFocused = true }
                    .onSubmit {
                        commitSpeedDraft()
                        isTypingSpeed = false
                    }
                    .onExitCommand {
                        isTypingSpeed = false
                        resyncSpeedDraftAfterFieldCloses()
                    }
            } else {
                DotMatrixText(
                    text: String(format: "%.1f", isPickingSpeed ? speedDraft : model.displaySpeed),
                    dot: 5.6,
                    gap: 2.3,
                    lit: model.isConnected
                )
                .contentShape(.rect)
                .onTapGesture {
                    guard model.isConnected else { return }
                    isTypingSpeed = true
                }
                .help("Click to type an exact speed")
            }
            Text(model.speedUnitLabel)
                .font(Theme.caption)
                .foregroundStyle(Theme.faint)
                .padding(.bottom, 2)
        }
    }

    // MARK: primary

    /// One button, one verb. Disconnected it connects; connected it starts
    /// and stops. Space presses it.
    private var primary: some View {
        PrimaryButton(title: primaryTitle, height: 44, action: primaryAction)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.busy || model.isConnecting)
            .help(model.isConnected
                ? "Start or stop the belt. Space here, \(GlobalHotKey.display) anywhere."
                : "Look for the pad now")
    }

    private var primaryTitle: String {
        if let verb = model.pendingVerb { return verb }
        if model.isConnecting { return "Connecting…" }
        if !model.isConnected { return "Connect" }
        return running ? "Stop" : "Start"
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
        guard !isPickingSpeed, !speedFieldFocused else { return }
        speedDraft = model.targetDisplaySpeed ?? model.speedRange.lowerBound
    }

    /// The field flushes its text into the draft while it is torn down, so
    /// resync on the next turn, after that write.
    private func resyncSpeedDraftAfterFieldCloses() {
        DispatchQueue.main.async {
            guard !isTypingSpeed else { return }
            syncSpeedDraft()
        }
    }

    private func commitSpeedDraft() {
        let range = model.speedRange
        let clamped = min(max(speedDraft, range.lowerBound), range.upperBound)
        speedDraft = (clamped * 10).rounded() / 10
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
/// while walking is all the history the Now page needs.
private struct TodayCard: View {
    let model: TreadmillViewModel

    var body: some View {
        let today = model.today
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
            }
        }
    }
}

// MARK: - Live slot

/// Always 36 pt. While the belt moves it holds this walk's numbers, each in
/// its own view so only the one that changed redraws; otherwise one line
/// about the connection. Never both, never empty of meaning.
private struct LiveSlot: View {
    let model: TreadmillViewModel

    var body: some View {
        Group {
            if model.live.beltRunning {
                HStack(spacing: 0) {
                    LiveCell(model: model, kind: .elapsed)
                    LiveCell(model: model, kind: .distance)
                    LiveCell(model: model, kind: .steps)
                    LiveCell(model: model, kind: .kcal)
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
    enum Kind { case elapsed, distance, steps, kcal }

    let model: TreadmillViewModel
    let kind: Kind

    var body: some View {
        let live = model.live
        switch kind {
        case .elapsed:
            StatCell(value: model.formatElapsed(live.elapsedS), label: "Walk")
        case .distance:
            StatCell(value: model.formatDistance(live.distanceM), label: "Distance")
        case .steps:
            StatCell(value: live.steps.formatted(.number), label: "Steps est.")
        case .kcal:
            StatCell(value: "\(Int(live.caloriesKcal.rounded()))", label: "kcal est.")
        }
    }
}

/// Silent when all is well. Speaks only while connecting or when wrong.
private struct StatusLine: View {
    let model: TreadmillViewModel

    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(model.commandError == nil ? Theme.dim : Theme.trouble)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var text: String {
        if let error = model.commandError { return error }
        if model.isConnected {
            if let pending = model.pendingTargetDisplaySpeed {
                return String(format: "Starts at %.1f %@", pending, model.speedUnitLabel)
            }
            return ""
        }
        if model.failedAttempts >= 3 { return "Pad not found. Is the phone app closed?" }
        switch model.live.phase {
        case .scanning, .connecting: return "Looking for the pad…"
        case .error: return model.live.errorMessage ?? "Pad not found."
        default: return "Not connected"
        }
    }
}
