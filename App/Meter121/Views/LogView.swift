// LOG: start / stop a CSV recording of every reading, and the recordings in Documents/121GW (also in the Files app
// under "On My iPhone > 121GW"), each to share or delete.

import Meter121Kit
import SwiftUI

struct LogView: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme
    @State private var files: [Recorder.File] = []
    @State private var error: String?
    @State private var toDelete: URL?

    var body: some View {
        BenchPage(title: "Log") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Caption(meter.recording ? "Recording" : "Not recording")
                    if meter.recording, let u = meter.recordingURL {
                        Text(u.lastPathComponent).font(.system(size: 14, weight: .medium))
                        Text("\(meter.recordingRows) readings" + (meter.recordingStart.map { " since " + $0.formatted(date: .omitted, time: .standard) } ?? ""))
                            .font(.footnote).monospacedDigit().foregroundStyle(Bench.dim(scheme))
                    } else {
                        Text("Every reading with its time goes to a CSV file.").font(.footnote).foregroundStyle(Bench.dim(scheme))
                    }
                }
                Spacer()
                Button(meter.recording ? "Stop" : "Record") {
                    if meter.recording {
                        meter.stopRecording()
                        refresh()
                    } else {
                        do { try meter.startRecording() } catch { self.error = error.localizedDescription }
                    }
                }
                .benchButton(accent: !meter.recording)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Bench.bad) }
            Hairline()
            Caption("Recordings")
            if files.isEmpty {
                Text("No recordings yet.").font(.footnote).foregroundStyle(Bench.dim(scheme))
            }
            ForEach(files) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.url.lastPathComponent).font(.system(size: 14))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file) + " · "
                             + f.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(Bench.dim(scheme))
                    }
                    Spacer()
                    ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }
                    Button { toDelete = f.url } label: { Image(systemName: "trash") }
                        .disabled(meter.recording && f.url == meter.recordingURL)
                        .padding(.leading, 12)
                }
                .padding(.vertical, 4)
                Hairline()
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: meter.recording) { _, _ in refresh() }
        .confirmationDialog("Delete this recording?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let u = toDelete { try? FileManager.default.removeItem(at: u) }
                toDelete = nil
                refresh()
            }
        } message: {
            Text(toDelete?.lastPathComponent ?? "")
        }
    }

    func refresh() { files = Recorder.list() }
}
