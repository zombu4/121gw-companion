// LOG: start / stop a CSV recording of the readings, and the recordings in Documents/121GW (also in the Files app
// under "On My iPhone > 121GW"), each to share or delete.  Trigger: which readings get a row, by the meter's own rules
// (interval, on change, on limit verdict) or by voice (LogTrigger.swift; issue 40).  Voice notes: what is said while
// recording goes into a "note" column of the file, recognised on the iPhone (VoiceNotes.swift).

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
                        Text("The readings the trigger below picks, with their time, go to a CSV file.").font(.footnote).foregroundStyle(Bench.dim(scheme))
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
            trigger
            if !meter.voiceStatus.isEmpty {
                Text(meter.voiceStatus).font(.footnote).foregroundStyle(Bench.dim(scheme))
            }
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
        .onChange(of: meter.prefs.voiceNotes) { _, on in
            if !on && meter.prefs.logTrigger == .voice { meter.prefs.logTrigger = .every }   // voice needs the notes
        }
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

    /// The trigger: which readings get a row.  The interval and the threshold start from the meter's In and Ch (last
    /// settings read), else 1 s and 10; what the user types stays.
    @ViewBuilder private var trigger: some View {
        let mode = meter.prefs.logTrigger
        let busy = meter.recording || meter.recordingClosing
        Hairline()
        Picker("Trigger", selection: Binding(get: { meter.prefs.logTrigger }, set: {
            meter.prefs.logTrigger = $0
            if $0 == .voice { meter.prefs.voiceNotes = true }       // on voice needs the voice notes: this switches them on
        })) {
            ForEach(LogTriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .disabled(busy)
        if mode == .interval || mode == .change || mode == .limit {
            numberField(mode == .interval ? "Interval (s, 0 = every reading)" : "Also every (s, 0 = off)", 0...999,
                        Binding(get: { meter.prefs.triggerInterval }, set: { meter.prefs.logInterval = $0 }))
        }
        if mode == .change {
            numberField("Threshold (counts)", 1...255, Binding(get: { meter.prefs.triggerChange }, set: { meter.prefs.logChange = $0 }))
        }
        Text(triggerHelp(mode)).font(.footnote).foregroundStyle(Bench.dim(scheme))
        if mode == .limit && meter.prefs.derived.limit == nil {
            Text("No limit is set (Live page, Derived, Options): there is no verdict, so only the first reading"
                 + (meter.prefs.triggerInterval > 0 ? " and a row every \(meter.prefs.triggerInterval) s are written." : " is written."))
                .font(.footnote).foregroundStyle(Bench.bad)
        }
        Hairline()
    }

    private func numberField(_ title: String, _ range: ClosedRange<Int>, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80).monospacedDigit()
        }
        .disabled(meter.recording || meter.recordingClosing)
    }

    private func triggerHelp(_ mode: LogTriggerMode) -> String {
        let p = meter.prefs
        switch mode {
        case .every: return "A row for every reading."
        case .interval: return "A row every \(p.triggerInterval) s" + (p.triggerInterval == 0 ? " (every reading)." : ".")
        case .change:
            return "A row when the reading has changed by \(p.triggerChange) counts (the displayed digits) since the last row, "
                + "checked once a second; a change of mode, unit or range, or between a number and OFL, counts too"
                + (p.triggerInterval > 0 ? ". Also a row every \(p.triggerInterval) s." : ".")
        case .limit:
            return "A row when the verdict (PASS / HI / LO of your limits) changes" + (p.triggerInterval > 0
                ? ". Also a row every \(p.triggerInterval) s while the reading is outside the limits." : ".")
        case .voice: return "A row only where a spoken sentence is placed, with its note; switches the voice notes on."
        }
    }

    func refresh() { files = Recorder.list() }
}
