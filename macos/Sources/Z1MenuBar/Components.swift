import SwiftUI

// The small component set shared by name with DALI: Card, PrimaryButton,
// SecondaryButtonStyle, IconButton, StatusDot, StatCell, TickLine, ChipPicker,
// PillToggleStyle, SettingRow. Each is drawn from `Theme` and nothing else.

// MARK: - Card

/// A surface one step up from the ground: opaque-ish fill, one hairline.
/// `live` adds the blue underline glow that means "the belt is moving".
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.inner
    /// Only the two primary surfaces (speed, almanac) are glass. Everything
    /// else sits directly on the sky.
    var glass = true
    @ViewBuilder var content: Content

    var body: some View {
        if glass {
            let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            inner
                .background(shape.fill(Color.black.opacity(0.42)))
                .glass(shape)
        } else {
            inner
        }
    }

    private var inner: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// Full-width, 40 pt, surface fill, hairline edge. Live: the label stays
/// paper and a blue underline glows at the bottom edge — never a blue fill.
struct PrimaryButton: View {
    var title: String
    var live = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.bodyMedium)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(PrimaryButtonStyle(live: live))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var live = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, live: live)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let live: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(Theme.paper)
                // System glass only. Live = the one blue, as the system's own tint.
                .glass(Capsule(), interactive: enabled, tint: live ? Theme.accent.opacity(0.55) : nil)
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Theme.press, value: configuration.isPressed)
        }
    }
}

/// Text only: paper62, paper on hover.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.caption)
                .foregroundStyle(hovering && enabled ? Theme.paper : Theme.paper62)
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}

/// A 28 pt round control for − / + and similar.
struct IconButton: View {
    var symbol: String
    var enabled = true
    var help: String = ""
    /// Bare key (no modifiers) that presses it while the panel has focus.
    var key: KeyEquivalent?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.paper : Theme.paper38)
        .background(Circle().fill(Color.white.opacity(hovering && enabled ? 0.16 : 0.10)))
        .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: []) })
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Status

struct StatusDot: View {
    enum Kind { case live, idle, trouble, connecting }
    var state: Kind

    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 6, height: 6)
            // Pulse only while connecting: it is the one state where motion
            // carries information ("still trying").
            .opacity(state == .connecting && dim ? 0.4 : 1)
            .onAppear { restartPulse() }
            .onChange(of: state) { _, _ in restartPulse() }
    }

    private var colour: Color {
        switch state {
        case .live: Theme.accent
        case .idle, .connecting: Theme.paper38
        case .trouble: Theme.trouble
        }
    }

    private func restartPulse() {
        var off = Transaction()
        off.animation = nil
        withTransaction(off) { dim = false }
        guard state == .connecting, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// A number over its label. Estimated values say "est." in the label and are
/// never greyed: measured and modelled numbers get the same ink.
struct StatCell: View {
    var value: String
    var label: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            valueText
                .lineLimit(1)
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.paper38)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    /// "2.36 km" sets the unit smaller, so the number carries the weight.
    private var valueText: Text {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1].allSatisfy(\.isLetter) {
            return Text(parts[0]).font(Theme.number).foregroundStyle(Theme.paper)
                + Text(" " + parts[1]).font(Theme.caption).foregroundStyle(Theme.paper62)
        }
        return Text(value).font(Theme.number).foregroundStyle(Theme.paper)
    }
}

/// Progress as ticks: the app's one progress idiom.
struct TickLine: View {
    var progress: Double
    var count = 48
    var live = false

    var body: some View {
        Canvas { context, size in
            let pitch = size.width / CGFloat(count)
            let lit = Int((min(max(progress, 0), 1) * Double(count)).rounded(.down))
            let on = GraphicsContext.Shading.color(live ? Theme.accent : Theme.paper)
            let off = GraphicsContext.Shading.color(Theme.paper12)
            for i in 0..<count {
                let isOn = i < lit
                let h = isOn ? size.height : size.height * 0.5
                context.fill(
                    Path(CGRect(x: CGFloat(i) * pitch, y: (size.height - h) / 2, width: 1.25, height: h)),
                    with: isOn ? on : off
                )
            }
        }
    }
}

// MARK: - Choosers

/// A row of text chips; the chosen one sits on a raised pill.
struct ChipPicker<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(chosen ? Theme.captionMedium : Theme.caption)
                        .foregroundStyle(chosen ? Theme.paper : Theme.paper62)
                        .padding(.horizontal, compact ? 6 : 9)
                        .frame(height: 22)
                        .background {
                            if chosen { Capsule().fill(Color.white.opacity(0.16)) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Monochrome switch: the one-colour rule leaves no room for a blue toggle.
struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: Theme.related) {
                    configuration.label
                    Spacer(minLength: 4)
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(configuration.isOn ? Theme.paper : Color.white.opacity(0.18))
                        Circle()
                            .fill(configuration.isOn ? Theme.ink : Theme.paper62)
                            .padding(2)
                    }
                    .frame(width: 28, height: 16)
                    .animation(Theme.spring, value: configuration.isOn)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

// MARK: - Layout pieces

/// The 24 pt line every page starts with, so switching pages never moves
/// anything below it.
struct PageHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.related) {
            leading
            Spacer(minLength: Theme.related)
            trailing
        }
        .frame(height: 24)
    }
}

/// One line in a settings or records card: label left, control or value right.
struct SettingRow<Content: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.related) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.paper)
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.paper38)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.related)
            content
        }
        .frame(minHeight: 26)
    }
}

/// Hairline between rows inside a card.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
    }
}

/// Small caption above a card.
struct GroupLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.paper38)
            .padding(.leading, 4)
            .padding(.top, 4)
    }
}

/// A compact numeric field on a raised plate.
struct FieldPlate<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.edgeWidth))
    }
}
