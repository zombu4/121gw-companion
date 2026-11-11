// Transfers to the meter (companion transfer.py): the file transfer of the firmware's page Ld (FEATURES.md 2.10,
// ble/bft.s) and the update protocol of the two-part bootloader (bootloader/DESIGN.md 6.3, bl_ble.s).
//
// Packet to the meter: B5 5B type seq(2) len(1) payload crc16(2), little-endian, CRC-16/CCITT-FALSE over type..payload.
// Answer: B5 5B 81 seq(2) 03 status next(2) crc16(2).  Stop and wait on page Ld; two packets in flight in the
// bootloader.  Packed (IMP-63, F-1.32 / B-1.15): START kind | 0x80 and the DATA bytes are the packed stream.

import Foundation

public enum Transfer {
    public static let tStart: UInt8 = 1, tData: UInt8 = 2, tEnd: UInt8 = 3, tStatus: UInt8 = 5
    public static let tLeave: UInt8 = 0x19                // leave page Ld as a SETUP press does (F-1.17)
    public static let maxPayload = 232
    public static let packedFlag: UInt8 = 0x80
    public static let piece = 2048
    public static let rawPiece = 0x8000
    public static let finalDynamic: UInt8 = 5             // BFINAL 1, BTYPE 2
    public static let timeoutData = 5.0
    public static let timeoutEnd = 120.0
    public static let timeoutStart = 6.0                  // the bootloader erases before it answers START
    public static let rtoMin = 1.0
    public static let retries = 8
    public static let kindFirmware: UInt8 = 0, kindInstall: UInt8 = 1, kindBootloader: UInt8 = 2
    public static let bootVersionIndex: UInt8 = 0x80

    public static let statusText: [Int: String] = [
        0: "accepted", 1: "CRC wrong", 2: "not the expected packet", 3: "not allowed now", 4: "size refused",
        5: "beyond the announced size", 0x11: "the card could not be written", 0x12: "length or CRC-32 wrong",
        0x13: "not an application image", 0x14: "the copy to EEVBlog.bin failed",
        0x15: "EEVBlog.bin read back differs", 0x16: "the received file could not be read back",
        0x17: "the meter does not have one of EEVblog's bootloaders (already replaced?)",
        0x18: "battery too low for the bootloader install: put in fresh batteries",
        0x19: "the bootloader install failed (the file or a flash step)",
        0x1A: "the packed data was damaged (nothing was kept; send the file again)",
    ]
    public static let bootStatusText: [Int: String] = [
        0: "accepted", 1: "CRC wrong", 2: "not the expected packet", 3: "not allowed now", 4: "refused",
        5: "beyond the announced size", 0x12: "length or CRC-32 of the written image wrong",
        0x13: "not a firmware image", 0x16: "flash write or check failed",
        0x17: "the packed data was damaged (the meter stays in update mode; send it again)",
    ]

    static func text(_ table: [Int: String], _ s: Int) -> String { table[s] ?? String(s) }

