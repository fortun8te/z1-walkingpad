import AppKit
import SwiftUI

// The app's two moments of personality, and nothing else: the Now card's
// bloom and Start's glossy pill. Everything else stays flat and quiet.
//
// The halftone grit is drawn once and never moves. The gradient under it
// drifts very slowly on a low-rate TimelineView: slower at rest, a little
// livelier while walking, and a touch faster with belt speed. The timeline
// pauses when the window is hidden, covered or minimised, and stops for
// Reduce Motion and for the solid fallback. Every input is a small Equatable
// value, so the 1 Hz time/distance updates around it do not redraw the bloom.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Bloom {
    /// The card's base: neutral black, in light mode too.
    static let base = Color(hex: 0x000000)
    /// Deep blue: the middle of the bloom, and the whole card when
    /// Reduce Transparency or Increase Contrast is on.
    static let deep = Color(hex: 0x1E3A8A)
    static let periwinkle = Color(hex: 0x7FA6FF)
    static let rim = Color(hex: 0xC9DAFF)

    /// The slow gradient drift. Off: measured at 6.5% of a core while walking
    /// (the baseline is 0.12%), too costly until it is reworked. The code path
    /// stays so it can be turned back on; the bloom is static meanwhile.
    static let driftEnabled = false

    static let radius: CGFloat = 22
    /// Share of the card's height the bloom rises through.
    static let rise: CGFloat = 0.36
    /// Halftone strength: inside the 3 to 6% band, static.
    static let gritOpacity: Double = 0.055
    static let gritPitch: CGFloat = 3

    /// Text on the lit pill.
    static let pillInk = Color(hex: 0x0A2A66)
}

/// True when the system asks for fewer effects: no gradient, no grit, one
/// solid colour that keeps white type well above 7:1.
@MainActor
struct SolidFallback {
    var reduceTransparency: Bool
    var increasedContrast: Bool

    var isOn: Bool {
        let forced = PreviewHarness.forcesSolidCard
        return reduceTransparency || increasedContrast || forced
    }
}

// MARK: - Signature card

/// A black card with a blue bloom rising from its bottom edge. Its content is
/// always light on dark, so the whole card renders in the dark appearance
/// even in a light window.
struct SignatureCard<Content: View>: View {
    var padding = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    /// 0 at rest; 1 and up while the belt moves (the belt's speed, rounded).
    var motionTier = 0
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var windowVisible = true

    var body: some View {
        let solid = SolidFallback(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased).isOn
        let shape = RoundedRectangle(cornerRadius: Bloom.radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                BloomBackground(
                    solid: solid,
                    motion: BloomMotion(tier: motionTier, animated: Bloom.driftEnabled && !reduceMotion && windowVisible && !PreviewHarness.freezesMotion)
                )
                .equatable()
            }
            .background(WindowVisibilityProbe(visible: $windowVisible))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(solid ? 0.28 : 0.10), lineWidth: Theme.edgeWidth))
            .environment(\.colorScheme, .dark)
    }
}

/// How the bloom moves. `tier` is 0 at rest and the belt's speed (rounded to
/// km/h, at least 1) while walking. `animated` is false when the window is not
/// visible or Reduce Motion is on.
struct BloomMotion: Equatable {
    var tier: Int
    var animated: Bool

    /// Seconds for one slow loop: 20 at rest, about 11 walking, down to 6.
    var period: Double { tier == 0 ? 20 : max(6, 12 - Double(tier) * 0.9) }
    /// How far things move, 0...1. Always small.
    var amplitude: Double { tier == 0 ? 0.45 : min(1, 0.7 + Double(tier) * 0.05) }
    /// Frames per second. Low on purpose: this is drift, not animation.
    var frameInterval: Double { tier == 0 ? 1.0 / 8 : 1.0 / 12 }
}

/// Black, then deep blue, then a periwinkle rim at the bottom edge, with a
/// fine halftone inside the bloom only. The gradient drifts; the grit is
/// static.
struct BloomBackground: View, Equatable {
    var solid: Bool
    var motion: BloomMotion

