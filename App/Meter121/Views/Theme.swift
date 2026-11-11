// "Bench instrument" (the companion's design, owner choice): matte black, the 121GW yellow as the only accent,
// hairlines instead of boxes, large tabular digits, an oscilloscope-style grid; no rounded cards, no shadows, no
// decorative gradients; system fonts only.  Light and dark follow the SETTINGS choice.

import SwiftUI

enum Bench {
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    static let yellowDim = Color(red: 1.0, green: 0.80, blue: 0.0).opacity(0.14)

    static func background(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.055) : Color(white: 0.965) }
    static func panel(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.085) : Color.white }
    static func ink(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.92) : Color(white: 0.08) }
    static func dim(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.55) : Color(white: 0.42) }
    static func hairline(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.20) : Color(white: 0.82) }
    static func grid(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.16) : Color(white: 0.86) }
    static func segmentOff(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.12) : Color(white: 0.90) }
    static let bad = Color(red: 1.0, green: 0.33, blue: 0.27)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.45)
}

struct Hairline: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Rectangle().fill(Bench.hairline(scheme)).frame(height: 0.5) }
}

/// A small upper-case label, as the companion's section heads.
struct Caption: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Bench.dim(scheme))
    }
}

/// A flat pill-shaped button with a hairline frame; the accent fills it.
struct BenchButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .foregroundStyle(accent ? Color.black : Bench.ink(scheme))
            .background(Capsule().fill(accent ? Bench.yellow.opacity(configuration.isPressed ? 0.7 : 1) :
                (configuration.isPressed ? Bench.yellowDim : Color.clear)))
            .overlay(Capsule().stroke(accent ? Color.clear : Bench.hairline(scheme), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

extension View {
    func benchButton(accent: Bool = false) -> some View { buttonStyle(BenchButtonStyle(accent: accent)) }
}

/// A label / value row with tabular digits.
struct ValueRow: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Bench.dim(scheme))
            Spacer(minLength: 12)
            Text(value).monospacedDigit().foregroundStyle(Bench.ink(scheme)).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 14))
        .padding(.vertical, 6)
    }
}

/// A page: background, title row, hairline, scrolling content.
struct BenchPage<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var maxWidth: CGFloat = 720             // one column; the Live page in landscape has two and takes more
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ConnectBar(title: title)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(16)
                    .frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Bench.background(scheme).ignoresSafeArea())
    }
}

func formatNumber(_ v: Double?, _ dp: Int?) -> String {
    guard let v else { return "—" }
    return String(format: "%.*f", Int32(max(0, dp ?? 4)), v)
}
