// SD card file manager of the meter over the page Ld link: list, read, delete, info, format, and the sync to a
// folder (companion card.py; firmware ble/bftsd.s, requests 0x10..0x15 and 0x1A).
//
// Answer: B5 5B 82 seq(2) len status(1) field(2) data crc16(2), len = 3 + len(data), data <= 232 bytes.  Every request
// is idempotent except DELETE; a request with no answer is sent again.  A window's CRC-32 is checked after all its
// chunks arrived; on a mismatch the chunks are fetched again, then the window is staged again.  Files are written as
// <name>.part and renamed when complete; the sync never deletes local files.

import Foundation

public enum CardProtocol {
    public static let tList: UInt8 = 0x10, tRead: UInt8 = 0x11, tChunk: UInt8 = 0x12, tDelete: UInt8 = 0x13
    public static let tInfo: UInt8 = 0x14, tFormat: UInt8 = 0x15, tReadZ: UInt8 = 0x1A
    public static let tAnswer: UInt8 = 0x82
    public static let formatWord = Array("FORMAT".utf8)
    public static let stOK = 0, stNotNow = 3, stNotFound = 0x20, stName = 0x21, stArg = 0x22, stProtected = 0x23
    public static let stCard = 0x24, stNoFormat = 0x25
    public static let statusText: [Int: String] = [
        0: "accepted",
        3: "not allowed now (a firmware transfer, a restart due or a setting being edited on the meter)",
        0x20: "not found on the card", 0x21: "name refused", 0x22: "argument or value refused", 0x23: "protected file",
        0x24: "card error",
        0x25: "formatting needs the two-part bootloader (EEVblog's bootloader cannot read exFAT cards)",
    ]
    static let cardStep = [1: "open", 2: "seek", 3: "read", 4: "delete", 5: "getfree / close", 6: "format"]
    public static let chunk = Transfer.maxPayload            // 232
    public static let window = 8192
    public static let windowZ = 4096
    public static let listEnd = 0x8000
    public static let nameCut: UInt8 = 0x80
    public static let attrDir: UInt8 = 0x10, attrVolume: UInt8 = 0x08
    public static let maxName = 63
    public static let sector = 512
    public static let protected = ["cal.bin", "eevblog.bin", "btload.tmp"]
    public static let skipSync = ["btload.tmp"]
    public static let manifest = ".121gw-sync.json"

    public static func describe(_ status: Int, _ field: Int = 0) -> String {
        var t = statusText[status] ?? String(format: "status 0x%02X", status)
        if status == stCard { t += " (step \(cardStep[field >> 8] ?? String(field >> 8)), FatFs result \(field & 0xFF))" }
        return t
    }

    /// An answer frame as the meter sends it (the tests' fake meter).
    public static func answerPacket(_ seq: Int, _ status: Int, _ field: Int = 0, _ data: [UInt8] = []) -> [UInt8] {
        Transfer.packet(tAnswer, seq, [UInt8(status), UInt8(field & 0xFF), UInt8(field >> 8)] + data)
    }

    public struct Answer: Equatable, Sendable {
        public var seq: Int, status: Int, field: Int, data: [UInt8]
    }

    public static func parseAnswer(_ f: [UInt8]) -> Answer? {
        guard f.count >= 11, f[2] == tAnswer, f[5] >= 3 else { return nil }
        return Answer(seq: Int(f[3]) | Int(f[4]) << 8, status: Int(f[6]), field: Int(f[7]) | Int(f[8]) << 8,
                      data: Array(f[9..<(6 + Int(f[5]))]))
    }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func nameBytes(_ name: String) -> [UInt8] {
        let raw = Array(name.utf8)
        return [UInt8(raw.count)] + raw
    }

    public static func listRequest(_ start: Int, most: Int? = nil) -> [UInt8] { u16(start) + (most.map { [UInt8($0)] } ?? []) }
    public static func readRequest(_ name: String, _ offset: Int, _ length: Int) -> [UInt8] {
        nameBytes(name) + le32(offset) + u16(length)
    }
    public static func chunkRequest(_ idx: Int, size: Int? = nil) -> [UInt8] { u16(idx) + (size.map { [UInt8($0)] } ?? []) }

