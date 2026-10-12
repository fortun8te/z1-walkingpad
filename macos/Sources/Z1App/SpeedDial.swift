import AppKit
import SwiftUI

/// A ruled speed control: every 0.1 the pad accepts is a tick, the ticks you
/// have dialled past are lit, whole numbers are longer and labelled, and the
/// one you are on is a bright line.
///
/// The whole ruler is the hit target: press anywhere to jump there, drag to
/// fine-tune. Reading it is reading a ruler, so the full range is legible at
/// a glance. Each detent clicks under the finger on a Force Touch trackpad.
struct SpeedDial: View {
    let range: ClosedRange<Double>
    @Binding var value: Double
    var enabled: Bool
    var onEditingChanged: (Bool) -> Void
    var onCommit: () -> Void

    /// Height of the tick area; the numerals sit under it.
    var height: CGFloat = 36
    /// Belt moving: lit ticks turn the one blue.
    var live = false

    @State private var dragging = false
    @State private var lastDetent: Double?

    private static let step = 0.1
    private static let labelHeight: CGFloat = 13
    private static let tickWidth: CGFloat = 1.5

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
        let snapped = (raw / Self.step).rounded() * Self.step
        // Clamp after the snap, or 6.4000001 lands past the top.
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let usable = size.width - Self.tickWidth
                let lit = fraction(value)
                let on = GraphicsContext.Shading.color(live ? Theme.accent : Theme.ink)
                let off = GraphicsContext.Shading.color(Theme.track)
                for v in tickValues {
                    let f = fraction(v)
                    let major = abs(v.rounded() - v) < 0.001
                    let half = !major && abs((v * 2).rounded() - v * 2) < 0.001
                    let isLit = f <= lit + 0.0001
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
                                .foregroundStyle(Theme.faint)
                        )
                        // Kept inside the ruler, so a 6 at the top end is not clipped.
                        let w = label.measure(in: CGSize(width: 40, height: 20)).width
                        let lx = min(max(x + Self.tickWidth / 2, w / 2), size.width - w / 2)
                        context.draw(label, at: CGPoint(x: lx, y: height + Self.labelHeight / 2 + 1))
                    }
                }
                // The value you are on: a plain ink line, full height.
                let x = lit * (size.width - 2.5)
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: 0, width: 2.5, height: height), cornerRadius: 1.25),
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
                        guard enabled else { return }
                        dragging = false
                        lastDetent = nil
                        onEditingChanged(false)
                        onCommit()
                    }
            )
        }
        .frame(height: height + Self.labelHeight)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel("Speed")
        .accessibilityValue(String(format: "%.1f", value))
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

/// Five speeds one click away. Picked at a standstill, the speed waits for
/// Start; while walking it goes to the pad at once.
struct SpeedPresets: View {
    let values: [Double]
    /// The speed the pad is at, or will start at.
    let current: Double?
    var enabled: Bool
    var pick: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { preset in
                let chosen = current.map { abs($0 - preset) < 0.05 } ?? false
                Button {
                    pick(preset)
                } label: {
                    Text(String(format: "%.1f", preset))
                        .font(.system(size: 13, weight: chosen ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(chosen ? Theme.ink : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(chosen ? Theme.selection : Theme.wash)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(chosen ? Theme.ink.opacity(0.35) : .clear, lineWidth: 1)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help("\(String(format: "%.1f", preset))")
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }
}
