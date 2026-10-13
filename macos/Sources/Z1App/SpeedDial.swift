import AppKit
import SwiftUI

/// A ruled speed control: every 0.1 the pad accepts is a tick, whole numbers
/// are longer and labelled, and the speed you asked for is a bright line.
///
/// While the belt moves, the ticks up to the belt's own speed are lit in the
/// one blue, so a change reads as the blue filling up to the line as the belt
/// ramps. At a standstill the ticks up to the line are lit in ink.
///
/// The whole ruler is the hit target: press anywhere to jump there, drag to
/// fine-tune. Each detent clicks under the finger on a Force Touch trackpad.
struct SpeedDial: View {
    let range: ClosedRange<Double>
    @Binding var value: Double
    /// The belt's measured speed while it moves; nil at a standstill.
    var belt: Double?
    var enabled: Bool
    var format: (Double) -> String
    var onEditingChanged: (Bool) -> Void
    var onCommit: () -> Void

    /// Height of the tick area; the numerals sit under it.
    var height: CGFloat = 36

    @State private var dragging = false
    @State private var lastDetent: Double?

    private static let step = 0.1
    private static let labelHeight: CGFloat = 13
    private static let tickWidth: CGFloat = 1.5
    private static let lineWidth: CGFloat = 2.5

    private var span: Double { max(0.0001, range.upperBound - range.lowerBound) }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    /// The pad's grid is tenths of the unit, anchored at zero, so an imperial
    /// range that starts at 0.99 mph still ticks on 1.0, 1.1, …
    private var tickValues: [Double] {
        let first = Int((range.lowerBound / Self.step).rounded(.up))
        let last = Int((range.upperBound / Self.step + 1e-6).rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { Double($0) * Self.step }
    }

    private func speed(atX x: CGFloat, width: CGFloat) -> Double {
        let raw = range.lowerBound + Double(min(max(x / max(width, 1), 0), 1)) * span
        return Self.snapped(raw, in: range)
    }

    /// Interior values use the display's tenths. Endpoints stay exact: the
    /// pad's minimum in mph can sit between tenths, and rounding it upward
    /// would make the slowest belt speed impossible to select.
    static func snapped(_ raw: Double, in range: ClosedRange<Double>) -> Double {
        if raw <= range.lowerBound { return range.lowerBound }
        if raw >= range.upperBound { return range.upperBound }
        let onGrid = (raw / Self.step).rounded() * Self.step
        return min(max(onGrid, range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let usable = size.width - Self.tickWidth
                let litTo = fraction(belt ?? value)
                let on = GraphicsContext.Shading.color(belt != nil ? Theme.accent : Theme.ink)
                let off = GraphicsContext.Shading.color(Theme.track)
                for v in tickValues {
                    let f = fraction(v)
                    let major = abs(v.rounded() - v) < 0.001
                    let half = !major && abs((v * 2).rounded() - v * 2) < 0.001
                    let isLit = f <= litTo + 0.0001
                    let h = height * (major ? 0.78 : half ? 0.56 : (isLit ? 0.46 : 0.36))
                    let x = f * usable
                    context.fill(
                        Path(CGRect(x: x, y: (height - h) / 2, width: Self.tickWidth, height: h)),
                        with: isLit ? on : off
                    )
                    if major {
                        let label = context.resolve(
                            Text("\(Int(v.rounded()))")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.dim)
                        )
                        // Kept inside the ruler, so a 6 at the top end is not clipped.
                        let w = label.measure(in: CGSize(width: 40, height: 20)).width
                        let lx = min(max(x + Self.tickWidth / 2, w / 2), size.width - w / 2)
                        context.draw(label, at: CGPoint(x: lx, y: height + Self.labelHeight / 2 + 1))
                    }
                }
                // The speed asked for: a plain ink line, full height, centred
                // on its tick.
                let centre = fraction(value) * usable + Self.tickWidth / 2
                let lineX = min(max(centre - Self.lineWidth / 2, 0), size.width - Self.lineWidth)
                context.fill(
                    Path(roundedRect: CGRect(x: lineX, y: 0, width: Self.lineWidth, height: height),
                         cornerRadius: Self.lineWidth / 2),
                    with: .color(Theme.ink)
                )
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled else { return }
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        let next = speed(atX: drag.location.x, width: width)
                        if next != value {
                            value = next
                            tickHaptic(next)
                        }
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        finishEditing()
                        if enabled { onCommit() }
                    }
            )
        }
        .frame(height: height + Self.labelHeight)
        .opacity(enabled ? 1 : 0.4)
        // A disconnect may disable the ruler before the pointer is released.
        // Always clear editing so telemetry can own the draft again.
        .onChange(of: enabled) { _, enabled in
            if !enabled { finishEditing() }
        }
        .onDisappear { finishEditing() }
        .accessibilityElement()
        .accessibilityLabel("Speed")
        .accessibilityValue(format(value))
        .disabled(!enabled)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: value = Self.snapped(value + Self.step, in: range)
            case .decrement: value = Self.snapped(value - Self.step, in: range)
            @unknown default: return
            }
            onCommit()
        }
    }

    private func finishEditing() {
        guard dragging else { return }
        dragging = false
        lastDetent = nil
        onEditingChanged(false)
    }

    /// One click per stop. `.alignment` is the detent feedback macOS uses for
    /// snapping, which is exactly what this is. Haptic only; never a sound.
    private func tickHaptic(_ detent: Double) {
        guard lastDetent != detent else { return }
        lastDetent = detent
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .drawCompleted
        )
    }
}
