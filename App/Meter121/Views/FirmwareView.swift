// FIRMWARE: the update notice ("Update both", "Firmware only", "Bootloader only", "Later"), the running update, the
// table of every published release to install (also older ones), and a .bin file of your own (companion METER view).

import Meter121Kit
import SwiftUI
import UniformTypeIdentifiers

struct FirmwareSection: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var kind = Releases.Kind.firmware
    @State private var pending: (InstallPick, InstallPlan)?
    @State private var word = ""
    @State private var importing = false
    @State private var fileError: String?
    @State private var checking = false

    var u: UpdateState { meter.update }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption("Firmware updates")
            if u.active {
                running
            } else {
                notice
            }
            if !u.lastTransfer.isEmpty {
                Text("Last transfer: " + u.lastTransfer).font(.caption).foregroundStyle(Bench.dim(scheme))
            }
            Hairline()
            HStack {
                Picker("Kind", selection: $kind) {
                    Text("Firmware").tag(Releases.Kind.firmware)
                    Text("Bootloader").tag(Releases.Kind.bootloader)
                }
                .pickerStyle(.segmented)
                Button(checking ? "…" : "Refresh list") {
                    checking = true
                    Task {
                        await meter.checkRelease(force: true)
                        checking = false
                    }
                }
                .benchButton()
            }
            ForEach(u.latest[kind] ?? []) { e in releaseRow(e) }
            if (u.latest[kind] ?? []).isEmpty {
                Text(u.checkError.isEmpty ? "The list is read when a meter is connected, and with Refresh list." : u.checkError)
                    .font(.caption).foregroundStyle(Bench.dim(scheme))
            }
            HStack {
                Button("Install a file of your own…") { importing = true }.benchButton()
                    .disabled(!meter.connected || u.active)
                Spacer()
            }
            if let fileError { Text(fileError).font(.footnote).foregroundStyle(Bench.bad) }
            if let a = u.appNewer {
                Link("A newer version of this app exists: \(a.text)", destination: Releases.pageURL(a.tag)).font(.footnote)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            fileError = nil
            guard case let .success(url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: url), d.count <= 368_640 else {
                fileError = "the file could not be read or is larger than 368640 bytes"
                return
            }
            let (pick, why) = meter.stageFile(name: url.lastPathComponent, data: [UInt8](d))
            if let pick { ask(pick) } else { fileError = "refused: " + (why ?? "") }
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil; word = "" } })) {
            if let p = pending { confirmSheet(p.0, p.1) }
        }
    }

    // MARK: pieces

    @ViewBuilder var notice: some View {
        switch u.phase {
        case .available where !u.later:
            let parts = [u.firmware.map { "firmware \($0.text)" }, u.bootloader.map { "bootloader \($0.text)" }].compactMap { $0 }
            Text("Newer: " + parts.joined(separator: " and ")).font(.system(size: 15, weight: .semibold))
            if meter.bootloader == "EEV" && u.firmware != nil {
                Text("This meter has EEVblog's bootloader: the firmware goes to the SD card on the page Ld-bt, then the key sequence installs it.")
                    .font(.footnote).foregroundStyle(Bench.dim(scheme))
            }
            HStack {
                if u.firmware != nil && u.bootloader != nil {
                    Button("Update both") { meter.runUpdate("both") }.benchButton(accent: true)
                }
                if u.firmware != nil { Button("Firmware only") { meter.runUpdate("firmware") }.benchButton(accent: u.bootloader == nil) }
                if u.bootloader != nil { Button("Bootloader only") { meter.runUpdate("bootloader") }.benchButton() }
                Button("Later") { meter.update.later = true }.benchButton()
            }
        case .done:
            Text("Update done." + (u.message.isEmpty ? "" : " " + u.message)).font(.footnote)
        case .error:
            Text("Update stopped: " + u.message).font(.footnote).foregroundStyle(Bench.bad)
        default:
            if let c = u.checked {
                Text("Up to date (checked \(c.formatted(date: .omitted, time: .shortened))).").font(.footnote).foregroundStyle(Bench.dim(scheme))
            } else if !u.checkError.isEmpty {
                Text(u.checkError).font(.footnote).foregroundStyle(Bench.dim(scheme))
            }
        }
    }

    @ViewBuilder var running: some View {
        let label: String = {
            switch u.phase {
            case .downloading: return u.message
            case .waitingLd: return "Show the SETUP page Ld-bt on the meter (Bluetooth on, logging off) to receive \(u.step)."
            case .restarting: return "The meter restarts: \(u.message)."
            case .sending: return "Sending \(u.step)…"
            default: return u.message
            }
        }()
        Text(label).font(.system(size: 14, weight: .semibold))
        if u.phase == .sending {
            ProgressView(value: Double(u.done), total: Double(max(1, u.total))).tint(Bench.yellow)
            Text("\(u.done) of \(u.total) bytes").font(.caption).monospacedDigit().foregroundStyle(Bench.dim(scheme))
        } else {
            ProgressView().tint(Bench.yellow)
        }
        Text("Keep the phone near the meter and this app open until the update is done.").font(.caption).foregroundStyle(Bench.dim(scheme))
        Button("Cancel") { meter.cancelUpdate() }.benchButton()
    }

    func releaseRow(_ e: Releases.Entry) -> some View {
        let pick = InstallPick(kind: kind, text: e.text, tag: e.tag, data: nil, expect: e.text)
        let plan = meter.plan(for: pick)
        let names: [InstallPlan.Relation: String] = [.newer: "newer", .same: "installed", .older: "older",
                                                     .unknown: "unknown", .custom: ""]
        let relation = plan.needsMeter ? "connect the meter" : plan.refusal != nil ? "refused" : names[plan.relation] ?? ""
        let action = plan.relation == .same ? "Reinstall" : plan.relation == .older ? "Go back…" : "Install"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text([e.published, relation].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Bench.dim(scheme))
            }
            Spacer()
            Button(action) { ask(pick) }
                .benchButton()
                .disabled(plan.refusal != nil || u.active)
        }
    }

    func ask(_ pick: InstallPick) {
        let plan = meter.plan(for: pick)
        if let r = plan.refusal {
            fileError = r
            return
        }
        if plan.needsConfirm {
            pending = (pick, plan)
        } else {
            meter.runUpdate(pick.kind == .firmware ? "firmware" : "bootloader", picks: [pick.kind: pick])
        }
    }

    func confirmSheet(_ pick: InstallPick, _ plan: InstallPlan) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Install \(plan.label) as \(plan.kind.rawValue)?").font(.headline)
                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, w in Text(w).font(.callout) }
                    TextField("Type \(InstallPlan.word) to go on", text: $word)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Install") {
                        meter.runUpdate(pick.kind == .firmware ? "firmware" : "bootloader", picks: [pick.kind: pick])
                        pending = nil
                        word = ""
                    }
                    .benchButton(accent: true)
                    .disabled(word != InstallPlan.word)
                }
                .padding(16)
            }
            .navigationTitle("Check first")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pending = nil; word = "" } } }
        }
    }
}
