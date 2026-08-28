import AppKit
import SwiftUI

/// Pre-rendered template frames for the menu-bar walking man.
///
/// Frames render into `NSImage`s rather than a live `Canvas`: a
/// `MenuBarExtra` label rasterizes its content, and Canvas views come out
/// empty there — the first build of this icon was invisible. Template images
/// are the one thing the menu bar always honours, tinting themselves for
/// light/dark and the highlighted state.
///
/// The cache lives outside the View because a View's members infer MainActor
/// under Swift 6, and these statics must build without actor hops.
private enum WalkerIconCache {
    static let frameSize = CGSize(
        width: 16 * CGFloat(WalkerSprites.width) / CGFloat(WalkerSprites.height),
        height: 16
    )

    static let stand = render(WalkerSprites.stand)
    static let walk: [NSImage] = [
        WalkerSprites.walk0, WalkerSprites.walk1,
        WalkerSprites.walk2, WalkerSprites.walk3,
        WalkerSprites.walk4, WalkerSprites.walk5,
        WalkerSprites.walk6, WalkerSprites.walk7,
    ].map(render)

    /// One sprite grid -> one template image. Solid squares for every inked
    /// cell: at 16 pt the silhouette carries the pose, dither would be noise.
    static func render(_ grid: [String]) -> NSImage {
        let image = NSImage(size: frameSize)
        image.lockFocus()
        NSColor.black.setFill()
        let cellW = frameSize.width / CGFloat(WalkerSprites.width)
        let cellH = frameSize.height / CGFloat(WalkerSprites.height)
        for (row, line) in grid.enumerated() {
            for (column, ch) in line.enumerated() where ch != "0" {
                // NSImage draws bottom-up; sprite grids read top-down.
                NSRect(
                    x: CGFloat(column) * cellW,
                    y: frameSize.height - CGFloat(row + 1) * cellH,
                    width: cellW,
                    height: cellH
                ).fill()
            }
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

/// The walking man in the menu bar, walking at the belt's real cadence:
///     stepsPerMinute = 60 + 11 * speedKmh
/// The 8-frame cycle covers two full steps, so one frame lasts
/// 120 / (stepsPerMinute * 8) seconds. Stopped belt = static standing frame
/// with no timeline running at all.
struct WalkerMenuIcon: View {
    var speedKmh: Double
    var walking: Bool

    private var stepsPerMinute: Double { 60 + 11 * max(speedKmh, 0) }
    private var frameDuration: Double {
        120 / (stepsPerMinute * Double(WalkerIconCache.walk.count))
    }

    var body: some View {
        if walking {
            TimelineView(.animation(minimumInterval: frameDuration)) { context in
                let index = Int(
                    context.date.timeIntervalSinceReferenceDate / frameDuration
                ) % WalkerIconCache.walk.count
                Image(nsImage: WalkerIconCache.walk[index])
            }
        } else {
            // Belt stopped: standing frame, no timeline churn at all.
            Image(nsImage: WalkerIconCache.stand)
        }
    }
}