    @State private var clock = DriftClock()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.solid == rhs.solid && lhs.motion == rhs.motion }

    var body: some View {
        if solid {
            Bloom.deep
        } else {
            ZStack {
                if motion.animated {
                    TimelineView(.animation(minimumInterval: motion.frameInterval)) { timeline in
                        let phase = clock.advance(to: timeline.date, period: motion.period)
                        Canvas { context, size in
                            Self.drawGradient(&context, size: size, phase: phase, amplitude: motion.amplitude)
                        }
                    }
                } else {
                    Canvas { context, size in
                        Self.drawGradient(&context, size: size, phase: clock.frozenPhase, amplitude: motion.amplitude)
                    }
                }
                BloomGrit().equatable()
            }
        }
    }

    private static let ramp = Gradient(stops: [
        .init(color: Bloom.base, location: 0),
        .init(color: Color(hex: 0x070D24), location: 0.18),
        .init(color: Color(hex: 0x0F1E52), location: 0.42),
        .init(color: Bloom.deep, location: 0.68),
        .init(color: Color(hex: 0x4A70D0), location: 0.86),
        .init(color: Bloom.periwinkle, location: 0.95),
        .init(color: Bloom.rim, location: 1),
    ])

    /// The gradient and its swell. `phase` is in radians and only ever nudges
    /// the bloom's height by a few percent, slides the swell sideways and
    /// breathes its strength; at phase 0 it is the resting picture.
    static func drawGradient(_ context: inout GraphicsContext, size: CGSize, phase: Double, amplitude: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Bloom.base))

        let rest = size.height * Bloom.rise
        let bloomHeight = rest * (1 + 0.06 * amplitude * sin(phase))
        let top = size.height - bloomHeight
        context.fill(
            Path(CGRect(x: 0, y: top, width: size.width, height: bloomHeight)),
            with: .linearGradient(ramp, startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height))
        )

        // A wider swell low in the rim, so the bloom reads as light pooling.
        let centre = size.width * (0.5 + 0.2 * amplitude * sin(phase * 0.6 + 1.2))
        let strength = 1 + 0.22 * amplitude * sin(phase * 1.3 + 0.4)
        var swell = context
        swell.clip(to: Path(CGRect(x: 0, y: top, width: size.width, height: bloomHeight)))
        swell.translateBy(x: centre, y: size.height)
        swell.scaleBy(x: 1, y: bloomHeight / (size.width * 0.5) * 0.95)
        let tint = Color(hex: 0x3F6FE8)
        swell.fill(
            Path(CGRect(x: -size.width, y: -size.width, width: size.width * 2, height: size.width * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: tint.opacity(min(1, 0.42 * strength)), location: 0),
                    .init(color: tint.opacity(0.16 * strength), location: 0.55),
                    .init(color: tint.opacity(0), location: 0.9),
                ]),
                center: .zero, startRadius: 0, endRadius: size.width * 0.5
            )
        )
    }
}

/// Integrates the drift phase, so a change of period (the belt starting or
/// speeding up) bends the motion instead of jumping it. A plain reference
/// type held in @State; only the timeline's main-actor closure touches it.
@MainActor
final class DriftClock {
    private var phase = 0.0
    private var last: Date?
    /// Where a paused or reduced-motion bloom rests: the clean picture.
    let frozenPhase = 0.0

    func advance(to date: Date, period: Double) -> Double {
        defer { last = date }
        guard let last else { return phase }
        // A long gap (the timeline was paused) is not motion to catch up on.
        let dt = min(max(date.timeIntervalSince(last), 0), 0.5)
        phase += dt * 2 * .pi / period
        if phase > 2 * .pi * 1000 { phase = phase.truncatingRemainder(dividingBy: 2 * .pi) }
        return phase
    }
}

/// The static halftone: drawn once, never redrawn.
struct BloomGrit: View, Equatable {
    var body: some View {
        Canvas { context, size in Self.draw(&context, size: size) }
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize) {
        let bloomHeight = size.height * Bloom.rise
        let top = size.height - bloomHeight
        // Halftone: a regular dot grid whose dots swell toward the rim, the
        // way a printed tint does. White on the dark part, navy on the pale
        // rim, never more than a few percent, and fading in from nothing so
        // the bloom has no visible top edge.
        let pitch = Bloom.gritPitch
        let fadeBands: [CGFloat] = [0.3, 0.6, 1.0]
        var light = Array(repeating: Path(), count: fadeBands.count)
        var dark = Path()
        var row = 0
        var y = top
        while y < size.height {
            let u = min(max((y - top) / max(bloomHeight, 1), 0), 1)
            let band = u < 0.12 ? 0 : (u < 0.26 ? 1 : 2)
            let radius = pitch * (0.16 + 0.34 * u)
            let stagger: CGFloat = row.isMultiple(of: 2) ? 0 : pitch / 2
            var x = stagger
            while x < size.width {
                let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                if u < 0.9 { light[band].addEllipse(in: dot) } else { dark.addEllipse(in: dot) }
                x += pitch
            }
            y += pitch
            row += 1
        }
        for (band, path) in light.enumerated() {
            context.fill(path, with: .color(.white.opacity(Bloom.gritOpacity * fadeBands[band])))
        }
        context.fill(dark, with: .color(Color(hex: 0x0A1A55).opacity(Bloom.gritOpacity + 0.01)))
    }
}

