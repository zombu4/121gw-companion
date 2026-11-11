// CARD: the meter's SD card while it shows the page Ld-bt (firmware F-1.05 or newer): the files with size, date and
// time, download (each window checked with a CRC-32), delete (cal.bin, EEVBlog.bin and BTLOAD.TMP are protected),
// free space, sync to a folder, format.  Companion CARD page.

import Meter121Kit
import SwiftUI

struct CardView: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var toDelete: CardFile?
    @State private var formatting = false
    @State private var formatWord = ""
    @State private var leaveError: String?

    var lock: String? { meter.card.busy ? nil : meter.lockReason }

    var body: some View {
        BenchPage(title: "Card") {
            if let lock {
                NoteText(text: lock + ". On the meter: SETUP until the page Ld, Bluetooth on (Ld-bt), logging off.")
            }
            HStack {
                Button(meter.card.listed ? "Refresh" : "List files") { meter.cardList() }.benchButton(accent: true)
                Button("Sync to folder") { meter.cardSync() }.benchButton()
                Spacer()
                if meter.card.busy { Button("Stop") { meter.cardStop() }.benchButton() }
            }
            .disabled(lock != nil)
            if meter.card.busy {
                VStack(alignment: .leading, spacing: 4) {
                    Caption(meter.card.op + "…")
                    ProgressView(value: meter.card.progress).tint(Bench.yellow)
                }
            }
            if let e = meter.card.error { Text(e).font(.footnote).foregroundStyle(Bench.bad) }
            if !meter.card.result.isEmpty { Text(meter.card.result).font(.footnote).foregroundStyle(Bench.dim(scheme)) }
            if let free = meter.card.free, let total = meter.card.total {
                ValueRow(label: "Free", value: ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)
                    + " of " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))
            }
            if let s = meter.card.lastSync {
                ValueRow(label: "Last sync", value: s.formatted(date: .abbreviated, time: .standard))
            }
            Hairline()
            Caption("Files")
            if meter.card.listed && meter.card.files.isEmpty {
                Text("No files on the card.").font(.footnote).foregroundStyle(Bench.dim(scheme))
            }
            ForEach(meter.card.files) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.system(size: 14, design: .monospaced))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file) + "  " + f.date + " " + f.time)
                            .font(.caption).monospacedDigit().foregroundStyle(Bench.dim(scheme))
                    }
                    Spacer()
                    Button { meter.cardDownload(f) } label: { Image(systemName: "arrow.down.circle") }
                        .disabled(lock != nil || meter.card.busy)
                    Button { toDelete = f } label: { Image(systemName: "trash") }
                        .disabled(lock != nil || meter.card.busy || CardProtocol.isProtected(f.name))
                        .padding(.leading, 12)
                }
                .padding(.vertical, 4)
                Hairline()
            }
            Text("Downloads and the sync go to the Files app: On My iPhone › 121GW › card. The sync copies new or changed files and never deletes anything there.")
                .font(.caption).foregroundStyle(Bench.dim(scheme))
            Hairline()
            HStack {
                if meter.desk && meter.has(.leaveLd) {
                    Button("Leave page Ld") {
                        Task { do { try await meter.leaveLd() } catch { leaveError = error.localizedDescription } }
                    }
                    .benchButton()
                    .disabled(meter.card.busy)
                }
                Spacer()
                Button("Format card…", role: .destructive) { formatting = true }
                    .benchButton()
                    .disabled(lock != nil || meter.bootloader == "EEV")
            }
            if let leaveError { Text(leaveError).font(.footnote).foregroundStyle(Bench.bad) }
        }
        .confirmationDialog("Delete \(toDelete?.name ?? "")?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete from the card", role: .destructive) {
                if let f = toDelete { meter.cardDelete(f) }
                toDelete = nil
            }
        }
        .alert("Format the card?", isPresented: $formatting) {
            TextField("Type FORMAT", text: $formatWord)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Format", role: .destructive) {
                meter.cardFormat(confirm: formatWord)
                formatWord = ""
            }
            Button("Cancel", role: .cancel) { formatWord = "" }
        } message: {
            Text("Everything on the card is erased and it is formatted as exFAT (firmware F-1.09 or newer with the two-part bootloader). Type FORMAT to go on.")
        }
    }
}
