// The reading drawn as the meter's seven-segment LCD: each character a cell of segments a..g, the decimal point
// belongs to the cell before it.  Unlit segments are drawn faintly, as on the glass.

import SwiftUI

struct SevenSegmentText: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var cells = 6                       // the main display: a sign cell and five digits
    var lit: Color = Bench.yellow
    var height: CGFloat = 96

    //   aaa
    //  f   b
    //   ggg
    //  e   c
    //   ddd
    static let masks: [Character: UInt8] = [
        "0": 0b0111111, "1": 0b0000110, "2": 0b1011011, "3": 0b1001111, "4": 0b1100110,
        "5": 0b1101101, "6": 0b1111101, "7": 0b0000111, "8": 0b1111111, "9": 0b1101111,
        "-": 0b1000000, " ": 0, "O": 0b0111111, "F": 0b1110001, "L": 0b0111000, "E": 0b1111001,
        "A": 0b1110111, "P": 0b1110011, "U": 0b0111110, "n": 0b1010100, "r": 0b1010000, "d": 0b1011110,
        "b": 0b1111100, "C": 0b0111001, "H": 0b1110110, "S": 0b1101101, "t": 0b1111000, "o": 0b1011100,
        "u": 0b0011100, "N": 0b0110111, "D": 0b1011110, "_": 0b0001000,
    ]

    /// (character, point after it) cells, right-aligned in `cells`.
    static func layout(_ text: String, _ cells: Int) -> [(Character, Bool)] {
        var out: [(Character, Bool)] = []
        for ch in text {
            if ch == "." || ch == "," {
                if out.isEmpty { out.append((" ", true)) } else { out[out.count - 1].1 = true }
            } else {
                out.append((ch, false))
            }
        }
        if out.count < cells { out = Array(repeating: (" ", false), count: cells - out.count) + out }
        return out
    }

    // `height` is the largest size: on a narrow screen the cells shrink with their proportions kept, so the display
    // never makes the page wider than the screen (6 cells at 92 pt are 386 pt, more than an iPhone has beside the unit)
    var body: some View {
        let cellsUsed = Self.layout(text, cells)
        let ratio = CGFloat(cellsUsed.count) * 0.70     // width / height: each cell 0.58 h wide, 0.12 h apart
        Canvas { ctx, size in
            let off = Bench.segmentOff(scheme)
            let h = size.height
            let w = h * 0.58
            for (i, cell) in cellsUsed.enumerated() {
                let x0 = CGFloat(i) * (w + h * 0.12)
                let mask = Self.masks[cell.0] ?? 0
                draw(&ctx, x0: x0, w: w, h: h, mask: 0b1111111, color: off)
                draw(&ctx, x0: x0, w: w, h: h, mask: mask, color: lit)
                let r = h * 0.06
                let dot = Path(ellipseIn: CGRect(x: x0 + w + h * 0.03 - r / 2, y: h - r * 1.4, width: r, height: r))
                ctx.fill(dot, with: .color(cell.1 ? lit : off))
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: ratio * height, maxHeight: height)
        .accessibilityLabel(text)
    }

    private func draw(_ ctx: inout GraphicsContext, x0: CGFloat, w: CGFloat, h: CGFloat, mask: UInt8, color: Color) {
        let t = h * 0.09                // segment thickness
        let slant = h * 0.08            // italic lean of the glass
        let half = h / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x + slant * (1 - y / h), y: y) }
        func horizontal(_ y: CGFloat) -> Path {
            var p = Path()
            p.move(to: pt(t * 0.6, y))
            p.addLine(to: pt(t * 1.1, y - t / 2))
            p.addLine(to: pt(w - t * 1.1, y - t / 2))
            p.addLine(to: pt(w - t * 0.6, y))
            p.addLine(to: pt(w - t * 1.1, y + t / 2))
            p.addLine(to: pt(t * 1.1, y + t / 2))
            p.closeSubpath()
            return p
        }
        func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path {
            var p = Path()
            p.move(to: pt(x, y0 + t * 0.6))
            p.addLine(to: pt(x + t / 2, y0 + t * 1.1))
            p.addLine(to: pt(x + t / 2, y1 - t * 1.1))
            p.addLine(to: pt(x, y1 - t * 0.6))
            p.addLine(to: pt(x - t / 2, y1 - t * 1.1))
            p.addLine(to: pt(x - t / 2, y0 + t * 1.1))
            p.closeSubpath()
            return p
        }
        let segs: [Path] = [
            horizontal(t / 2),                          // a
            vertical(w - t / 2, 0, half),               // b
            vertical(w - t / 2, half, h),               // c
            horizontal(h - t / 2),                      // d
            vertical(t / 2, half, h),                   // e
            vertical(t / 2, 0, half),                   // f
            horizontal(half),                           // g
        ]
        for (i, s) in segs.enumerated() where mask & (1 << i) != 0 {
            ctx.fill(s, with: .color(color))
        }
    }
}