// MARK: - Window visibility

/// Tells the card whether anyone can see it, so its timeline can pause when
/// the window is minimised, hidden, on another Space or fully covered.
struct WindowVisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.report = { visible in
            DispatchQueue.main.async { if self.visible != visible { self.visible = visible } }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.report = { visible in
            DispatchQueue.main.async { if self.visible != visible { self.visible = visible } }
        }
    }

    private final class ProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var report: (Bool) -> Void = { _ in }
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            self.window = window
            guard let window else { report(false); return }
            let names: [(NotificationCenter, Notification.Name, AnyObject?)] = [
                (.default, NSWindow.didChangeOcclusionStateNotification, window),
                (.default, NSWindow.didMiniaturizeNotification, window),
                (.default, NSWindow.didDeminiaturizeNotification, window),
                (.default, NSApplication.didHideNotification, nil),
                (.default, NSApplication.didUnhideNotification, nil),
                (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification, nil),
            ]
            for (center, name, object) in names {
                tokens.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            refresh()
        }

        private func refresh() {
            guard let window else { report(false); return }
            report(window.isVisible && !window.isMiniaturized && !NSApp.isHidden
                   && window.occlusionState.contains(.visible))
        }
    }
}

// MARK: - Glossy pill

/// The one glossy button: a blue radial highlight, a white inner rim and dark
/// blue type. Start (and Stop, the same button) on Now. Nothing else uses it.
struct GlossPrimaryButton: View {
    var title: String
    var height: CGFloat = 44
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.emphasis)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: title)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(.rect)
        }
        .buttonStyle(GlossPillStyle())
    }
}

struct GlossPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let solid = SolidFallback(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased).isOn
            configuration.label
                .foregroundStyle(Bloom.pillInk)
                .background { GlossPillBackground(solid: solid).equatable() }
                .overlay { Capsule().fill(Color.white.opacity(hovering && enabled ? 0.12 : 0)) }
                .clipShape(Capsule())
                // A whisper of lift in light mode, where the white rim has
                // nothing to stand against.
                .shadow(color: Bloom.pillInk.opacity(scheme == .light ? 0.22 : 0), radius: 2.5, y: 1)
                .opacity(enabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
                // The press: the pill dips and springs back. Nothing moves at
                // rest, and Reduce Motion keeps only the dimming.
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.965 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.62), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

struct GlossPillBackground: View, Equatable {
    var solid: Bool

    var body: some View {
        Canvas { context, size in
            let capsule = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2, style: .continuous)
            if solid {
                context.fill(capsule, with: .color(Color(hex: 0x8FBBFF)))
                context.stroke(
                    Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75), cornerRadius: size.height / 2, style: .continuous),
                    with: .color(Bloom.pillInk), lineWidth: 1.5
                )
                return
            }
            context.clip(to: capsule)
            // Base: a wide, flat ellipse of blue, vivid in the middle and pale
            // toward the ends and the lower edge.
            var layer = context
            layer.translateBy(x: size.width / 2, y: size.height * 0.40)
            layer.scaleBy(x: 1, y: size.height / size.width * 1.9)
            let reach = size.width * 0.5
            layer.fill(
                Path(CGRect(x: -size.width, y: -size.width, width: size.width * 2, height: size.width * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color(hex: 0x4090FF), location: 0),
                        .init(color: Color(hex: 0x4F9AFF), location: 0.5),
                        .init(color: Color(hex: 0x80B4FF), location: 0.86),
                        .init(color: Color(hex: 0xA9CBFF), location: 1),
                    ]),
                    center: .zero, startRadius: 0, endRadius: reach
                )
            )
            // A soft white pool low in the pill, like light through gel.
            var glow = context
            glow.translateBy(x: size.width / 2, y: size.height)
            glow.scaleBy(x: 1, y: size.height / size.width * 1.6)
            glow.fill(
                Path(CGRect(x: -size.width, y: -size.width, width: size.width * 2, height: size.width * 2)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.62), .white.opacity(0)]),
                    center: .zero, startRadius: 0, endRadius: size.width * 0.24
                )
            )
            // White inner rim, then a finer lighter line just inside it.
            context.stroke(
                Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.9, dy: 0.9), cornerRadius: size.height / 2, style: .continuous),
                with: .color(.white.opacity(0.95)), lineWidth: 1.8
            )
            context.stroke(
                Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 2.4, dy: 2.4), cornerRadius: size.height / 2, style: .continuous),
                with: .color(.white.opacity(0.28)), lineWidth: 0.8
            )
        }
    }
}