    public struct Entry: Equatable, Sendable {
        public var name: String, size: Int, date: String, time: String, attr: UInt8, cut: Bool
        public var isFile: Bool { attr & (attrDir | attrVolume) == 0 && !cut && size != 0xFFFF_FFFF }
    }

    public static func le(_ d: [UInt8], _ o: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | Int(d[o + $1]) << (8 * $1) } }

    public static func parseList(_ field: Int, _ data: [UInt8]) throws -> ([Entry], Bool) {
        let count = field & 0x7FFF, end = field & listEnd != 0
        var pos = 0
        var out: [Entry] = []
        for _ in 0..<count {
            guard pos + 10 <= data.count else { throw CardError("LIST answer cut off") }
            let size = le(data, pos, 4), date = le(data, pos + 4, 2), tm = le(data, pos + 6, 2)
            let attr = data[pos + 8], n = Int(data[pos + 9])
            pos += 10
            guard pos + n <= data.count else { throw CardError("LIST answer cut off") }
            let name = String(data[pos..<(pos + n)].map { Character(Unicode.Scalar($0)) })     // latin-1
            out.append(Entry(name: name, size: size, date: fatDate(date), time: fatTime(tm), attr: attr & 0x7F, cut: attr & nameCut != 0))
            pos += n
        }
        guard pos == data.count else { throw CardError("LIST answer: \(data.count) bytes of data, the entries use \(pos)") }
        return (out, end)
    }

    public static func listAnswer(_ entries: [Entry], end: Bool) -> (Int, [UInt8]) {
        var data: [UInt8] = []
        for e in entries {
            let raw = e.name.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
            data += le32(e.size) + u16(fatDateWord(e.date)) + u16(0) + [e.attr | (e.cut ? nameCut : 0), UInt8(raw.count)] + raw
        }
        return (entries.count | (end ? listEnd : 0), data)
    }

    static func fatDateWord(_ s: String) -> Int {
        let p = s.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? (p[0] - 1980) << 9 | p[1] << 5 | p[2] : 0
    }

    public static func parseReadZ(_ field: Int, _ data: [UInt8]) throws -> (n: Int, crc: UInt32, staged: Int, method: Int) {
        guard data.count == 7 else { throw CardError("READZ answer has \(data.count) bytes of data, expected 7") }
        let crc = UInt32(le(data, 0, 4)), staged = le(data, 4, 2), method = Int(data[6])
        if !(method == 0 || method == 1) || (method == 0 && staged != field) || (method == 1 && !(staged > 0 && staged < field)) {
            throw CardError("READZ answer: method \(method), \(staged) staged for \(field) bytes read")
        }
        return (field, crc, staged, method)
    }

    public static func parseRead(_ field: Int, _ data: [UInt8]) throws -> (n: Int, crc: UInt32) {
        guard data.count == 4 else { throw CardError("READ answer has \(data.count) bytes of data, expected 4") }
        return (field, UInt32(le(data, 0, 4)))
    }

    public static func parseInfo(_ field: Int, _ data: [UInt8]) throws -> (free: Int, total: Int) {
        guard data.count == 8, field != 0 else {
            throw CardError("INFO answer has \(data.count) bytes of data and \(field) sectors per cluster")
        }
        return (le(data, 0, 4) * field * sector, le(data, 4, 4) * field * sector)
    }

    public static func fatDate(_ d: Int) -> String {
        let y = 1980 + (d >> 9), m = (d >> 5) & 15, day = d & 31
        return (1...12).contains(m) && (1...31).contains(day) ? String(format: "%04d-%02d-%02d", y, m, day) : ""
    }

    public static func fatTime(_ t: Int) -> String {
        let h = t >> 11, mi = (t >> 5) & 63, s = (t & 31) * 2
        return h < 24 && mi < 60 && s < 60 ? String(format: "%02d:%02d:%02d", h, mi, s) : ""
    }

    static let okChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -")
    static let devices: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })

    /// Refuse what the meter refuses (bftsd.s).
    public static func checkName(_ name: String) throws {
        if name.isEmpty { throw CardError("name refused: empty", status: stName) }
        if name.contains(where: { !okChars.contains($0) }) {
            throw CardError("name refused: \"\(name)\" has a character the meter does not take (A-Z a-z 0-9 . _ space -)", status: stName)
        }
        if name.contains("..") || name != name.trimmingCharacters(in: CharacterSet(charactersIn: " ")) || name.hasSuffix(".") {
            throw CardError("name refused: \"\(name)\" has \"..\", a space at an end or a dot at the end", status: stName)
        }
        if name.utf8.count > maxName { throw CardError("name refused: longer than \(maxName) bytes", status: stName) }
    }

    public static func isProtected(_ name: String) -> Bool { protected.contains(name.lowercased()) }

    public static func checkLocalName(_ name: String) throws {
        try checkName(name)
        if name == manifest || name.lowercased().hasSuffix(".part") {
            throw CardError("name \"\(name)\" is used by the sync itself", status: stName)
        }
        if devices.contains(String(name.split(separator: ".", omittingEmptySubsequences: false)[0]).uppercased()) {
            throw CardError("name \"\(name)\" is a device name on Windows", status: stName)
        }
    }
}

