import AppKit

/// The status-item icon: seven ticks, lit up to today's goal progress.
///
/// Ticks are the app's one progress idiom (speed dial, goal line), so the
/// menu bar speaks the same language instead of showing a figure. It is a
/// template image — the menu bar tints it for light/dark/highlight — and the
/// unlit ticks ride on alpha, which templates honour.
///
/// Never animate this. `NSStatusItem` images swapped on a timer are what once
/// blew the process up to gigabytes; the icon changes only when the lit count
/// changes, a handful of times a day.
enum MenuBarGlyph {
    static let tickCount = 7

    private static let cache: [NSImage] = (0...tickCount).map(render)

    /// `progress` 0...1 against the daily goal.
    static func image(progress: Double) -> NSImage {
        cache[litTicks(progress)]
    }

    static func litTicks(_ progress: Double) -> Int {
        let clamped = min(max(progress, 0), 1)
        // Any walking at all lights the first tick; full only at the goal.
        if clamped <= 0 { return 0 }
        return max(1, Int((clamped * Double(tickCount)).rounded(.down)))
    }

    private static func render(_ lit: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            for i in 0..<tickCount {
                let on = i < lit
                NSColor.black.withAlphaComponent(on ? 1 : 0.38).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: 1 + CGFloat(i) * 2.6,
                        y: 1.5,
                        width: 1.4,
                        height: on ? 11 : 5.5
                    ),
                    xRadius: 0.7,
                    yRadius: 0.7
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Z1 WalkingPad"
        return image
    }
}
