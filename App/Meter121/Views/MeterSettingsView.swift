// METER SETTINGS: the meter's SETUP settings read and changed from the phone while it shows the page Ld-bt
// (firmware F-1.05 or newer): each row with its full name, the meter's page and the value as the meter shows it.
// Companion METER SETTINGS page (GitHub issue 35).

import Meter121Kit
import SwiftUI

struct MeterSettingsView: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var busy = false

    var body: some View {
        BenchPage(title: "Meter settings") {
            if let lock = meter.lockReason { NoteText(text: lock) }
            HStack {
                Button(meter.settings.items.isEmpty ? "Read settings" : "Read again") {
                    run { await meter.settingsGet() }
                }
                .benchButton(accent: true)
                .disabled(meter.lockReason != nil || busy)
                Spacer()
                if busy { ProgressView() }
            }
            if let e = meter.settings.error { Text(e).font(.footnote).foregroundStyle(Bench.bad) }
            ForEach(meter.settings.items) { item in
                SettingRow(item: item, enabled: meter.lockReason == nil && !busy) { v in
                    run { await meter.settingsPut(item.id, v) }
                }
                Hairline()
            }
            Text("Each change is written as the meter's own page stores it, then read back. Calibration, the serial number and the rotary memory cannot be reached.")
                .font(.caption).foregroundStyle(Bench.dim(scheme))
        }
    }

    func run(_ f: @escaping () async -> Void) {
        busy = true
        Task {
            await f()
            busy = false
        }
    }
}

struct SettingRow: View {
    @Environment(\.colorScheme) private var scheme
    let item: SettingItem
    let enabled: Bool
    let set: (Int) -> Void

    func shown(_ v: Int) -> String {
        if let t = item.texts { return t[v - item.min] }
        let x = Double(v) * item.scale
        let num = item.scale < 1 ? String(format: "%.1f", x) : String(format: "%.0f", x)
        return num + (item.unit.map { $0.isEmpty ? "" : " \($0)" } ?? "")
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14))
                Text(item.tag).font(.caption).foregroundStyle(Bench.dim(scheme))
            }
            Spacer()
            if item.texts != nil && item.max - item.min < 8 {
                Menu {
                    ForEach(item.min...item.max, id: \.self) { v in
                        Button(shown(v)) { if v != item.value { set(v) } }
                    }
                } label: {
                    Text(item.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Bench.yellow)
                }
                .disabled(!enabled)
            } else {
                Stepper {
                    Text(shown(item.value)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                } onIncrement: {
                    if item.value < item.max { set(item.value + 1) }
                } onDecrement: {
                    if item.value > item.min { set(item.value - 1) }
                }
                .fixedSize()
                .disabled(!enabled)
            }
        }
        .padding(.vertical, 4)
    }
}
