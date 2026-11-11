// CSV recording of every reading with its time (companion record.Session.start_recording), into the app's
// Documents/121GW folder, which the Files app shows ("On My iPhone > 121GW").

import Foundation
import Meter121Kit

final class Recorder {
    private(set) var url: URL?
    private(set) var rows = 0
    private(set) var start: Date?
    private var handle: FileHandle?
    private var format: CSVFormat = .comma
    private var pending = ""

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("121GW", isDirectory: true)
    }

    var active: Bool { handle != nil }

    func begin(format: CSVFormat) throws -> URL {
        if let url, handle != nil { return url }
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let u = folder.appendingPathComponent(Session.recordingName(now))
        let header = Session.csvLine(Session.csvHeader, format: format)
        try Data(header.utf8).write(to: u)
        handle = try FileHandle(forWritingTo: u)
        try handle?.seekToEnd()
        self.format = format
        url = u
        rows = 0
        start = now
        pending = ""
        return u
    }

    func add(_ r: Reading) {
        guard handle != nil else { return }
        pending += Session.csvRow(r, format: format)
        rows += 1
        if rows % 50 == 0 { flush() }
    }

    @discardableResult
    func end() -> URL? {
        flush()
        try? handle?.close()
        handle = nil
        return url
    }

    private func flush() {
        guard let h = handle, !pending.isEmpty else { return }
        try? h.write(contentsOf: Data(pending.utf8))
        pending = ""
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
