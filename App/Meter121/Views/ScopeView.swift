// SCOPE: the trend on an oscilloscope grid with a time base and two cursors (time, value and frequency differences);
// the trace breaks where the meter had no value (overload, range change).  Companion SCOPE page.

import Meter121Kit
import SwiftUI

struct ScopeView: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var window: Double = 60
    @State private var cursors: (Double, Double)? = nil      // fractions 0..1 of the width
    @State private var frozen: [TrendPoint]? = nil

    struct TimeBase: Hashable { let label: String; let seconds: Double }
    static let windows = [TimeBase(label: "10 s", seconds: 10), TimeBase(label: "30 s", seconds: 30),
                          TimeBase(label: "1 min", seconds: 60), TimeBase(label: "2 min", seconds: 120),
                          TimeBase(label: "5 min", seconds: 300), TimeBase(label: "10 min", seconds: 600)]

    var points: [TrendPoint] { frozen ?? meter.session.trendInScale() }

    var body: some View {
        BenchPage(title: "Scope") {
            HStack {
                Picker("Time base", selection: $window) {
                    ForEach(Self.windows, id: \.self) { Text($0.label).tag($0.seconds) }
                }
                .pickerStyle(.segmented)
            }
            TrendCanvas(points: points, window: window, cursors: $cursors)
                .frame(height: 300)
            HStack {
                Button(frozen == nil ? "Stop" : "Run") { frozen = frozen == nil ? meter.session.trendInScale() : nil }
                    .benchButton(accent: frozen != nil)
                Button(cursors == nil ? "Cursors" : "Cursors off") { cursors = cursors == nil ? (0.3, 0.7) : nil }
                    .benchButton()
                Spacer()
                Text(meter.session.last?.unit ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(Bench.dim(scheme))
            }
            if let c = cursors { CursorReadout(points: points, window: window, cursors: c) }
            Text("Drag a cursor on the trace to move it. The trace shows the readings of the present mode, unit and range; up to 6000 readings are kept.")
                .font(.caption).foregroundStyle(Bench.dim(scheme))
        }
    }
}

/// The trace on the scope grid (10 x 8 divisions), newest at the right edge.
struct TrendCanvas: View {
    @Environment(\.colorScheme) private var scheme
    let points: [TrendPoint]
    let window: Double
    var cursors: Binding<(Double, Double)?>?

    static func visible(_ points: [TrendPoint], _ window: Double) -> (ArraySlice<TrendPoint>, Date) {
        let end = points.last?.t ?? Date()
        let start = end.addingTimeInterval(-window)
        let i = points.firstIndex { $0.t >= start } ?? points.count
        return (points[i...], end)
    }

    static func range(_ pts: ArraySlice<TrendPoint>) -> (Double, Double) {
        let vals = pts.compactMap(\.value)
        guard var lo = vals.min(), var hi = vals.max() else { return (0, 1) }
        if hi - lo < 1e-12 {
            let pad = max(abs(hi) * 0.01, 1e-6)
            lo -= pad
            hi += pad
        }
        let pad = (hi - lo) * 0.08
        return (lo - pad, hi + pad)
    }

    var body: some View {
        let (pts, end) = Self.visible(points, window)
        let (lo, hi) = Self.range(pts)
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let gridColor = Bench.grid(scheme)
                    for i in 0...10 {
                        let x = size.width * CGFloat(i) / 10
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(gridColor), lineWidth: i == 5 ? 1 : 0.5)
                    }
                    for i in 0...8 {
                        let y = size.height * CGFloat(i) / 8
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(gridColor), lineWidth: i == 4 ? 1 : 0.5)
                    }
                    var path = Path()
                    var pen = false
                    for p in pts {
                        guard let v = p.value else { pen = false; continue }
                        let x = size.width * CGFloat(1 - end.timeIntervalSince(p.t) / window)
                        let y = size.height * CGFloat(1 - (v - lo) / (hi - lo))
                        if pen { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)) }
                        pen = true
                    }
                    ctx.stroke(path, with: .color(Bench.yellow), lineWidth: 1.5)
                    if let c = cursors?.wrappedValue {
                        for f in [c.0, c.1] {
                            let x = size.width * CGFloat(f)
                            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                       with: .color(Bench.ink(scheme).opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                }
                VStack(alignment: .leading) {
                    Text(axis(hi)).font(.system(size: 10)).monospacedDigit()
                    Spacer()
                    Text(axis(lo)).font(.system(size: 10)).monospacedDigit()
                }
                .foregroundStyle(Bench.dim(scheme))
                .padding(4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                guard let b = cursors, let c = b.wrappedValue else { return }
                let f = min(1, max(0, d.location.x / g.size.width))
                b.wrappedValue = abs(f - c.0) < abs(f - c.1) ? (f, c.1) : (c.0, f)
            }, including: cursors?.wrappedValue == nil ? .subviews : .all)
        }
        .background(Bench.panel(scheme))
        .overlay(Rectangle().stroke(Bench.hairline(scheme), lineWidth: 0.5))
    }

    func axis(_ v: Double) -> String { String(format: "%.4g", v) }
}

struct CursorReadout: View {
    let points: [TrendPoint]
    let window: Double
    let cursors: (Double, Double)

    func value(at f: Double) -> (Date, Double?) {
        let (pts, end) = TrendCanvas.visible(points, window)
        let t = end.addingTimeInterval(-window * (1 - f))
        let near = pts.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
        return (t, near?.value)
    }

    var body: some View {
        let a = value(at: min(cursors.0, cursors.1)), b = value(at: max(cursors.0, cursors.1))
        let dt = b.0.timeIntervalSince(a.0)
        VStack(spacing: 0) {
            ValueRow(label: "Δt", value: String(format: "%.3f s", dt))
            ValueRow(label: "1/Δt", value: dt > 0 ? String(format: "%.4g Hz", 1 / dt) : "—")
            ValueRow(label: "A / B", value: "\(a.1.map { String(format: "%.6g", $0) } ?? "—") / \(b.1.map { String(format: "%.6g", $0) } ?? "—")")
            ValueRow(label: "ΔV (B − A)", value: (a.1 != nil && b.1 != nil) ? String(format: "%.6g", b.1! - a.1!) : "—")
        }
    }
}
