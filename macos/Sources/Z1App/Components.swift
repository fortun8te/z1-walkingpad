import SwiftUI

// The small component set: Card, PrimaryButton, SecondaryButtonStyle,
// IconButton, StatusDot, StatCell, TickLine, ChipPicker, PillToggleStyle,
// SettingRow, RowDivider, GroupLabel, FieldPlate. Each is drawn from `Theme`
// and nothing else: flat fills and one hairline. The only light is the
// hero card edge-lit in blue while the belt moves.

// MARK: - Card

/// A surface one step off the ground, with one hairline.
///
/// `live` edge-lights it from below in the one blue: a still pool of light
/// at the bottom edge and a hairline that warms into it. It snaps on and off
/// with the belt and never moves.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.inner
    var live = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Theme.surface)
                    if live {
                        GeometryReader { proxy in
                            // A wide, shallow ellipse of light sitting on the
                            // bottom edge, not a tint over the whole card.
                            RadialGradient(
                                colors: [Theme.glow, Theme.glow.opacity(0)],
                                center: .bottom,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.5
                            )
                            .scaleEffect(x: 1, y: 0.42, anchor: .bottom)
                        }
                        .clipShape(shape)
                    }
                }
            }
            .overlay {
                if live {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Theme.hairline, Theme.litEdge],
                            startPoint: .center,
                            endPoint: .bottom
                        ),
                        lineWidth: Theme.edgeWidth
                    )
                } else {
                    shape.strokeBorder(Theme.hairline, lineWidth: Theme.edgeWidth)
                }
            }
    }
}

// MARK: - Buttons

/// Full-width, 40 pt, a surface pill with a hairline. One per page.
struct PrimaryButton: View {
    var title: String
    var height: CGFloat = 40
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(height > 40 ? Theme.emphasis : Theme.bodyMedium)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(.rect)
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.ink)
                .background(Capsule().fill(Theme.surface))
                .background(Capsule().fill(hovering && enabled ? Theme.wash : .clear))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: Theme.edgeWidth))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .animation(Theme.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Text only: dim, full ink on hover.
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
                .foregroundStyle(hovering && enabled ? Theme.ink : Theme.dim)
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}

/// A round control for − / + and similar; 28 pt unless asked bigger.
struct IconButton: View {
    var symbol: String
    var size: CGFloat = 28
    var enabled = true
    var help: String = ""
    /// Bare key (no modifiers) that presses it while the window is key.
    var key: KeyEquivalent?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size > 32 ? 15 : 11, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.ink : Theme.faint)
        .background(Circle().fill(hovering && enabled ? Theme.controlHover : Theme.control))
        .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: []) })
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Status

/// Six points of state. Blue only while the belt moves. Connecting is a ring,
/// not a pulse: nothing on screen animates on its own.
struct StatusDot: View {
    enum Kind { case live, idle, trouble, connecting }
    var state: Kind

    var body: some View {
        Group {
            switch state {
            case .live: Circle().fill(Theme.accent)
            case .idle: Circle().fill(Theme.faint)
            case .trouble: Circle().fill(Theme.trouble)
            case .connecting: Circle().strokeBorder(Theme.faint, lineWidth: 1.25)
            }
        }
        .frame(width: 6, height: 6)
    }
}

/// A number over its label. Estimated values say "est." in the label and are
/// never greyed: measured and modelled numbers get the same ink.
struct StatCell: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            valueText
                .lineLimit(1)
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "2.36 km" sets the unit smaller, so the number carries the weight.
    private var valueText: Text {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1].allSatisfy(\.isLetter) {
            return Text(parts[0]).font(Theme.number).foregroundStyle(Theme.ink)
                + Text(" " + parts[1]).font(Theme.caption).foregroundStyle(Theme.dim)
        }
        return Text(value).font(Theme.number).foregroundStyle(Theme.ink)
    }
}

/// Progress as ticks: the app's one progress idiom.
struct TickLine: View {
    var progress: Double
    var count = 48
    /// Lit-tick colour. Today's goal is progress, so it is blue; everything
    /// else stays ink.
    var tint: Color = Theme.ink

    var body: some View {
        Canvas { context, size in
            let pitch = size.width / CGFloat(count)
            let lit = Int((min(max(progress, 0), 1) * Double(count)).rounded(.down))
            let on = GraphicsContext.Shading.color(tint)
            let off = GraphicsContext.Shading.color(Theme.track)
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

/// A row of text chips; the chosen one sits on a pill.
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
                        .foregroundStyle(chosen ? Theme.ink : Theme.dim)
                        .padding(.horizontal, compact ? 6 : 9)
                        .frame(height: 22)
                        .background {
                            if chosen { Capsule().fill(Theme.selection) }
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
                            .fill(configuration.isOn ? Theme.ink : Theme.track)
                        Circle()
                            .fill(configuration.isOn ? Theme.surface : Theme.dim)
                            .padding(2)
                    }
                    .frame(width: 28, height: 16)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

// MARK: - Layout pieces

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
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.faint)
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
            .foregroundStyle(Theme.faint)
            .padding(.leading, 4)
            .padding(.top, 4)
    }
}

/// A compact numeric field on a plate.
struct FieldPlate<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline, lineWidth: Theme.edgeWidth))
    }
}
