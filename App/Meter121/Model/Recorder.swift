// CSV recording of the readings with their time (companion record.Session.start_recording), into the app's
// Documents/121GW folder, which the Files app shows ("On My iPhone > 121GW").  Which readings get a row is the logging
// trigger's choice (LogTrigger.swift; by default every reading).  With voice notes the file has a "note" column: the rows
// go through a NotePlacer, which holds them a few seconds so a phrase lands in its row.

import Foundation
import Meter121Kit

final class Recorder {
    private(set) var url: URL?
    private(set) var rows = 0
    private(set) var start: Date?
    private var handle: FileHandle?
    private var format: CSVFormat = .comma
    private var pending = ""
    private var placer: NotePlacer?                // voice notes: rows wait here for their phrases
    private var trigger = LogTrigger()             // which readings get a row
    private var flushedAt = Date.distantPast
    private(set) var notes = 0

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("121GW", isDirectory: true)
    }

    var active: Bool { handle != nil }

    func begin(format: CSVFormat, notes withNotes: Bool = false, trigger: LogTrigger = LogTrigger()) throws -> URL {
        if let url, handle != nil { return url }
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let u = folder.appendingPathComponent(Session.recordingName(now))
        let header = Session.csvLine(withNotes ? Session.csvHeaderNotes : Session.csvHeader, format: format)
        try Data(header.utf8).write(to: u)
        handle = try FileHandle(forWritingTo: u)
        try handle?.seekToEnd()
        self.format = format
        url = u
        rows = 0
        start = now
        pending = ""
        self.trigger = trigger
        flushedAt = now
        placer = withNotes ? NotePlacer() : nil
        notes = 0
        return u
    }

    /// A reading with its limit verdict (nil without a limit); written when the trigger says so.  In voice mode every
    /// reading goes to the placer and the rows without a note are dropped when it hands them out.
    func add(_ r: Reading, verdict: String? = nil) {
        guard handle != nil, trigger.accept(r, verdict: verdict) else { return }
        if trigger.mode != .voice { rows += 1 }
        if let placer {
            write(placer.add(r))
        } else {
            pending += Session.csvRow(r, format: format)
        }
        // a sparse trigger would keep a row in memory for minutes: write at least once a second
        if rows % 50 == 0 || (!pending.isEmpty && Date().timeIntervalSince(flushedAt) >= 1) { flush() }
    }

    /// A voice note; it is written with its row (or alone, when it came too late for it).
    func add(_ p: NotePhrase) {
        guard handle != nil, let placer else { return }
        notes += 1
        write(placer.add(p))
    }

    private func write(_ out: [NoteRow]) {
        for row in out where trigger.mode != .voice || LogTrigger.keepsVoiceRow(row) {
            if trigger.mode == .voice && row.reading != nil { rows += 1 }
            pending += Session.csvRow(row, format: format)
        }
    }

    @discardableResult
    func end() -> URL? {
        if let placer { write(placer.finish()) }
        placer = nil
        flush()
        try? handle?.close()
        handle = nil
        return url
    }

    private func flush() {
        guard let h = handle, !pending.isEmpty else { return }
        try? h.write(contentsOf: Data(pending.utf8))
        pending = ""
        flushedAt = Date()
    }

    struct File: Identifiable {
        let url: URL
        let size: Int
        let date: Date
        var id: URL { url }
    }

    /// The recordings in the folder, newest first (at most 50).
    static func list() -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "csv" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return File(url: u, size: v?.fileSize ?? 0, date: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }.prefix(50).map { $0 }
    }
}
