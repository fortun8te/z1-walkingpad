import AppKit
import SwiftUI

/// Design tokens shared with DALI (see the ecosystem spec): near-black ground,
/// one surface step up, one hairline, one blue. Blue means one thing — the
/// belt is moving. Amber means trouble. Nothing else on screen is coloured.
enum Theme {
    // MARK: colour

    static let ink = Color(hex: 0x0B0C0E)
    static let surface = Color(hex: 0x141518)
    static let raised = Color(hex: 0x1B1C20)

    static let paper = Color(hex: 0xF4F5F7)
    static let paper62 = paper.opacity(0.62)
    static let paper38 = paper.opacity(0.38)
    /// Tracks, unlit ticks, empty bars.
    static let paper12 = paper.opacity(0.12)
    static let paper06 = paper.opacity(0.06)

    static let hairline = Color.white.opacity(0.08)
    static let hairlineLit = Color.white.opacity(0.14)

    static let accent = Color(hex: 0x4C8DFF)
    static let trouble = Color(hex: 0xF5A524)

    // MARK: geometry (8-pt grid)

    static let outer: CGFloat = 16
    static let inner: CGFloat = 12
    static let related: CGFloat = 8
    static let group: CGFloat = 16

    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
    static let edgeWidth: CGFloat = 0.75

    // MARK: type — SF Pro, sentence case, no tracking

    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let emphasis = Font.system(size: 15, weight: .semibold)
    static let section = Font.system(size: 22, weight: .semibold)
    /// Live and summary numbers.
    static let number = Font.system(size: 15, weight: .medium).monospacedDigit()

    // MARK: motion

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let fade = Animation.easeOut(duration: 0.16)
    static let press = Animation.easeOut(duration: 0.12)
}

/// Names older files (and the sky) still use. Same values as `Theme`.
enum Z1 {
    static let live = Theme.accent
    static let ink = Theme.paper
    static let dim = Theme.paper62
    static let faint = Theme.paper38
    static let unlit = Theme.paper06
    static let hairline = Theme.hairline
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Glass

/// Native glass with a restrained dark tint. It stays translucent over the
/// localized sky light and keeps the controls readable as the weather shifts.
extension View {
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, clear: Bool = false, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glassKind(clear: clear, interactive: interactive, tint: tint), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @available(macOS 26.0, *)
    private static func glassKind(clear: Bool, interactive: Bool, tint: Color?) -> Glass {
        var glass: Glass = clear ? .clear : .regular
        glass = glass.tint(tint ?? Color.black.opacity(clear ? 0.20 : 0.60))
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Groups neighbouring glass so it samples the backdrop once and melds.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The one "effect": a hairline that catches a little light on its top edge.
struct EdgeStroke: View {
    var radius: CGFloat
    var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(lit ? 0.22 : 0.14),
                        Color.white.opacity(lit ? 0.10 : 0.05),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: Theme.edgeWidth
            )
            .allowsHitTesting(false)
    }
}
