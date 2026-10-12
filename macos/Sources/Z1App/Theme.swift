import AppKit
import SwiftUI

/// The whole palette: one flat ground, one surface a step off it, one ink in
/// a few strengths, one hairline, one blue.
///
/// Blue means the belt is moving, or progress toward today's goal. Amber means
/// trouble. Nothing else on screen is coloured. Every token resolves per
/// appearance, so light and dark are both first-class and follow the system.
enum Theme {
    // MARK: colour

    static let ground = dynamic(light: 0xF3F3F1, dark: 0x0F1012)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x18191C)

    /// Text and marks. Full strength for every number, measured or estimated.
    static let ink = dynamic(light: 0x16171A, dark: 0xF4F5F7)
    /// Secondary text: units, captions that carry information.
    static let dim = ink.opacity(0.62)
    /// Labels under numbers, axis marks.
    static let faint = ink.opacity(0.42)
    /// Unlit ticks, tracks.
    static let track = ink.opacity(0.13)
    /// Empty bars and cells.
    static let wash = ink.opacity(0.06)

    static let hairline = dynamic(light: 0x000000, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// The chosen chip or tab.
    static let selection = dynamic(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.13)
    /// Round controls (− / +) at rest and under the pointer.
    static let control = dynamic(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let controlHover = dynamic(light: 0x000000, lightAlpha: 0.11, dark: 0xFFFFFF, darkAlpha: 0.16)
    /// Dot-matrix dots that are off: just perceptible, never a texture.
    static let unlitDot = dynamic(light: 0x000000, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.05)

    static let accent = dynamic(light: 0x2F6FE4, dark: 0x4C8DFF)
    static let trouble = dynamic(light: 0xB86E00, dark: 0xF5A524)

    static let nsGround = nsDynamic(light: 0xF3F3F1, dark: 0x0F1012)

    // MARK: geometry (8-pt grid)

    static let outer: CGFloat = 16
    static let inner: CGFloat = 12
    static let related: CGFloat = 8

    static let cardRadius: CGFloat = 14
    static let edgeWidth: CGFloat = 0.75

    // MARK: type: SF Pro, sentence case, no tracking

    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let emphasis = Font.system(size: 15, weight: .semibold)
    static let section = Font.system(size: 22, weight: .semibold)
    /// Live and summary numbers.
    static let number = Font.system(size: 15, weight: .medium).monospacedDigit()

    // MARK: motion

    /// The only animation left: a pressed control dipping for a moment.
    static let press = Animation.easeOut(duration: 0.12)

    // MARK: helpers

    private static func dynamic(
        light: UInt32, lightAlpha: CGFloat = 1,
        dark: UInt32, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: nsDynamic(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
    }

    private static func nsDynamic(
        light: UInt32, lightAlpha: CGFloat = 1,
        dark: UInt32, darkAlpha: CGFloat = 1
    ) -> NSColor {
        let lightColor = NSColor(hex: light, alpha: lightAlpha)
        let darkColor = NSColor(hex: dark, alpha: darkAlpha)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