public struct CardError: LocalizedError, Equatable {
    public let message: String
    public let status: Int?
    public init(_ m: String, status: Int? = nil) { message = m; self.status = status }
    public var errorDescription: String? { message }
}

/// Stop-and-wait requests of type 0x10.. over `send`; the 0x82 answer frames arrive in `answers`.
public final class CardClient {
    public static let retries = 4
    public static let timeouts: [UInt8: Double] = [0x10: 15, 0x11: 30, 0x1A: 30, 0x12: 5, 0x13: 20, 0x14: 30, 0x15: 180]
    let send: Sender.Send
    let answers: AnswerQueue<[UInt8]>
    var seq = 0
    public var cancelled = false
    public var minTimeout = 0.0              // link 2: the time a whole answer takes at the block pace

    public init(send: @escaping Sender.Send, answers: AnswerQueue<[UInt8]>) {
        self.send = send
        self.answers = answers
    }

    /// (status, field, data) of the answer; CardError after `retries` sends without one.
    public func request(_ type: UInt8, _ payload: [UInt8] = [], timeout: Double? = nil, retries: Int = CardClient.retries)
        async throws -> (Int, Int, [UInt8]) {
        let t = max(timeout ?? Self.timeouts[type] ?? 10, minTimeout)
        seq = (seq + 1) & 0xFFFF
        let mySeq = seq
        let pkt = Transfer.packet(type, mySeq, payload)
        for _ in 0..<retries {
            answers.clear()
            try await send(pkt)
            let end = Date().addingTimeInterval(t)
            while Date() < end {
                if cancelled { throw CardError("cancelled") }
                guard let f = await answers.get(timeout: min(0.5, max(0.01, end.timeIntervalSinceNow)), cancelled: { self.cancelled })
                else { continue }
                guard let a = CardProtocol.parseAnswer(f), a.seq == mySeq else { continue }
                return (a.status, a.field, a.data)
            }
            if cancelled { throw CardError("cancelled") }
        }
        throw CardError("no answer from the meter (is \"Ld-bt\" still shown on it?)")
    }

    /// (field, data) of an accepted request; CardError with the meter's reason otherwise.
    public func ok(_ type: UInt8, _ payload: [UInt8] = [], timeout: Double? = nil, retries: Int = CardClient.retries)
        async throws -> (Int, [UInt8]) {
        let (status, field, data) = try await request(type, payload, timeout: timeout, retries: retries)
        if status != 0 { throw CardError(CardProtocol.describe(status, field), status: status) }
        return (field, data)
    }
}

public struct CardFile: Equatable, Identifiable, Sendable {
    public var name: String, size: Int, date: String, time: String
    public var id: String { name }
}

public struct SyncResult: Equatable, Sendable {
    public var copied = 0, unchanged = 0, bytes = 0
    public var skipped: [String] = []
}

public struct CarefulStats: Equatable, Sendable {
    public var pieces = 0, again = 0
    public var sizes: [Int: Int] = [:]
}

public final class Card {
    public static let chunkRetries = 8, windowTries = 3, chunkPasses = 2
    public static let carefulListMax = 4, carefulRetries = 12
    public static let carefulSizes = [16, 32, 64, 128], carefulStart = 32, carefulGrow = 4
    public static let carefulWaitRTT = 3.0, carefulWaitMin = 0.5, carefulWaitStart = 2.0, carefulRTTKeep = 8
    public static let probeWait = 3.0

