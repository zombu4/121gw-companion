// The diagnosis report (METER view, "Save report"): one text file with what the app knows about the meter and the
// link, to attach to a GitHub issue (companion report.py).  Anonymised over the whole text at the end: no Bluetooth
// identifier, no UUID, no MAC address, no file path.

import Foundation
import Meter121Kit
import UIKit

extension MeterController {
    static let xdiagStatusFirst = 40, mclockStatusFirst = 49

    /// The meter's nine link counters and its clock measurement (setting "Extended diagnosis", F-1.15 / F-1.17 on):
    /// on page Ld the STATUS values, else the key codes 0x95 / 0x96.
    func xdiagCollect() async -> [String] {
        guard prefs.extendedDiagnosis else { return ["  off (App settings: Extended diagnosis)"] }
        guard connected else { return ["  not connected to a meter"] }
        guard has(.extendedDiagnosis) else { return ["  not supported by this firmware (\(version ?? "?"); F-1.15 or newer needed)"] }
        var out: [String] = []
        do {
            let (values, clock): ([Int], Frames.ClockMeasurement?) = try await ops("diagnosis report", needDesk: false, wait: 2.5) { s in
                if self.desk {
                    let v = try await (0..<9).asyncMap { try await s.statusValue(Self.xdiagStatusFirst + $0) }
                    var c: Frames.ClockMeasurement?
                    if self.has(.clockMeasurement) {
                        let m = try await (0..<7).asyncMap { try await s.statusValue(Self.mclockStatusFirst + $0) }
                        c = Frames.mclockFromStatus(m)
                    }
                    return (v, c)
                }
                self.xdiagFrame = nil
                guard try await self.keyWithEcho(0x95) else { throw OpsError.refused("no echo of the counters request") }
                await self.waitFor(Self.xdiagWait) { self.xdiagFrame != nil }
                guard let f = self.xdiagFrame else { throw OpsError.refused("the meter sent no counters (is the diagnosis on? it is switched on at connection)") }
                var c: Frames.ClockMeasurement?
                if self.has(.clockMeasurement) {
                    self.mclockFrame = nil
                    if try await self.keyWithEcho(0x96) {
                        await self.waitFor(Self.xdiagWait) { self.mclockFrame != nil }
                        c = self.mclockFrame.map(Frames.mclockValues)
                    }
                }
                return (Frames.xdiagValues(f), c)
            }
            for (n, v) in zip(Frames.xdiagNames, values) {
                out.append("  " + n.padding(toLength: 44, withPad: " ", startingAt: 0) + " \(v)")
            }
            if let clock { out.append("[meter clock]"); out += Frames.mclockLines(clock) }
        } catch {
            out.append("  error: \(error.localizedDescription)")
        }
        return out
    }

