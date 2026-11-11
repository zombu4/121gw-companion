// METER: what runs on the meter (firmware, bootloader), the link, the clock, page Ld and the event log
// (companion METER page).

import Meter121Kit
import SwiftUI

struct MeterInfoView: View {
    @EnvironmentObject var meter: MeterController
    @EnvironmentObject var link: MeterLink
    @Environment(\.colorScheme) private var scheme
    @State private var clockBusy = false
    @State private var clockError: String?
    @State private var leaveError: String?

    var firmwareText: String {
        switch meter.fwKind {
        case .fast: meter.version ?? "?"
        case .other: "not the fast build (no version answer)"
        case .unknown: meter.mode == .bootloader ? "— (update mode)" : (meter.connected ? "asking…" : "—")
        }
    }

    var bootloaderText: String {
        guard let b = meter.bootloader else { return meter.connected ? "not reported" : "—" }
        return b == "EEV" ? "EEVblog original" : b
    }

    var body: some View {
        BenchPage(title: "Meter") {
            Caption("Meter")
            VStack(spacing: 0) {
                ValueRow(label: "Firmware", value: firmwareText)
                ValueRow(label: "Bootloader", value: bootloaderText)
                ValueRow(label: "State", value: meter.mode == .bootloader ? "update mode" : meter.desk ? "page Ld (Ld-bt)" :
                    meter.connected ? (meter.stale ? "no readings" : "readings") : "not connected")
                ValueRow(label: "This app", value: AppInfo.version)
            }
            if meter.desk {
                HStack {
                    Text("Page Ld is shown: the meter sends no readings.").font(.footnote).foregroundStyle(Bench.dim(scheme))
                    Spacer()
                    Button("Leave page Ld") {
                        Task {
                            do { try await meter.leaveLd() } catch { leaveError = error.localizedDescription }
                        }
                    }
                    .benchButton()
                    .disabled(!meter.has(.leaveLd))
                }
                if let leaveError { Text(leaveError).font(.footnote).foregroundStyle(Bench.bad) }
            }
            Hairline()
            Caption("Clock")
            VStack(spacing: 0) {
                ValueRow(label: "Time server", value: meter.prefs.ntpServer)
                ValueRow(label: "Last set to", value: meter.clock.last ?? "—")
                if let o = meter.clock.offset { ValueRow(label: "Phone clock offset", value: String(format: "%+.3f s", o)) }
                if !meter.clock.auto.isEmpty { ValueRow(label: "On connect", value: meter.clock.auto) }
            }
            HStack {
                Button(clockBusy ? "Setting…" : "Sync time") {
                    clockBusy = true
                    clockError = nil
                    Task {
                        do { try await meter.syncTime() } catch { clockError = error.localizedDescription }
                        clockBusy = false
                    }
                }
                .benchButton(accent: true)
                .disabled(!meter.connected || clockBusy || meter.desk)
                Spacer()
            }
            if let clockError { Text(clockError).font(.footnote).foregroundStyle(Bench.bad) }
            Hairline()
            Caption("Link")
            VStack(spacing: 0) {
                ValueRow(label: "Meter", value: link.deviceName ?? "—")
                ValueRow(label: "MTU", value: link.mtu.map { "\($0)" + ($0 == carefulMTU ? " (old BLE112 module)" : "") } ?? "—")
                ValueRow(label: "Readings", value: meter.framesPerSecond.map { String(format: "%.1f / s", $0) } ?? "—")
                ValueRow(label: "Link 2", value: meter.l2c.on ? String(format: "on, %.1f blocks / s", MeterController.blocksPerSecond(meter.l2c.pace)) :
                    meter.link2Supported ? "asked for" : "not used")
                if meter.l2c.on {
                    let s = link.link2.stats
                    ValueRow(label: "Link 2 blocks", value: "\(s.blocks), \(s.corrected) repaired, \(s.lost) lost")
                }
                ValueRow(label: "Notifications", value: "\(link.stats.notifications)")
                ValueRow(label: "Damaged bytes", value: "\(link.reassembler.dropped)")
                ValueRow(label: "Heartbeat", value: "\(meter.hb.sent) sent, \(meter.hb.probes) checks, \(meter.hb.dead) dead links")
                ValueRow(label: "Disconnects", value: "\(link.stats.disconnectCount)")
            }
            Hairline()
            Caption("Events")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(meter.events.suffix(60).reversed()) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text(e.t.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(Bench.dim(scheme))
                        Text(e.text)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}
