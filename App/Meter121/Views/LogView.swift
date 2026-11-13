// LOG: start / stop a CSV recording of every reading, and the recordings in Documents/121GW (also in the Files app
// under "On My iPhone > 121GW"), each to share or delete.  Voice notes: what is said while recording goes into a
// "note" column of the file, recognised on the iPhone (VoiceNotes.swift).

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
                    Caption(meter.recording ? "Recording" : meter.recordingClosing ? "Writing the last note" : "Not recording")
                    if meter.recording, let u = meter.recordingURL {
                        Text(u.lastPathComponent).font(.system(size: 14, weight: .medium))
                        Text("\(meter.recordingRows) readings" + (meter.voiceListening ? " · \(meter.voiceNotes) notes" : "")
                             + (meter.recordingStart.map { " since " + $0.formatted(date: .omitted, time: .standard) } ?? ""))
                            .font(.footnote).monospacedDigit().foregroundStyle(Bench.dim(scheme))
                    } else {
                        Text("Every reading with its time goes to a CSV file.").font(.footnote).foregroundStyle(Bench.dim(scheme))
                    }
                }
                Spacer()
                Button(meter.recording ? "Stop" : "Record") {
                    error = nil
                    if meter.recording {
                        meter.stopRecording()
                    } else {
                        Task {
                            do { try await meter.startRecording() } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                .benchButton(accent: !meter.recording)
                .disabled(meter.recordingClosing)
            }
            Toggle(isOn: $meter.prefs.voiceNotes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice notes").font(.system(size: 15, weight: .semibold))
                    Text("While recording, what you say is written into a \"note\" column next to the readings. "
                         + "Recognised on this iPhone only; no audio is kept.")
                        .font(.footnote).foregroundStyle(Bench.dim(scheme))
                }
            }
            .tint(Bench.yellow)
            .disabled(meter.recording || meter.recordingClosing)
            if meter.voiceListening {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "mic.fill").foregroundStyle(Bench.yellow)
                    Text(meter.voiceHeard.isEmpty ? "Listening…" : "“\(meter.voiceHeard)”")
                        .font(.footnote).foregroundStyle(Bench.dim(scheme)).lineLimit(3)
                }
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
        .onChange(of: meter.recordingClosing) { _, _ in refresh() }
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
