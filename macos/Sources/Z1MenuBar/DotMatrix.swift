import SwiftUI

/// Numerals drawn as a lit dot grid, with the unlit dots left visible.
///
/// The unlit dots are the point: the readout reads as a physical panel whose
/// segments are being lit, not as text that happens to be dotty. It also means
/// the block never changes size as the digits change.
struct DotMatrixText: View {
    var text: String
    var dot: CGFloat = 3
    var gap: CGFloat = 1.6
    var color: Color = Z1.ink
    /// When false the panel keeps its exact shape but nothing lights up — the
    /// app has no value to show, and says so by staying dark rather than by
    /// displaying a confident 0,0 it did not measure.
    var lit: Bool = true
    /// Kept very low on purpose. The unlit grid has to be *just* perceptible —
    /// present enough that a dark panel reads as "no value", faint enough that
    /// the lit digits are a number and not a texture.
    var unlit: Color = Color.white.opacity(0.045)

    private static let rows = 7

    /// 5×7 for digits, 2×7 for separators. Hand-set: a real 5×7 cell is the
    /// smallest grid where a 4 and a 1 cannot be confused at a glance.
    private static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ",": ["00", "00", "00", "00", "00", "11", "10"],
        ".": ["00", "00", "00", "00", "00", "11", "11"],
        ":": ["00", "00", "11", "00", "00", "11", "00"],
        "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
        " ": ["00", "00", "00", "00", "00", "00", "00"],
    ]

    private var pitch: CGFloat { dot + gap }

    private var glyphList: [[String]] {
        text.map { Self.glyphs[$0] ?? Self.glyphs[" "]! }
    }

    private var size: CGSize {
        let widths = glyphList.map { CGFloat($0[0].count) * pitch - gap }
        let total = widths.reduce(0, +) + pitch * CGFloat(max(0, glyphList.count - 1))
        return CGSize(width: total, height: CGFloat(Self.rows) * pitch - gap)
    }

    var body: some View {
        Canvas { context, _ in
            var x: CGFloat = 0
            for glyph in glyphList {
                let columns = glyph[0].count
                for (row, bits) in glyph.enumerated() {
                    for (column, bit) in bits.enumerated() {
                        let rect = CGRect(
                            x: x + CGFloat(column) * pitch,
                            y: CGFloat(row) * pitch,
                            width: dot,
                            height: dot
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(lit && bit == "1" ? color : unlit)
                        )
                    }
                }
                x += CGFloat(columns) * pitch - gap + pitch
            }
        }
        .frame(width: size.width, height: size.height)
        // reduce contention with 1Hz telemetry: only animate when value actually committed, not every tick
        .animation(.easeOut(duration: 0.12), value: text)
        .animation(.smooth(duration: 0.3), value: lit)
        .drawingGroup(opaque: false) // rasterize dots to single layer, faster
    }
}
