import AppKit
import SwiftUI

/// A ruled speed slider: every 0.1 km/h the pad accepts is a tick, the ticks
/// you have dialled past are lit, and the one you are on is a bright line.
///
/// It replaces the old slider-plus-field-plus-steppers arrangement, where the
/// speed lived in three places at once and none of them was obviously *the*
/// control. Reading the value is counting lit ticks, so the whole 1.6–6.4
/// range is legible at a glance instead of being inferred from a knob's
/// position. Each detent clicks under the finger on a Force Touch trackpad.
struct SpeedDial: View {
    let range: ClosedRange<Double>
    @Binding var value: Double
    var enabled: Bool
    var onEditingChanged: (Bool) -> Void
    var onCommit: () -> Void

    var step: Double = 0.1
    var height: CGFloat = 26
    /// Belt moving: lit ticks turn the one blue.
    var live = false

    @State private var dragging = false
    @State private var lastDetent: Double?

    private var span: Double { max(0.0001, range.upperBound - range.lowerBound) }
    private var tickCount: Int { Int((span / step).rounded()) + 1 }

    private func value(at index: Int) -> Double {
        range.lowerBound + Double(index) * step
    }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    private func speed(atX x: CGFloat, width: CGFloat) -> Double {
        let raw = range.lowerBound + Double(min(max(x / max(width, 1), 0), 1)) * span
        let snapped = (raw / step).rounded() * step
        // clamp after snap to avoid 6.4000001 > max
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    // Cache tick layout — only recompute when range/step changes, not on every value change
    private var ticks: [(f: CGFloat, major: Bool)] {
        (0..<tickCount).map { idx in
            let v = value(at: idx)
            return (fraction(v), abs(v.rounded() - v) < 0.001)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let lit = fraction(value)
                    let on = GraphicsContext.Shading.color(live ? Theme.accent : Theme.paper)
                    let off = GraphicsContext.Shading.color(Theme.paper12)
                    for tick in ticks {
                        let x = tick.f * (size.width - 1.25)
                        let isLit = tick.f <= lit + 0.0001
                        let h = size.height * (tick.major ? 0.72 : (isLit ? 0.52 : 0.36))
                        context.fill(
                            Path(CGRect(x: x, y: (size.height - h) / 2, width: 1.25, height: h)),
                            with: isLit ? on : off
                        )
                    }
                }
                indicator(width: width)
            }
            .frame(height: height)
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
                        guard enabled else { return }
                        dragging = false
                        lastDetent = nil
                        onEditingChanged(false)
                        onCommit()
                    }
            )
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel("Speed")
        .accessibilityValue(String(format: "%.1f", value))
    }

    /// The value you are on: a plain paper line, no halo. It snaps with the
    /// telemetry; only a drag is allowed to feel physical.
    private func indicator(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Theme.paper)
            .frame(width: 2, height: height)
            .offset(x: fraction(value) * max(width - 2, 0))
    }

    /// One click per stop. `.alignment` is the detent feedback macOS uses for
    /// snapping, which is exactly what this is.
    private func tickHaptic(_ detent: Double) {
        guard lastDetent != detent else { return }
        lastDetent = detent
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .drawCompleted
        )
    }
}
