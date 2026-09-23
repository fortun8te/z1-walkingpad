import AppKit
import SwiftUI
import Z1Core

/// The panel that hangs from the menu bar.
///
/// One fixed frame. Nothing inside it grows, shrinks or pushes: the old
/// popover grew History/Settings underneath itself and resized its own window
/// under the pointer, which is where most of the "jumping" came from. Now the
/// three secondary views are pages that swap inside the same rectangle, and
/// every slot on the main page reserves its height whether or not it has
/// something to say.
@MainActor
struct PanelView: View {
    static let size = NSSize(width: 312, height: 548)
    static let radius: CGFloat = 18

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
                bottomBar
            }
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            SkyField(
                intensity: viewModel.goalProgress ?? 0,
                weather: Self.freshWeather,
                kp: SpaceWeather.cachedKp() ?? 0
            )
        }
        .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
        )
        // Content swaps snap. No crossfades on state: they read as glitches.
        .transaction { $0.animation = nil }
        .environment(\.colorScheme, .dark)
        .onAppear { viewModel.checkForUpdate() }
    }

    /// Only a snapshot from the last two hours. Nothing fetches weather any
    /// more, so an old cached rain shower would otherwise rain forever.
    private static var freshWeather: WeatherSnapshot? {
        guard let cached = OpenMeteo.cached(),
              Date().timeIntervalSince(cached.fetchedAt) < 2 * 3_600
        else { return nil }
        return cached
    }

    // MARK: - bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            ForEach([Page.history, .records, .settings]) { target in
                Button {
                    page = page == target ? .now : target
                    if page != .now { viewModel.refreshHistoryFromDisk() }
                } label: {
                    Text(target.title)
                        .font(Z1Type.regular(12))
                        .foregroundStyle(page == target ? Z1.ink : Z1.dim)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(page == target ? Z1.ink : .clear)
                                .frame(height: 1)
                                .offset(y: 4)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if case .available = viewModel.updater.phase {
                Button("Update") { viewModel.installUpdate() }
                    .buttonStyle(HairlineButtonStyle())
                    .font(Z1Type.medium(11))
                    .disabled(viewModel.updater.isBusy)
                    .help("Install the new build and relaunch")
            }
            Button("Quit") { viewModel.quit() }
                .buttonStyle(.plain)
                .font(Z1Type.regular(12))
                .foregroundStyle(Z1.dim)
                .keyboardShortcut("q")
                .help("Quit and leave the belt exactly as it is")
        }
        .frame(height: 22)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Z1.hairline).frame(height: 0.7)
        }
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

    var body: some View {
        VStack(spacing: 10) {
            header
            hero
            dialRow
            actionButton
            liveSlot
            AlmanacCard(viewModel: viewModel)
        }
        .onAppear(perform: syncSpeedDraft)
        .onChange(of: viewModel.displaySpeed) { _, _ in syncSpeedDraft() }
        .onChange(of: viewModel.unitsImperial) { _, _ in syncSpeedDraft() }
        .onChange(of: speedFieldFocused) { _, focused in
            // Clicking away mid-edit: the field writes its half-typed value
            // into the draft as it goes, which then sat on the dial as if it
            // were the speed. Drop it and follow the pad again.
            guard !focused, isTypingSpeed else { return }
            isTypingSpeed = false
            resyncSpeedDraftAfterFieldCloses()
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isConnected ? Z1.live : (viewModel.isConnecting ? Z1.dim : Z1.faint))
                .frame(width: 6, height: 6)
            Text(viewModel.status.deviceName ?? "Walking pad")
                .font(Z1Type.medium(13))
                .foregroundStyle(Z1.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: viewModel.connectTapped) {
                Text(connectLabel)
                    .font(Z1Type.regular(11))
                    .frame(minWidth: 64)
            }
            .buttonStyle(HairlineButtonStyle())
            .disabled(viewModel.busy || viewModel.isConnecting)
        }
        .frame(height: 24)
    }

    private var connectLabel: String {
        if viewModel.isConnecting { return "Connecting" }
        return viewModel.isConnected ? "Disconnect" : "Connect"
    }

    // MARK: hero

    private var hero: some View {
        AuraCard(colour: Z1.live, active: viewModel.status.beltRunning, radius: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                if isTypingSpeed {
                    TextField("", value: $speedDraft, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.plain)
                        .font(Z1Type.light(32))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Z1.ink)
                        .frame(width: 92)
                        .focused($speedFieldFocused)
                        // Focus must be requested once the field exists;
                        // set in the same tap that creates it, it was dropped.
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
                        dot: 3.5,
                        gap: 1.7,
                        color: Z1.ink,
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
                    .font(Z1Type.regular(11))
                    .foregroundStyle(Z1.dim)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 66)
        }
    }

    private var speedText: String {
        String(format: "%.1f", isPickingSpeed ? speedDraft : viewModel.displaySpeed)
    }

    // MARK: dial

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
        .frame(height: 26)
    }

    private func nudge(_ symbol: String, action: @escaping () -> Void) -> some View {
        let live = viewModel.status.beltRunning && !viewModel.busy
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(live ? Z1.ink : Z1.faint)
        .background(Circle().strokeBorder(Z1.hairline, lineWidth: 0.7))
        .disabled(!live)
        .help(live ? "Nudge the speed" : "The pad only takes speed changes while the belt moves")
    }

    // MARK: start / stop

    private var actionButton: some View {
        Button(action: viewModel.startStopTapped) {
            Text(viewModel.status.beltRunning ? "Stop" : "Start")
                .font(Z1Type.medium(13))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(PanelButtonStyle(lit: viewModel.status.beltRunning))
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!viewModel.isConnected)
        .help("Start or stop the belt. Space does the same while this panel is open.")
    }

    // MARK: live slot

    /// Always 34 pt tall. While the belt moves it holds this walk's numbers;
    /// otherwise it holds the connection story. Never both, never empty.
    private var liveSlot: some View {
        Group {
            if viewModel.status.beltRunning {
                let st = viewModel.status
                HStack(spacing: 0) {
                    StatCell(value: viewModel.formatElapsed(st.elapsedS), label: "Walk")
                    StatCell(value: viewModel.formatDistance(st.distanceM), label: "Distance")
                    StatCell(value: st.steps.formatted(.number), label: "Steps est.")
                    StatCell(value: "\(Int(st.caloriesKcal.rounded()))", label: "kcal est.")
                }
            } else {
                HStack(spacing: 8) {
                    if viewModel.isConnecting {
                        ProgressView().controlSize(.mini).tint(Z1.dim)
                    }
                    Text(statusLine)
                        .font(Z1Type.regular(11))
                        .foregroundStyle(Z1.dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 34)
    }

    private var statusLine: String {
        if let error = viewModel.commandError { return error }
        if viewModel.isConnected {
            return "Ready. Start here, or on the remote."
        }
        if viewModel.failedAttempts >= 3 {
            return "Can't find the pad. Is it on, and is the phone app closed?"
        }
        switch viewModel.status.phase {
        case .scanning: return "Looking for the pad…"
        case .connecting: return "Connecting…"
        case .error: return viewModel.status.errorMessage ?? "No pad found."
        default: return "Not connected."
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

/// A number over its label. Measured and modelled values look the same;
/// the modelled ones say "est." instead of being greyed.
struct StatCell: View {
    var value: String
    var label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Z1Type.medium(15))
                .foregroundStyle(Z1.ink)
                .lineLimit(1)
            Text(label)
                .font(Z1Type.regular(10))
                .foregroundStyle(Z1.faint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The primary button: glass, edge-lit, blue edge while the belt runs.
struct PanelButtonStyle: ButtonStyle {
    var lit: Bool

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, lit: lit)
    }

    private struct PanelButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let lit: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Z1.ink)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.09 : 0.05))
                )
                .z1LiquidGlass(radius: 11)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            lit ? Z1.live.opacity(0.7) : Color.white.opacity(0.2),
                            lineWidth: 0.8
                        )
                )
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
                .onHover { hovering = $0 }
        }
    }
}
