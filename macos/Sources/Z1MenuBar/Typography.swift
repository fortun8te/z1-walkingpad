import AppKit
import SwiftUI

/// ABC Diatype (Dinamo, Berlin) — the neo-grotesque the interface is set in.
///
/// **Licence note:** the only build installed on this machine is the family
/// literally named "ABC Diatype Unlicensed Trial", so the PostScript names
/// below carry `UnlicensedTrial`. That is fine for a personal app that never
/// leaves this Mac — the faces are read from the user's own font library and
/// are not copied into the bundle — but it must be swapped for a licensed
/// build before this app is ever distributed.
///
/// Every call falls back to the system face if Diatype is missing, so the app
/// stays legible on a machine that has never heard of Dinamo.
enum Z1Type {
    private static let stem = "ABCDiatypeUnlicensedTrial"

    private static func font(_ suffix: String, _ size: CGFloat, _ fallback: Font.Weight) -> Font {
        let name = "\(stem)-\(suffix)"
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: fallback)
    }

    static func light(_ size: CGFloat) -> Font { font("Light", size, .light) }
    static func regular(_ size: CGFloat) -> Font { font("Regular", size, .regular) }
    static func medium(_ size: CGFloat) -> Font { font("Medium", size, .medium) }

    /// Exposure (OGJ) — a face whose weight is literally photographic
    /// exposure, cut in grades +10…+100. We map the grade to the sun: thin
    /// dark letters at night, blown-out at noon. Italic trial is the only cut
    /// installed; falls back to Diatype when absent.
    static func exposure(_ size: CGFloat, solarElevation: Double) -> Font {
        // night ≤ -6° → +20 · twilight → +40 · low sun → +60 · day → +90
        let grade: Int
        switch solarElevation {
        case ..<(-6): grade = 20
        case ..<2: grade = 40
        case ..<12: grade = 60
        case ..<25: grade = 80
        default: grade = 90
        }
        let name = "ExposureItalicTrial-+\(grade)"
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return medium(size)
    }

    /// True when the real face is present — used once, to decide whether the
    /// tighter Diatype-specific tracking is appropriate.
    static var available: Bool { NSFont(name: "\(stem)-Regular", size: 12) != nil }
}
