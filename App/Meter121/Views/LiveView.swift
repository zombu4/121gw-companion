// LIVE: the reading drawn as the meter's LCD with its symbols and bargraph, the statistics, a short trend and the
// meter's keys (companion LIVE page).

import Meter121Kit
import SwiftUI

struct LiveView: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        if vSize == .compact {
            // landscape: the display alone takes the height of the screen, so it goes left and the rest right
            BenchPage(title: "Live", maxWidth: 1100) {
                HStack(alignment: .top, spacing: 16) {
                    // the keys under the display, both above the floating tab bar on a 440 pt high screen
                    VStack(alignment: .leading, spacing: 12) {
                        LCDPanel(reading: meter.reading, stale: meter.stale, desk: meter.desk, digitHeight: 48, subHeight: 26)
                        KeyPad(compact: true)
                        if let note = meter.link2Note { NoteText(text: note) }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        StatsPanel()
                        DerivedPanel()
                        MiniTrend()
                    }
                }
            }
        } else {
            BenchPage(title: "Live") {
                LCDPanel(reading: meter.reading, stale: meter.stale, desk: meter.desk)
                if let note = meter.link2Note { NoteText(text: note) }
                StatsPanel()
                DerivedPanel()
                MiniTrend()
                KeyPad()
            }
        }
    }
}

struct NoteText: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Bench.yellow).frame(width: 2)
            Text(text).font(.footnote).foregroundStyle(Bench.dim(scheme))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LCDPanel: View {
    @Environment(\.colorScheme) private var scheme
    let reading: Reading?
    let stale: Bool
    let desk: Bool
    var digitHeight: CGFloat = 92           // the main digits at their largest; they shrink to the width they get
    var subHeight: CGFloat = 34             // the sub display's digits

    static let symbolOrder = ["AC", "DC", "AUTO", "HOLD", "A-HOLD", "REL", "MIN", "MAX", "AVG", "PEAK", "MEM", "1kHz", "HV",
                              "APO", "BAT", "BT"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Caption(reading?.modeName ?? "no reading")
                Spacer()
                if desk {
                    Caption("page Ld: no readings")
                } else if stale && reading != nil {
                    Caption("stale")
                }
            }
            symbols
            HStack(alignment: .bottom, spacing: 10) {
                Spacer(minLength: 0)
                SevenSegmentText(text: reading?.text ?? "-----", lit: stale ? Bench.yellow.opacity(0.45) : Bench.yellow, height: digitHeight)
                Text(reading?.unit ?? "")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Bench.ink(scheme))
                    .frame(minWidth: 56, alignment: .leading)
            }
            .minimumScaleFactor(0.5)
            HStack(alignment: .bottom) {
                if let r = reading, !r.subText.isEmpty {
                    Caption(r.subLabel)
                    Spacer()
                    SevenSegmentText(text: r.subText, cells: 5, lit: Bench.ink(scheme), height: subHeight)
                    Text(r.subUnit).font(.system(size: 15, weight: .semibold)).frame(minWidth: 34, alignment: .leading)
                } else {
                    Caption("sub display")
                    Spacer()
                    Text("—").foregroundStyle(Bench.dim(scheme))
                }
            }
            BarGraph(bar: reading?.bar)
        }
        .padding(14)
        .background(Bench.panel(scheme))
        .overlay(Rectangle().stroke(Bench.hairline(scheme), lineWidth: 0.5))
    }

    var symbols: some View {
        let on = Set(reading?.symbols ?? [])
        return HStack(spacing: 6) {
            ForEach(Self.symbolOrder, id: \.self) { s in
                if on.contains(s) {
                    Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Bench.yellow)
                }
            }
            if on.isEmpty { Text(" ").font(.system(size: 11)) }
        }
    }
}

struct BarGraph: View {
    @Environment(\.colorScheme) private var scheme
    let bar: Bargraph?

    var body: some View {
        let b = bar ?? Bargraph(shown: false, lit: 0, negative: false, label: "")
        HStack(spacing: 6) {
            Text(b.shown && b.negative ? "−" : " ").font(.system(size: 13, weight: .bold)).frame(width: 10)
            GeometryReader { g in
                let n = 26
                let gap: CGFloat = 2
                let w = (g.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                HStack(spacing: gap) {
                    ForEach(0..<n, id: \.self) { i in
                        Rectangle()
                            .fill(b.shown && i < b.lit ? Bench.yellow : Bench.segmentOff(scheme))
                            .frame(width: max(1, w), height: i % 5 == 0 ? 14 : 9)
                    }
                }
                .frame(height: 14, alignment: .bottom)
            }
            .frame(height: 14)
            Text(b.shown ? b.label : "").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Bench.dim(scheme)).frame(width: 34, alignment: .trailing)
        }
    }
}

struct StatsPanel: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = meter.session.stats
        let dp = meter.session.statsDP
        let unit = meter.session.last?.unit ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Statistics")
                Spacer()
                Button("Reset") { meter.resetStats() }.font(.system(size: 12, weight: .semibold))
            }
            HStack(spacing: 0) {
                cell("min", formatNumber(s.min, dp))
                cell("max", formatNumber(s.max, dp))
                cell("mean", formatNumber(s.mean, (dp ?? 3) + 1))
                cell("sd", formatNumber(s.sd, (dp ?? 3) + 1))
                cell("n", String(s.n))
            }
            if !unit.isEmpty { Text("in \(unit); restarts when the mode, unit or range changes").font(.caption2).foregroundStyle(Bench.dim(scheme)) }
        }
    }

    func cell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 10, weight: .semibold)).foregroundStyle(Bench.dim(scheme))
            Text(v).font(.system(size: 15, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last minute of the trend, small.
struct MiniTrend: View {
    @EnvironmentObject var meter: MeterController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Trend · last 60 s")
            TrendCanvas(points: meter.session.trendInScale(), window: 60, cursors: nil)
                .frame(height: 110)
        }
    }
}

/// The meter's keys from the phone (companion: RANGE, HOLD, REL, PEAK, MODE, MIN/MAX and MEM long; SETUP after a
/// confirmation, since the meter refuses it while logging and starts an offset calibration in calibration mode).
struct KeyPad: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var error: String?
    @State private var confirmSetup = false
    @State private var busy = false
    var compact = false                     // landscape: lower keys, no caption, so they fit under the display

    let rows: [[MeterKey]] = [[.range, .hold, .rel, .peak], [.mode, .minmax, .mem, .setup]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact { Caption("Keys · touch and hold for a long press") }
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r], id: \.self) { k in
                        Text(k.label)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: compact ? 38 : 44)
                            .overlay(Capsule().stroke(Bench.hairline(scheme)))
                            .contentShape(Capsule())
                            .onLongPressGesture(minimumDuration: 0.6) { press(k, long: true) }
                            .onTapGesture {
                                if k == .setup { confirmSetup = true } else { press(k, long: false) }
                            }
                    }
                }
            }
            .disabled(!meter.connected || meter.desk || meter.mode == .bootloader || busy)
            .opacity(!meter.connected || meter.desk ? 0.4 : 1)
            if let error { Text(error).font(.footnote).foregroundStyle(Bench.bad) }
        }
        .confirmationDialog("Press SETUP on the meter?", isPresented: $confirmSetup, titleVisibility: .visible) {
            Button("Press SETUP") { press(.setup, long: false) }
        } message: {
            Text("The meter refuses SETUP while it logs, and in calibration mode SETUP starts an offset calibration.")
        }
    }

    func press(_ k: MeterKey, long: Bool) {
        busy = true
        error = nil
        Task {
            do { try await meter.press(k, long: long) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
