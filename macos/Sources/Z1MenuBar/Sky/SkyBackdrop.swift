import AppKit
import QuartzCore
import SwiftUI
import Z1Core

/// A painted field with one slowly drifting light layer. Core Animation
/// moves the cached image; the SwiftUI view does no work per frame.
struct SkyBackdrop: View {
    var goalProgress: Double
    @ObservedObject private var engine = SkyEngine.shared

    var body: some View {
        SkyLayerRepresentable(frame: engine.frame, progress: min(1, max(0, goalProgress)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { engine.setVisible(true) }
            .onDisappear { engine.setVisible(false) }
    }
}

private struct SkyLayerRepresentable: NSViewRepresentable {
    var frame: SkyFrame?
    var progress: Double

    func makeNSView(context: Context) -> SkyLayerView { SkyLayerView() }
    func updateNSView(_ view: SkyLayerView, context: Context) {
        view.apply(frame: frame, progress: progress)
    }
}

final class SkyLayerView: NSView {
    private let root = CALayer()
    private let back = CALayer()
    private let light = CALayer()
    private let goalGlow = CAGradientLayer()
    private var current: SkyFrame?
    private var occlusionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = root
        wantsLayer = true
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        for image in [back, light] {
            image.contentsGravity = .resize
            image.minificationFilter = .linear
            image.magnificationFilter = .linear
            root.addSublayer(image)
        }
        goalGlow.type = .radial
        goalGlow.startPoint = CGPoint(x: 0.5, y: 0)
        goalGlow.endPoint = CGPoint(x: 1.15, y: 0.42)
        root.addSublayer(goalGlow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            light.removeAllAnimations()
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVisibility() }
        }
        root.contentsScale = window.backingScaleFactor
        SkyEngine.shared.setRenderSize(bounds.size, scale: window.backingScaleFactor)
        syncVisibility()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.frame = bounds
        goalGlow.frame = bounds
        let inset = current?.blobInset ?? SkyRenderer.blobInset
        light.frame = bounds.insetBy(dx: -inset, dy: -inset)
        CATransaction.commit()
        if let window {
            SkyEngine.shared.setRenderSize(bounds.size, scale: window.backingScaleFactor)
        }
    }

    func apply(frame newFrame: SkyFrame?, progress: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        goalGlow.colors = [
            (newFrame?.horizonGlow ?? NSColor.systemBlue.cgColor).copy(alpha: 0.02 + 0.08 * progress) ?? NSColor.clear.cgColor,
            NSColor.clear.cgColor,
        ]
        CATransaction.commit()

        guard let newFrame else { return }
        let first = current == nil
        current = newFrame
        CATransaction.begin()
        CATransaction.setAnimationDuration(first ? 0 : 1.4)
        CATransaction.setDisableActions(first)
        back.contents = newFrame.back
        light.contents = newFrame.blobs
        CATransaction.commit()
        needsLayout = true
        syncVisibility()
    }

    private func syncVisibility() {
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        SkyEngine.shared.setVisible(visible)
        guard visible, current?.blobs != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            light.removeAllAnimations()
            return
        }
        guard light.animation(forKey: "breathe") == nil else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = -7
        move.toValue = 7
        move.duration = 22
        move.autoreverses = true
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
        light.add(move, forKey: "breathe")
    }
}

/// Kept for the callers that still name the previous sky view.
struct SkyField: View {
    static func accent(at date: Date = Date(), weather: WeatherSnapshot?) -> Color {
        _ = (date, weather)
        return Z1.live
    }

    var intensity: Double
    var date: Date = Date()
    var weather: WeatherSnapshot?
    var kp: Double = 0

    var body: some View { SkyBackdrop(goalProgress: intensity) }
}

struct NightField: View {
    var intensity: Double
    var body: some View { SkyBackdrop(goalProgress: intensity) }
}

extension View {
    @ViewBuilder
    func z1LiquidGlass(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}