    /// Unpack a raw deflate stream to exactly n bytes, nil otherwise (the app passes the Compression framework's).
    public typealias Inflate = ([UInt8], Int) -> [UInt8]?

    let c: CardClient
    let careful: Bool
    /// true: READZ (F-1.32 on); false: READ; nil: not known, the first read asks READZ once.
    public private(set) var packed: Bool?
    let inflate: Inflate?
    private var size = Card.carefulStart
    private var rtts: [Double] = []
    private var most = Card.carefulListMax
    public private(set) var carefulStats = CarefulStats()
    public private(set) var packedStats = (read: 0, fetched: 0)

    public init(client: CardClient, careful: Bool = false, packed: Bool? = false, inflate: Inflate? = nil) {
        c = client
        self.careful = careful
        self.packed = inflate == nil ? false : packed
        self.inflate = inflate
    }

    // MARK: listing

    public func listEntries() async throws -> [CardProtocol.Entry] {
        var out: [CardProtocol.Entry] = []
        var start = 0
        while true {
            let (field, data) = careful ? try await carefulListPage(start)
                : try await c.ok(CardProtocol.tList, CardProtocol.listRequest(start))
            let (entries, end) = try CardProtocol.parseList(field, data)
            out += entries
            if end { return out }
            if entries.isEmpty || out.count > 0x7FFF {
                throw CardError("LIST did not advance (\(out.count) entries, none new after \(start))")
            }
            start += entries.count
        }
    }

    private func carefulListPage(_ start: Int) async throws -> (Int, [UInt8]) {
        for _ in 0..<Self.carefulRetries {
            let t0 = Date()
            let status: Int, field: Int, data: [UInt8]
            do {
                (status, field, data) = try await c.request(CardProtocol.tList, CardProtocol.listRequest(start, most: most), timeout:
                    rtts.isEmpty ? CardClient.timeouts[CardProtocol.tList]! : carefulWait(), retries: 1)
            } catch {
                if c.cancelled { throw error }
                carefulStats.again += 1
                most = max(1, most / 2)
                continue
            }
            if status != 0 { throw CardError(CardProtocol.describe(status, field), status: status) }
            noteRTT(Date().timeIntervalSince(t0))
            return (field, data)
        }
        throw CardError("no answer from the meter (is \"Ld-bt\" still shown on it?)")
    }

    public func list() async throws -> [CardFile] {
        try await listEntries().filter(\.isFile).map { CardFile(name: $0.name, size: $0.size, date: $0.date, time: $0.time) }
    }

    public func info() async throws -> (free: Int, total: Int) {
        let (field, data) = try await c.ok(CardProtocol.tInfo)
        return try CardProtocol.parseInfo(field, data)
    }

    /// Format the card as exFAT (F-1.09 on with the two-part bootloader): sent once, the answer comes when done.
    public func format() async throws {
        let (status, field, _) = try await c.request(CardProtocol.tFormat, CardProtocol.formatWord, retries: 1)
        if status == CardProtocol.stNotNow {
            throw CardError("format refused: the meter's firmware is older than F-1.09 and does not know this command, or a "
                            + "firmware transfer is running", status: status)
        }
        if status != 0 { throw CardError("format refused: " + CardProtocol.describe(status, field), status: status) }
    }

    public func delete(_ name: String) async throws {
        try CardProtocol.checkName(name)
        if CardProtocol.isProtected(name) {
            throw CardError("\(name) is protected: the meter needs it", status: CardProtocol.stProtected)
        }
        let pkt = CardProtocol.nameBytes(name)
        for attempt in 0..<CardClient.retries {
            let status: Int, field: Int
            do {
                (status, field, _) = try await c.request(CardProtocol.tDelete, pkt, retries: 1)
            } catch {
                if attempt == CardClient.retries - 1 || c.cancelled { throw error }
                continue
            }
            if status == CardProtocol.stNotFound && attempt > 0 { return }   // an earlier send was done, its answer lost
            if status != 0 { throw CardError(CardProtocol.describe(status, field), status: status) }
            return
        }
    }

    // MARK: reading

    private func noteRTT(_ t: Double) {
        rtts.append(t)
        if rtts.count > Self.carefulRTTKeep { rtts.removeFirst() }
    }

