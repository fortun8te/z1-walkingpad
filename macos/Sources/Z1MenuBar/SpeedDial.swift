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
                    for tick in ticks {
                        let x = tick.f * (size.width - 1)
                        let isLit = tick.f <= lit + 0.0001
                        let h = size.height * (tick.major ? 0.80 : (isLit ? 0.62 : 0.44))
                        let rect = CGRect(
                            x: x,
                            y: (size.height - h) / 2,
                            width: 1.4,
                            height: h
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 0.7),
                            with: .color(isLit ? Z1.ink.opacity(0.92) : Color.white.opacity(0.16))
                        )
                    }
                }
                // speed indicator: throttle animation to avoid fighting telemetry 1Hz jitter
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
        .opacity(enabled ? 1 : 0.35)
    }

    private func indicator(width: CGFloat) -> some View {
        Rectangle()
            .fill(Z1.ink)
            .frame(width: 1.6, height: height)
            .shadow(color: Color.white.opacity(dragging ? 0.9 : 0.6), radius: dragging ? 5 : 3)
            .offset(x: fraction(value) * max(width - 1, 0) - 0.8)
            // don't animate live telemetry bumps — only drag movement feels physical
            .animation(dragging ? .smooth(duration: 0.08) : .linear(duration: 0.02), value: value)
            .animation(.smooth(duration: 0.14), value: dragging)
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