    func buildReport() async -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func t(_ d: Date) -> String { df.string(from: d) }
        func row(_ k: String, _ v: String) -> String { "  " + k.padding(toLength: 26, withPad: " ", startingAt: 0) + " " + v }
        var L: [String] = []
        L.append("121GW iPhone app diagnosis report, \(t(Date()))")
        L.append("")
        L.append("[app]")
        L.append(row("version", AppInfo.version))
        L.append(row("system", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(UIDevice.current.model)"))
        L.append("[meter]")
        L.append(row("firmware", version ?? fwKind.rawValue))
        L.append(row("bootloader", bootloader ?? "not reported"))
        L.append(row("mode", mode.rawValue + (desk ? ", page Ld" : "")))
        if let r = reading { L.append(row("last reading", "\(r.modeName) \(r.text) \(r.unit), raw \(Frames.hexSpaced(r.raw))")) }
        L.append("[link]")
        L.append(row("state", link.state.rawValue + (link.detail.isEmpty ? "" : ": \(link.detail)")))
        L.append(row("bytes received", "\(link.rxBytes), \(link.reassembler.dropped) skipped as damaged"))
        let st = link.stats
        L.append(row("notifications", "\(st.notifications); sizes 1-20: \(st.sizes[0]), 21-64: \(st.sizes[1]), 65-244: \(st.sizes[2]), larger: \(st.sizes[3])"))
        func ms(_ x: Double?) -> String { x.map { String(format: "%.0f ms", $0 * 1000) } ?? "—" }
        L.append(row("gaps", "median \(ms(LinkStatistics.percentile(st.gaps, 0.5))), 95 % \(ms(LinkStatistics.percentile(st.gaps, 0.95))), max \(ms(st.gaps.max()))"))
        L.append(row("writes", "\(st.writes), \(st.writeErrors) failed; confirmed after median \(ms(LinkStatistics.percentile(st.writeTimes, 0.5))), max \(ms(st.writeTimes.max()))"))
        L.append(row("signal at discovery", st.rssi.suffix(5).map { "#\($0.0): \($0.1.map { "\($0) dBm" } ?? "?")" }.joined(separator: ", ")))
        L.append(row("MTU", st.mtu.map(String.init) ?? "—"))
        L.append(row("status frames", "\(statusFrames)" + (framesPerSecond.map { String(format: ", %.1f / s", $0) } ?? "")))
        L.append(row("link 2", l2c.on ? "on, pace \(Self.paceTicks[l2c.pace]) ticks; \(link.link2.stats)" : "off"))
        L.append(row("heartbeat", "\(hb.sent) sent, \(hb.probes) checks, \(hb.dead) dead links"))
        L.append(row("disconnects", "\(st.disconnectCount)"))
        for d in st.disconnects.suffix(10) { L.append("    \(t(d.0)) \(d.1 ? "by the user" : d.2)") }
        let pieces = link.damaged()
        if !pieces.isEmpty {
            L.append("  damaged pieces (length: first bytes):")
            for (n, b) in pieces { L.append("    \(n): \(Frames.hexSpaced(b))") }
        }
        L.append("[meter link counters]")
        L += await xdiagCollect()
        L.append("[update]")
        L.append(row("state", update.phase.rawValue + (update.message.isEmpty ? "" : ": \(update.message)")))
        L.append(row("last transfer", update.lastTransfer.isEmpty ? "—" : update.lastTransfer))
        L.append("[transfer diagnosis]")
        L.append(diag.text.isEmpty ? "  not read" : "  " + diag.text)
        if !diag.values.isEmpty { L.append("  STATUS: " + diag.values.map(String.init).joined(separator: " ")) }
        L.append("[meter settings as last read]")
        if settings.items.isEmpty { L.append("  not read") }
        for i in settings.items { L.append(row(i.tag, "\(i.text)  (\(i.name))")) }
        L.append("[app settings]")
        L.append(row("CSV format", prefs.csvFormat))
        L.append(row("clock on connect", prefs.clockOnConnect ? "on" : "off"))
        L.append(row("update check", prefs.updateCheck.rawValue))
        L.append(row("extended diagnosis", prefs.extendedDiagnosis ? "on" : "off"))
        L.append("[events]")
        for e in events { L.append("  \(t(e.t)) \(e.text)") }
        return Self.anonymise(L.joined(separator: "\n") + "\n")
    }

    static func anonymise(_ text: String) -> String {
        var s = text
        let patterns = [
            "\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\b": "<id>",
            "\\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\\b": "<address>",
            "(?:file://)?/(?:var|private|Users|tmp)/[^\\s,;]*": "<path>",
        ]
        for (p, r) in patterns {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        let name = UIDevice.current.name
        if name.count >= 3 { s = s.replacingOccurrences(of: name, with: "<device>") }
        return s
    }

    /// The report written to a temporary file for the share sheet.
    func saveReport() async -> URL? {
        let text = await buildReport()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("121GW_report_\(f.string(from: Date())).txt")
        do {
            try Data(text.utf8).write(to: u, options: .atomic)
            return u
        } catch {
            event("report: \(error.localizedDescription)")
            return nil
        }
    }
}

extension Sequence {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for x in self { out.append(try await f(x)) }
        return out
    }
}