    private func carefulWait() -> Double {
        guard let m = rtts.max() else { return Self.carefulWaitStart }
        return min(CardClient.timeouts[CardProtocol.tChunk]!, max(Self.carefulWaitMin, Self.carefulWaitRTT * m))
    }

    func chunks(_ n: Int) async throws -> [UInt8] {
        if careful { return try await carefulChunks(n) }
        var buf: [UInt8] = []
        let size = CardProtocol.chunk
        for idx in 0..<((n + size - 1) / size) {
            let want = min(size, n - idx * size)
            var got = false
            for _ in 0..<Self.chunkRetries {
                let status: Int, field: Int, data: [UInt8]
                do {
                    (status, field, data) = try await c.request(CardProtocol.tChunk, CardProtocol.chunkRequest(idx), retries: 1)
                } catch {
                    if c.cancelled { throw error }
                    continue
                }
                if status != 0 { throw CardError("chunk \(idx): \(CardProtocol.describe(status, field))", status: status) }
                if field == idx && data.count == want {
                    buf += data
                    got = true
                    break
                }
            }
            if !got { throw CardError("chunk \(idx) did not arrive") }
        }
        return buf
    }

    private func carefulChunks(_ n: Int) async throws -> [UInt8] {
        var buf: [UInt8] = []
        var good = 0
        let sizes = Self.carefulSizes
        while buf.count < n {
            let pos = buf.count
            var sz = size
            var want = min(sz, n - pos)
            var idx = pos / sz
            var data: [UInt8]?
            for _ in 0..<Self.carefulRetries {
                let t0 = Date()
                var status: Int?, field = 0, d: [UInt8] = []
                do {
                    let r = try await c.request(CardProtocol.tChunk, CardProtocol.chunkRequest(idx, size: sz), timeout: carefulWait(), retries: 1)
                    (status, field, d) = (r.0, r.1, r.2)
                } catch {
                    if c.cancelled { throw error }
                }
                if let s = status, s != 0 {
                    throw CardError("chunk \(idx) (\(sz) bytes): \(CardProtocol.describe(s, field))", status: s)
                }
                if status == 0 && field == idx && d.count == want {
                    noteRTT(Date().timeIntervalSince(t0))
                    data = d
                    break
                }
                carefulStats.again += 1
                good = 0
                if sz > sizes[0] {
                    sz = sizes[sizes.firstIndex(of: sz)! - 1]
                    size = sz
                    want = min(sz, n - pos)
                    idx = pos / sz
                }
            }
            guard let d = data else { throw CardError("chunk at byte \(pos) (\(sz) bytes) did not arrive") }
            buf += d
            carefulStats.pieces += 1
            carefulStats.sizes[sz, default: 0] += 1
            good += 1
            if good >= Self.carefulGrow && sz < sizes.last! {
                let bigger = sizes[sizes.firstIndex(of: sz)! + 1]
                if buf.count % bigger == 0 {
                    size = bigger
                    good = 0
                }
            }
        }
        return buf
    }

    public var window: Int { packed == false ? CardProtocol.window : CardProtocol.windowZ }

    private func probePacked(_ name: String, _ offset: Int, _ length: Int) async throws {
        do {
            _ = try await c.request(CardProtocol.tReadZ, CardProtocol.readRequest(name, offset, length), timeout: Self.probeWait, retries: 1)
            packed = true
        } catch {
            if c.cancelled { throw error }
            packed = false
        }
    }

    /// Up to `length` (<= window) bytes of the file from `offset`, checked against the CRC-32 the meter gave.
    public func readWindow(_ name: String, _ offset: Int, _ length: Int) async throws -> [UInt8] {
        precondition(length > 0 && length <= window, "window length 1..\(window)")
        if packed == nil { try await probePacked(name, offset, length) }
        if packed == true { return try await readWindowZ(name, offset, length) }
        for _ in 0..<Self.windowTries {
            let (field, d) = try await c.ok(CardProtocol.tRead, CardProtocol.readRequest(name, offset, length))
            let (n, crc) = try CardProtocol.parseRead(field, d)
            if n == 0 { return [] }
            if n > length { throw CardError("READ staged \(n) bytes, more than the \(length) asked") }
            for _ in 0..<Self.chunkPasses {
                let data = try await chunks(n)
                if CRC32.checksum(data) == crc { return data }
            }
        }
        throw CardError("CRC-32 of \(name) at offset \(offset) did not match after \(Self.windowTries) tries")
    }