    public static func packet(_ type: UInt8, _ seq: Int, _ payload: [UInt8] = []) -> [UInt8] {
        let body: [UInt8] = [type, UInt8(seq & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(payload.count)] + payload
        let crc = Frames.crc16(body)
        return [0xB5, 0x5B] + body + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    public struct Answer: Equatable, Sendable {
        public var seq: Int, status: Int, next: Int
    }

    /// (seq, status, next) of a checked answer frame of type 0x81.
    public static func answer(_ f: [UInt8]) -> Answer? {
        guard f.count >= 11, f[2] == 0x81, f[5] == 3 else { return nil }
        return Answer(seq: Int(f[3]) | Int(f[4]) << 8, status: Int(f[6]), next: Int(f[7]) | Int(f[8]) << 8)
    }

    /// A raw-deflate compressor of one piece (nil: cannot); the app passes the Compression framework's.
    public typealias Deflate = ([UInt8]) -> [UInt8]?

    /// True when the block is what the meter's inflater takes (firmware sys/zinf.s): one final block with the dynamic
    /// code, HLIT at most 286 and HDIST at most 30.
    public static func meterTakes(_ blk: [UInt8]) -> Bool {
        guard blk.count >= 3, blk[0] & 7 == finalDynamic else { return false }
        let hlit = Int((blk[0] >> 3) & 31) + 257
        let hdist = Int(blk[1] & 31) + 1
        return hlit <= 286 && hdist <= 30
    }

    /// The packed stream: per piece raw length u16, packed length u16 (0x8000 | raw length: the raw bytes follow).
    public static func packStream(_ data: [UInt8], deflate: Deflate?, piece: Int = piece) -> [UInt8] {
        var out: [UInt8] = []
        var p = 0
        while p < data.count {
            let raw = Array(data[p..<min(p + piece, data.count)])
            func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
            if let blk = deflate?(raw), meterTakes(blk), blk.count < raw.count {
                out += u16(raw.count) + u16(blk.count) + blk
            } else {
                out += u16(raw.count) + u16(rawPiece | raw.count) + raw
            }
            p += piece
        }
        return out
    }

    static func dataPackets(_ stream: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: stream.count, by: maxPayload).enumerated().map { n, i in
            packet(tData, n, Array(stream[i..<min(i + maxPayload, stream.count)]))
        }
    }
}

public struct TransferError: LocalizedError, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Answers of one kind, pushed by the controller as frames arrive, taken by a running operation (thread-safe: an
/// operation's async code may run off the main thread).
public final class AnswerQueue<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()
    public init() {}
    public func put(_ x: T) {
        lock.lock(); defer { lock.unlock() }
        items.append(x)
        if items.count > 64 { items.removeFirst() }
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty
    }
    func take() -> T? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// The next item, waiting up to `timeout` seconds (nil after that, or when `cancelled` says so).
    public func get(timeout: Double, cancelled: () -> Bool = { false }) async -> T? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if let x = take() { return x }
            if Date() >= end || cancelled() || Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

public struct TransferStats: Equatable, Sendable {
    public var packets = 0, sends = 0, timeouts = 0, crcWrong = 0, resync = 0, stray = 0
    public var waited = 0.0, slowest = 0.0, seconds = 0.0
    public var startAnswered: Double?
    public var file = 0, sent = 0

    public func text(dropped: Int = 0) -> String {
        var parts = [String(format: "%d packets in %.0f s", packets, seconds)]
        if sent != 0 && file != 0 && sent != file {
            parts.append(String(format: "packed: %d bytes sent for %d (%.0f %%)", sent, file, 100.0 * Double(sent) / Double(file)))
        }
        let repeats = sends - packets
        parts.append(repeats > 0 ? "\(repeats) sent again" : "none sent again")
        if timeouts > 0 { parts.append(String(format: "%d answers missing (%.0f s waited for them)", timeouts, waited)) }
        if crcWrong > 0 { parts.append("\(crcWrong) packets arrived damaged") }
        if resync > 0 { parts.append("\(resync) resynchronisations") }
        if stray > 0 { parts.append("\(stray) late answers") }
        if let s = startAnswered { parts.append(String(format: "START answered after %.1f s", s)) }
        parts.append(String(format: "slowest answer %.1f s", slowest))
        if dropped > 0 { parts.append("\(dropped) received bytes damaged") }
        return parts.joined(separator: ", ")
    }
}

/// Runs page Ld requests and transfers over `send`, with the 0x81 answers put into `answers`.
public final class Sender {
    public typealias Send = ([UInt8]) async throws -> Void
    let send: Send
    public let answers = AnswerQueue<Transfer.Answer>()
    public private(set) var done = 0
    public private(set) var total = 0
    public var cancelled = false
    public private(set) var stats = TransferStats()
    public var timeoutData = Transfer.timeoutData
    public var timeoutEnd = Transfer.timeoutEnd
    public var timeoutStart = Transfer.timeoutStart

    public init(send: @escaping Send) { self.send = send }

    func ask(_ pkt: [UInt8], _ seq: Int, timeout: Double) async throws -> (Int, Int) {
        for _ in 0..<Transfer.retries {
            answers.clear()
            try await send(pkt)
            stats.sends += 1
            let sent = Date()
            let end = sent.addingTimeInterval(timeout)
            var answered = false
            while Date() < end {
                if cancelled { throw TransferError("cancelled") }
                guard let a = await answers.get(timeout: min(0.5, max(0.01, end.timeIntervalSinceNow)), cancelled: { self.cancelled })
                else { continue }
                if a.status == 1 {
                    stats.crcWrong += 1
                    answered = true
                    break
                }
                if a.seq != seq {
                    stats.stray += 1
                    continue
                }
                stats.slowest = max(stats.slowest, Date().timeIntervalSince(sent))
                return (a.status, a.next)
            }
            if cancelled { throw TransferError("cancelled") }
            if !answered {
                stats.timeouts += 1
                stats.waited += timeout
            }
        }
        throw TransferError("no answer to packet \(seq) (is \"Ld-bt\" still shown on the meter?)")
    }

    /// True when the meter answers a status request, i.e. it shows the page Ld.
    public func probe(timeout: Double = 1.5) async throws -> Bool {
        answers.clear()
        try await send(Transfer.packet(Transfer.tStatus, 0, [0]))
        return await answers.get(timeout: timeout) != nil
    }

    /// Diagnosis value `index` (STATUS request): the "next" field of the answer.
    public func statusValue(_ index: Int, timeout: Double = 2.0) async throws -> Int {
        let (status, next) = try await ask(Transfer.packet(Transfer.tStatus, index, [UInt8(index)]), index, timeout: timeout)
        if status != 0 { throw TransferError("STATUS \(index): \(Transfer.text(Transfer.statusText, status))") }
        return next
    }

    /// Leave page Ld (LEAVE, F-1.17 on): the meter goes to the next SETUP page and the readings come back.
    public func leave(timeout: Double = 2.0) async throws {
        let (status, _) = try await ask(Transfer.packet(Transfer.tLeave, 0), 0, timeout: timeout)
        if status != 0 { throw TransferError("leave page Ld: \(Transfer.text(Transfer.statusText, status))") }
    }

    /// Send `data` as EEVBlog.bin, or with kind 1 as the first-install file of the two-part bootloader; `deflate`
    /// given (F-1.32 on): as the packed stream.  Returns the card sessions the meter had to repeat.
    public func run(_ data: [UInt8], kind: UInt8? = nil, deflate: Transfer.Deflate? = nil) async throws -> Int {
        let packed = deflate != nil
        let stream = packed ? Transfer.packStream(data, deflate: deflate) : data
        let pkts = Transfer.dataPackets(stream)
        total = stream.count
        done = 0
        stats = TransferStats()
        stats.packets = pkts.count + 2
        stats.file = data.count
        stats.sent = stream.count
        let t0 = Date()
        defer { stats.seconds = Date().timeIntervalSince(t0) }
        var start = le32(data.count) + le32(Int(CRC32.checksum(data)))
        if packed { start.append((kind ?? 0) | Transfer.packedFlag) } else if let kind { start.append(kind) }
        let t = Date()
        var (status, _) = try await ask(Transfer.packet(Transfer.tStart, 0, start), 0, timeout: timeoutData)
        stats.startAnswered = Date().timeIntervalSince(t)
        if status != 0 { throw TransferError("START: \(Transfer.text(Transfer.statusText, status))") }
        var n = 0
        while n < pkts.count {
            let (s, next) = try await ask(pkts[n], n, timeout: timeoutData)
            if s == 2 {
                stats.resync += 1
                n = next
                continue
            }
            if s != 0 { throw TransferError("packet \(n): \(Transfer.text(Transfer.statusText, s))") }
            n += 1
            done = min(total, n * Transfer.maxPayload)
        }
        let info: Int
        (status, info) = try await ask(Transfer.packet(Transfer.tEnd, pkts.count), pkts.count, timeout: timeoutEnd)
        if status == 0x14 || status == 0x15 {
            throw TransferError("\(Transfer.statusText[status]!): the card holds the old EEVBlog.bin untouched or none at all; "
                                + "do not use the update keys, send the file again")
        }
        if status != 0 { throw TransferError("END: \(Transfer.text(Transfer.statusText, status))") }
        return info
    }

    /// The version of the bootloader when the meter is in its update mode, else nil.
    public func bootVersion(timeout: Double = 1.5) async throws -> Version? {
        answers.clear()
        try await send(Transfer.packet(Transfer.tStatus, 0, [Transfer.bootVersionIndex]))
        guard let a = await answers.get(timeout: timeout), a.status == 0 else { return nil }
        return Version(a.next >> 8, (a.next >> 4) & 0xF, a.next & 0xF)
    }

    /// The bootloader's update protocol: START (erase, then answer), DATA with two packets in flight, END (the meter
    /// checks the flash and restarts half a second after its answer).  The DATA wait follows the measured answer
    /// times as TCP's does (RFC 6298), Karn's rule for packets sent again.
    public func runBoot(_ data: [UInt8], kind: UInt8 = Transfer.kindFirmware, version: Int? = nil,
                        deflate: Transfer.Deflate? = nil) async throws {
        let packed = deflate != nil
        let stream = packed ? Transfer.packStream(data, deflate: deflate) : data
        let pkts = Transfer.dataPackets(stream)
        total = stream.count
        done = 0
        stats = TransferStats()
        stats.packets = pkts.count + 2
        stats.file = data.count
        stats.sent = stream.count
        let t0 = Date()
        defer { stats.seconds = Date().timeIntervalSince(t0) }
        var start = le32(data.count) + le32(Int(CRC32.checksum(data))) + [kind | (packed ? Transfer.packedFlag : 0)]
        if let version { start += le32(version) }
        let t = Date()
        let (status, _) = try await ask(Transfer.packet(Transfer.tStart, 0, start), 0, timeout: timeoutStart)
        stats.startAnswered = Date().timeIntervalSince(t)
        if status != 0 { throw TransferError("START: \(Transfer.text(Transfer.bootStatusText, status))") }
        var acked = 0
        var srtt: Double?, rttvar = 0.0
        var rto = timeoutData
        var resent = 0
        while acked < pkts.count {
            answers.clear()
            var nextSend = acked, inflight = 0, stalled = false
            while acked < pkts.count && !stalled {
                while inflight < 2 && nextSend < pkts.count {
                    try await send(pkts[nextSend])
                    stats.sends += 1
                    nextSend += 1
                    inflight += 1
                }
                let waiting = Date()
                guard let got = await answers.get(timeout: rto, cancelled: { self.cancelled }) else {
                    if cancelled { throw TransferError("cancelled") }
                    stats.timeouts += 1
                    stats.waited += rto
                    rto = min(timeoutData, 2 * rto)
                    resent = nextSend
                    stalled = true
                    break
                }
                let took = Date().timeIntervalSince(waiting)
                stats.slowest = max(stats.slowest, took)
                if got.seq >= resent {
                    if let s = srtt {
                        rttvar = 0.75 * rttvar + 0.25 * abs(s - took)
                        srtt = 0.875 * s + 0.125 * took
                    } else {
                        srtt = took
                        rttvar = took / 2
                    }
                    rto = min(timeoutData, max(min(Transfer.rtoMin, timeoutData), srtt! + 4 * rttvar))
                }
                if got.status == 0 && got.seq >= acked {
                    let new = max(acked + 1, min(got.next, nextSend))
                    inflight = max(0, inflight - (new - acked))
                    acked = new
                    done = min(total, acked * Transfer.maxPayload)
                } else if got.status == 0 {
                    stats.stray += 1
                    inflight = max(0, inflight - 1)
                } else if got.status == 1 || got.status == 2 {
                    if got.status == 1 { stats.crcWrong += 1 } else { stats.resync += 1 }
                    stalled = true
                    if got.status == 2 { acked = got.next }
                } else {
                    throw TransferError("packet \(got.seq): \(Transfer.text(Transfer.bootStatusText, got.status))")
                }
            }
            if stalled { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
        let (endStatus, _) = try await ask(Transfer.packet(Transfer.tEnd, pkts.count), pkts.count, timeout: timeoutStart)
        if endStatus != 0 { throw TransferError("END: \(Transfer.text(Transfer.bootStatusText, endStatus))") }
    }
}

func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

/// CRC-32 (IEEE 802.3, as zlib.crc32).
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum<C: Collection>(_ data: C, start: UInt32 = 0) -> UInt32 where C.Element == UInt8 {
        var c = ~start
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}
