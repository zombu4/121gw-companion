// Derived values on the LIVE page (companion state.derived): REL in percent, 4-20 / 0-20 mA loop percent, Pt100 /
// Pt1000 temperature from ohms (IEC 60751), a limit test with your own limits.  Computed on the phone.

import Meter121Kit
import SwiftUI

struct DerivedPanel: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false

    var body: some View {
        let d = meter.derived
        let o = meter.prefs.derived
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Caption("Derived")
                Spacer()
                Button("Options") { editing = true }.font(.system(size: 12, weight: .semibold))
            }
            HStack(spacing: 0) {
                cell("REL", d.relPct.map { String(format: "%+.3f %%", $0) } ?? "—")
                cell("Loop \(o.loopRange.rawValue) mA", d.loopPct.map { String(format: "%.2f %%", $0) } ?? "—")
                cell(o.ptType?.rawValue ?? "Pt", d.ptC.map { String(format: "%.2f °C", $0) } ?? "—")
                cell("Limit", d.verdict ?? "—", color: d.verdict == "PASS" ? Bench.good : d.verdict == nil ? nil : Bench.bad)
            }
        }
        .sheet(isPresented: $editing) { DerivedOptionsSheet() }
    }

    func cell(_ k: String, _ v: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 10, weight: .semibold)).foregroundStyle(Bench.dim(scheme)).lineLimit(1)
            Text(v).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(color ?? Bench.ink(scheme))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DerivedOptionsSheet: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.dismiss) private var dismiss
    @State private var lo = ""
    @State private var hi = ""
    @State private var unit = ""
    @State private var error: String?

    static let units = ["V", "mV", "A", "mA", "µA", "Ω", "kΩ", "MΩ", "Hz", "kHz", "nF", "µF", "°C", "°F", "%"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Current loop (DC current modes)") {
                    Picker("Range", selection: $meter.prefs.derived.loopRange) {
                        ForEach(LoopRange.allCases, id: \.self) { Text($0.rawValue + " mA").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("RTD sensor (OHM mode)") {
                    Picker("Sensor", selection: $meter.prefs.derived.ptType) {
                        Text("Off").tag(PtType?.none)
                        ForEach(PtType.allCases, id: \.self) { Text($0.rawValue).tag(PtType?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Limit test") {
                    TextField("Low limit", text: $lo).keyboardType(.numbersAndPunctuation)
                    TextField("High limit", text: $hi).keyboardType(.numbersAndPunctuation)
                    Picker("Unit", selection: $unit) {
                        ForEach(Self.units, id: \.self) { Text($0).tag($0) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Button("Clear the limits", role: .destructive) {
                        meter.prefs.derived.limit = nil
                        lo = ""
                        hi = ""
                    }
                }
            }
            .navigationTitle("Derived values")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { if save() { dismiss() } } }
            }
            .onAppear {
                let l = meter.prefs.derived.limit
                lo = l?.lo.map { String($0) } ?? ""
                hi = l?.hi.map { String($0) } ?? ""
                unit = l?.unit ?? (Self.units.contains(meter.reading?.unit ?? "") ? meter.reading!.unit : "V")
            }
        }
    }

    func save() -> Bool {
        func num(_ s: String) -> Double?? {
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if t.isEmpty { return .some(nil) }
            return Double(t).map { .some($0) }
        }
        guard let l = num(lo), let h = num(hi) else {
            error = "the limits must be numbers"
            return false
        }
        if let l, let h, l > h {
            error = "the low limit is above the high one"
            return false
        }
        meter.prefs.derived.limit = (l == nil && h == nil) ? nil : Limit(lo: l, hi: h, unit: unit)
        return true
    }
}