    private func readWindowZ(_ name: String, _ offset: Int, _ length: Int) async throws -> [UInt8] {
        for _ in 0..<Self.windowTries {
            let (field, d) = try await c.ok(CardProtocol.tReadZ, CardProtocol.readRequest(name, offset, length))
            let z = try CardProtocol.parseReadZ(field, d)
            if z.n == 0 { return [] }
            if z.n > length { throw CardError("READZ read \(z.n) bytes, more than the \(length) asked") }
            for _ in 0..<Self.chunkPasses {
                let staged = try await chunks(z.staged)
                let data = z.method == 0 ? staged : inflate?(staged, z.n)
                if let data, data.count == z.n, CRC32.checksum(data) == z.crc {
                    packedStats.read += z.n
                    packedStats.fetched += z.staged
                    return data
                }
            }
        }
        throw CardError("CRC-32 of \(name) at offset \(offset) did not match after \(Self.windowTries) tries")
    }

    /// Read `size` bytes of the file through `write` in checked windows; progress(done) after each.
    public func readFile(_ name: String, size: Int, write: ([UInt8]) throws -> Void,
                         progress: ((Int) -> Void)? = nil) async throws -> Int {
        var offset = 0
        while offset < size {
            let data = try await readWindow(name, offset, min(window, size - offset))
            if data.isEmpty { throw CardError("\(name) is shorter than listed (\(offset) of \(size) bytes)") }
            try write(data)
            offset += data.count
            progress?(offset)
        }
        return offset
    }

    /// Copy a card file into `folder` (.part, then renamed); returns the local file.
    @discardableResult
    public func download(_ name: String, to folder: URL, size known: Int? = nil,
                         progress: ((Int, Int) -> Void)? = nil) async throws -> URL {
        try CardProtocol.checkLocalName(name)
        var size = known
        if size == nil {
            guard let f = try await list().first(where: { $0.name.lowercased() == name.lowercased() }) else {
                throw CardError("\(name) is not on the card", status: CardProtocol.stNotFound)
            }
            size = f.size
        }
        let total = size!
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(name)
        let part = folder.appendingPathComponent(name + ".part")
        fm.createFile(atPath: part.path, contents: nil)
        do {
            let h = try FileHandle(forWritingTo: part)
            defer { try? h.close() }
            _ = try await readFile(name, size: total, write: { try h.write(contentsOf: Data($0)) },
                                   progress: progress.map { p in { p($0, total) } })
            try? h.close()
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
            try fm.moveItem(at: part, to: path)
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
        return path
    }

    // MARK: sync

    struct Manifest: Codable {
        struct Rec: Codable, Equatable { var size: Int; var date: String; var time: String }
        var files: [String: Rec]
    }

    /// Copy the card's new or changed files into `folder` (the manifest records size, date and time of every file
    /// copied); local files are never deleted.
    public func sync(to folder: URL, progress: ((Int, Int) -> Void)? = nil) async throws -> SyncResult {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let mpath = folder.appendingPathComponent(CardProtocol.manifest)
        var done = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: mpath)))?.files ?? [:]
        var todo: [CardProtocol.Entry] = []
        var r = SyncResult()
        for f in try await listEntries() {
            guard f.isFile, (try? CardProtocol.checkLocalName(f.name)) != nil,
                  !CardProtocol.skipSync.contains(f.name.lowercased()) else {
                r.skipped.append(f.name)
                continue
            }
            let local = folder.appendingPathComponent(f.name)
            let localSize = (try? fm.attributesOfItem(atPath: local.path)[.size] as? Int) ?? nil
            if done[f.name] == Manifest.Rec(size: f.size, date: f.date, time: f.time) && localSize == f.size {
                r.unchanged += 1
            } else {
                todo.append(f)
            }
        }
        let total = todo.reduce(0) { $0 + $1.size }
        var base = 0
        for f in todo {
            let b = base
            try await download(f.name, to: folder, size: f.size, progress: progress.map { p in { d, _ in p(b + d, total) } })
            base += f.size
            done[f.name] = Manifest.Rec(size: f.size, date: f.date, time: f.time)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(Manifest(files: done)).write(to: mpath, options: .atomic)
        }
        r.copied = todo.count
        r.bytes = total
        return r
    }
}
