import AppKit
import SwiftUI
import Z1Core

/// Everything that hangs from the menu bar.
///
/// One fixed frame. Pages swap inside it and snap — no crossfades, no
/// resizing, no slot that appears or disappears. Every row on the Now page
/// reserves its height whether or not it has something to say.
@MainActor
struct PanelView: View {
    static let size = NSSize(width: 320, height: 584)

    @ObservedObject var viewModel: TreadmillViewModel
    var close: () -> Void = {}

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
        var key: KeyEquivalent {
            switch self {
            case .now: "1"
            case .history: "2"
            case .records: "3"
            case .settings: "4"
            }
        }
    }

    @State private var page: Page = TreadmillViewModel.isPreview
        ? Page(rawValue: ProcessInfo.processInfo.environment["Z1_PREVIEW_PAGE"] ?? "") ?? .now
        : .now
    @AppStorage("z1.hasSeenIntro") private var hasSeenIntro = false

    var body: some View {
        VStack(spacing: 0) {
            if !hasSeenIntro {
                IntroPage { hasSeenIntro = true }
            } else {
                Group {
                    switch page {
                    case .now: NowPage(viewModel: viewModel)
                    case .history: HistoryPage(viewModel: viewModel)
                    case .records: RecordsPage(viewModel: viewModel)
                    case .settings: SettingsPage(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                tabBar
            }
        }
        .padding(.horizontal, Theme.outer)
        .padding(.top, Theme.outer)
        .padding(.bottom, Theme.inner)
        .frame(width: Self.size.width, height: Self.size.height)
        .background { PanelBackdrop(goalProgress: viewModel.goalProgress ?? 0) }
        .background(alignment: .topLeading) { quitShortcut }
        // Content swaps snap. Crossfades on state read as glitches.
        .transaction { $0.animation = nil }
        .environment(\.colorScheme, .dark)
        .tint(Theme.paper)
    }

    /// ⌘Q works on every page, not only where a Quit button is visible.
    private var quitShortcut: some View {
        Button("Quit") { viewModel.quit() }
            .keyboardShortcut("q")
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: tab bar

    private var tabBar: some View {
        HStack(spacing: Theme.related) {
            HStack(spacing: 2) {
                ForEach(Page.allCases) { target in
                    let chosen = page == target
                    Button {
                        page = target
                        if target != .now { viewModel.refreshHistoryFromDisk() }
                    } label: {
                        Text(target.title)
                            .font(chosen ? Theme.captionMedium : Theme.caption)
                            .foregroundStyle(chosen ? Theme.paper : Theme.paper62)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background {
                                if chosen { Capsule().fill(Color.white.opacity(0.16)) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(target.key, modifiers: .command)
                    .help("\(target.title) (⌘\(String(target.key.character)))")
                }
            }
            .padding(3)
            .glass(Capsule())
            if case .available = viewModel.updater.phase {
                Button("Update") { viewModel.installUpdate() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(viewModel.updater.isBusy)
                    .help("Install the new build and relaunch")
            }
        }
        .frame(height: 32)
        .padding(.top, Theme.inner)
    }
}

/// The ground under the panel: the sky outside, right now.
struct PanelBackdrop: View {
    var goalProgress: Double

    var body: some View {
        SkyBackdrop(goalProgress: goalProgress)
            .background(Theme.ink)
    }
}

// MARK: - Now

@MainActor
struct NowPage: View {
    @ObservedObject var viewModel: TreadmillViewModel

    /// The speed the dial shows. Tracks the pad while untouched and stops
    /// tracking while you drag or type, so telemetry cannot yank the control.
    @State private var speedDraft = 0.0
    @State private var isPickingSpeed = false
    @State private var isTypingSpeed = false
    @FocusState private var speedFieldFocused: Bool

    private var running: Bool { viewModel.status.beltRunning }

    var body: some View {
        VStack(spacing: Theme.inner) {
            header
            GlassGroup(spacing: Theme.inner) {
                VStack(spacing: Theme.inner) {
                    hero
                    primary
                }
            }
            liveSlot
                .padding(.bottom, 4)
            AlmanacCard(viewModel: viewModel)
        }
        .onAppear(perform: syncSpeedDraft)
        .onChange(of: viewModel.displaySpeed) { _, _ in syncSpeedDraft() }
        .onChange(of: viewModel.unitsImperial) { _, _ in syncSpeedDraft() }
        .onChange(of: speedFieldFocused) { _, focused in
            // Clicking away mid-edit: drop the half-typed value and follow
            // the pad again.
            guard !focused, isTypingSpeed else { return }
            isTypingSpeed = false
            resyncSpeedDraftAfterFieldCloses()
        }
    }

    // MARK: header

    private var header: some View {
        PageHeader {
            StatusDot(state: dotState)
            Text(running ? "Walking" : viewModel.isConnecting ? "Connecting" : viewModel.isConnected ? "Ready" : "Offline")
                .font(Theme.bodyMedium)
                .foregroundStyle(Theme.paper)
                .lineLimit(1)
        } trailing: {
            EmptyView()
        }
    }

    private var dotState: StatusDot.Kind {
        if running { return .live }
        if viewModel.isConnecting { return .connecting }
        if viewModel.status.phase == .error || viewModel.failedAttempts >= 3 || viewModel.commandError != nil {
            return .trouble
        }
        return .idle
    }

    // MARK: hero

    private var hero: some View {
        Card(padding: 14) {
            VStack(spacing: 14) {
                speedReadout
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                HStack(spacing: 10) {
                    IconButton(
                        symbol: "minus",
                        enabled: nudgeEnabled,
                        help: nudgeHelp,
                        key: .leftArrow,
                        action: viewModel.speedDownTapped
                    )
                    SpeedDial(
                        range: viewModel.speedRange,
                        value: $speedDraft,
                        enabled: viewModel.isConnected,
                        onEditingChanged: { isPickingSpeed = $0 },
                        onCommit: commitSpeedDraft,
                        height: 28,
                        live: running
                    )
                    IconButton(
                        symbol: "plus",
                        enabled: nudgeEnabled,
                        help: nudgeHelp,
                        key: .rightArrow,
                        action: viewModel.speedUpTapped
                    )
                }
                .frame(height: 28)
            }
        }
    }

    private var nudgeEnabled: Bool { running && !viewModel.busy }
    private var nudgeHelp: String {
        running ? "Nudge the speed (← →)" : "The pad takes speed changes only while the belt moves"
    }

    @ViewBuilder
    private var speedReadout: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isTypingSpeed {
                TextField("", value: $speedDraft, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 36, weight: .light).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.paper)
                    .frame(width: 96, height: 44)
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
                    text: speedText,
                    dot: 4.4,
                    gap: 1.9,
                    color: Theme.paper,
                    lit: viewModel.isConnected
                )
                .contentShape(.rect)
                .onTapGesture {
                    guard viewModel.isConnected else { return }
                    isTypingSpeed = true
                }
                .help("Click to type an exact speed")
            }
            Text(viewModel.speedUnitLabel)
                .font(Theme.caption)
                .foregroundStyle(Theme.paper38)
                .padding(.bottom, 1)
        }
    }

    private var speedText: String {
        String(format: "%.1f", isPickingSpeed ? speedDraft : viewModel.displaySpeed)
    }

    // MARK: primary

    /// One button, one verb. Disconnected it connects; connected it starts
    /// and stops. Space presses it.
    private var primary: some View {
        PrimaryButton(title: primaryTitle, live: running, action: primaryAction)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(viewModel.busy || viewModel.isConnecting)
            .help(viewModel.isConnected
                ? "Start or stop the belt. Space here, \(GlobalHotKey.display) anywhere."
                : "Look for the pad now")
    }

    private var primaryTitle: String {
        if let verb = viewModel.pendingVerb { return verb }
        if viewModel.isConnecting { return "Connecting…" }
        if !viewModel.isConnected { return "Connect" }
        return running ? "Stop" : "Start"
    }

    private func primaryAction() {
        if viewModel.isConnected {
            viewModel.startStopTapped()
        } else {
            viewModel.connectTapped()
        }
    }

    // MARK: live slot

    /// Always 36 pt. While the belt moves it holds this walk's numbers;
    /// otherwise one line about the connection. Never both, never empty.
    private var liveSlot: some View {
        Group {
            if running {
                let st = viewModel.status
                HStack(spacing: 0) {
                    StatCell(value: viewModel.formatElapsed(st.elapsedS), label: "Walk")
                    StatCell(value: viewModel.formatDistance(st.distanceM), label: "Distance")
                    StatCell(value: st.steps.formatted(.number), label: "Steps est.")
                    StatCell(value: "\(Int(st.caloriesKcal.rounded()))", label: "kcal est.")
                }
                .padding(.horizontal, 4)
            } else {
                Text(statusLine)
                    .font(Theme.caption)
                    .foregroundStyle(viewModel.commandError == nil ? Theme.paper62 : Theme.trouble)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .frame(height: 36)
    }

    /// Silent when all is well. Speaks only while connecting or when wrong.
    private var statusLine: String {
        if let error = viewModel.commandError { return error }
        if viewModel.isConnected {
            if let pending = viewModel.pendingTargetDisplaySpeed {
                return String(format: "Starts at %.1f %@", pending, viewModel.speedUnitLabel)
            }
            return ""
        }
        if viewModel.failedAttempts >= 3 { return "Pad not found. Is the phone app closed?" }
        switch viewModel.status.phase {
        case .scanning, .connecting: return "Looking for the pad…"
        case .error: return viewModel.status.errorMessage ?? "Pad not found."
        default: return "Not connected"
        }
    }

    // MARK: speed plumbing

    private func syncSpeedDraft() {
        guard !isPickingSpeed, !speedFieldFocused else { return }
        let live = viewModel.displaySpeed
        speedDraft = live > 0
            ? live
            : (viewModel.pendingTargetDisplaySpeed ?? viewModel.speedRange.lowerBound)
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
        let range = viewModel.speedRange
        let clamped = min(max(speedDraft, range.lowerBound), range.upperBound)
        speedDraft = (clamped * 10).rounded() / 10
        viewModel.setSpeed(speedDraft)
    }
}

extension TreadmillViewModel {
    /// The panel just opened: look for a new build (local feed, cheap).
    func panelDidOpen() {
        guard !Self.isPreview else { return }
        checkForUpdate()
    }
}
