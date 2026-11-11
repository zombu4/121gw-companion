// Frames the 121GW sends over its Bluetooth link, reassembled from the notification chunks (companion frames.py;
// analysis/ble_packet.md 3 and 6 of the firmware; FEATURES.md 2.10 and 2.11).
//
//     start  length  frame                                  check
//     F2     19      status frame (the reading)             XOR of all 19 bytes = 0
//     F4     5       echo of a key frame                    the two hex pairs equal
//     F8     15      echo of a set-clock frame              7th hex pair = XOR of the first six
//     F6     7       version answer of the fast build       XOR of all 7 bytes = 0
//     F7     7       bootloader version answer (F-1.03 on)  XOR of all 7 bytes = 0
//     F9     20      extended link diagnosis (F-1.15 on)    XOR of all 20 bytes = 0
//     FA     20      clock measurement (F-1.17 on)          XOR of all 20 bytes = 0
//     B5 5B  8+n     answer of the file transfer (2.10)     CRC-16/CCITT-FALSE
//
// Bytes inside a binary frame can equal a start byte, so a frame is taken only when its whole length is present and its
// check passes; otherwise the first byte is dropped and the search goes on from the next one.

import Foundation

public enum FrameKind: String, Sendable {
    case status, keyEcho, clockEcho, version, blVersion, xdiag, mclock, bft
}

public struct Frame: Equatable, Sendable {
    public let kind: FrameKind
    public let bytes: [UInt8]
    public init(_ kind: FrameKind, _ bytes: [UInt8]) { self.kind = kind; self.bytes = bytes }
}

public enum Frames {
    public static let statusLength = 19
    public static let xdiagLength = 20
    public static let mclockLength = 20
    public static let mclockNominalHz = 4_194_304          // MSI range 6, the meter's run clock (sys/msical.s)
    public static let mclockBaud = 19_200                  // the meter's serial line to its Bluetooth module
    public static let damagedKeep = 20                     // skipped runs kept
    public static let damagedBytes = 32                    // bytes kept of one run

    public static let xdiagNames = [
        "bytes received", "overruns (ORE)", "noise flags (NE)", "framing errors (FE)",
        "bytes discarded on the card-session clock", "rejected key / clock frames",
        "page Ld packets with a wrong CRC", "answers not queued (transmit queue full)", "battery voltage (0.01 V)",
    ]

    public static let mclockStatus: [Int: String] = [
        0: "not measured since the meter was switched on", 1: "measured",
        2: "not measured (the meter was not on its RC clock)", 3: "not measured (the crystal was already running)",
        4: "not measured (the crystal did not start)", 5: "not measured (no signal from the crystal on the timer)",
        6: "measured, but more than 6 % off: not used",
        7: "measured; the trimmed clock measured worse, the trim was taken back",
    ]

    public static func xor<C: Collection>(_ data: C) -> UInt8 where C.Element == UInt8 {
        data.reduce(0, ^)
    }

    /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF), as the file transfer of the firmware (ble/bft.s).
    public static func crc16<C: Collection>(_ data: C, crc start: UInt16 = 0xFFFF) -> UInt16 where C.Element == UInt8 {
        var crc = start
        for b in data {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x37
        default: return nil
        }
    }

    static func pair(_ d: ArraySlice<UInt8>, _ i: Int) -> UInt8? {
        guard let hi = hexValue(d[d.startIndex + i]), let lo = hexValue(d[d.startIndex + i + 1]) else { return nil }
        return hi << 4 | lo
    }

    static func hex2(_ v: UInt8) -> [UInt8] {
        Array(String(format: "%02X", v).utf8)
    }

    /// The key frame of `code` (0x01..0x08 short, 0x81..0x88 long, 0x90 version, 0x91 update mode, 0x92 bootloader
    /// version, 0x93..0x95 extended diagnosis, 0x96 clock measurement, 0xA8 link 2, 0xAA.. link 2 pace): F4 and the
    /// code as an ASCII hex pair twice.
    public static func keyFrame(_ code: UInt8) -> [UInt8] {
        let h = hex2(code)
        return [0xF4] + h + h
    }

    public static let versionRequest = keyFrame(0x90)
    public static let updateModeRequest = keyFrame(0x91)     // restart into the two-part bootloader's update mode
    public static let blVersionRequest = keyFrame(0x92)      // bootloader version, answered with F7
    public static let xdiagOnRequest = keyFrame(0x93)
    public static let xdiagOffRequest = keyFrame(0x94)
    public static let xdiagRequest = keyFrame(0x95)
    public static let mclockRequest = keyFrame(0x96)
    public static let link2Request = keyFrame(0xA8)

    /// Heartbeat (IMP-56, F-1.26): 0xFE "still here", 0xFD switches the meter's watch off before a disconnect.
    public static let heartbeatOn: [UInt8] = [0xFE]
    public static let heartbeatOff: [UInt8] = [0xFD]

    /// "F-1.00" from a version frame F6 c0..c4 x (the decimal point follows the third character).
    public static func versionText(_ f: [UInt8]) -> String {
        let c = String(decoding: f[1..<6], as: UTF8.self)
        return String(c.prefix(3)) + "." + String(c.dropFirst(3))
    }

    /// "B-1.00" from F7 'B' '-' d d d x, or "EEV" for EEVblog's bootloader ("B-EEV").
    public static func blVersionText(_ f: [UInt8]) -> String {
        let c = String(decoding: f[1..<6], as: UTF8.self)
        return c == "B-EEV" ? "EEV" : String(c.prefix(3)) + "." + String(c.dropFirst(3))
    }

    /// The nine u16 values of an F9 frame, in the order of xdiagNames.
    public static func xdiagValues(_ f: [UInt8]) -> [Int] {
        (0..<9).map { Int(f[1 + 2 * $0]) | Int(f[2 + 2 * $0]) << 8 }
    }

    public struct ClockMeasurement: Equatable, Sendable {
        public var hz0: Int, hz: Int, trim: Int, status: Int, steps: Int, brr: Int
        public var calRun: Int?, calNow: Int?
    }

    /// The values of an FA frame (ck_send: FA, ck_hz0 u32, ck_hz u32, MSITRIM i8, status, measurements u16,
    /// USART2_BRR u16, MSICAL at the end of the measurement, MSICAL now, 2 zero bytes, XOR).
    public static func mclockValues(_ f: [UInt8]) -> ClockMeasurement {
        func u32(_ o: Int) -> Int { Int(f[o]) | Int(f[o + 1]) << 8 | Int(f[o + 2]) << 16 | Int(f[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(f[o]) | Int(f[o + 1]) << 8 }
        return ClockMeasurement(hz0: u32(1), hz: u32(5), trim: Int(Int8(bitPattern: f[9])), status: Int(f[10]),
                                steps: u16(11), brr: u16(13), calRun: Int(f[15]), calNow: Int(f[16]))
    }

    /// The same values from page Ld STATUS 49..55.
    public static func mclockFromStatus(_ v: [Int]) -> ClockMeasurement {
        let trim = v[4] & 0xFF
        return ClockMeasurement(hz0: v[0] | v[1] << 16, hz: v[2] | v[3] << 16, trim: trim & 0x80 != 0 ? trim - 256 : trim,
                                status: v[4] >> 8, steps: v[5], brr: v[6], calRun: nil, calNow: nil)
    }

    /// Report lines for the clock values (companion frames.mclock_lines).
    public static func mclockLines(_ c: ClockMeasurement) -> [String] {
        func pct(_ f: Double, _ ref: Double) -> Double { (f - ref) * 100 / ref }
        func row(_ k: String, _ v: String) -> String { "  " + k.padding(toLength: 24, withPad: " ", startingAt: 0) + " " + v }
        let nominal = Double(mclockNominalHz)
        var out = [row("result", mclockStatus[c.status] ?? "unknown status \(c.status)")]
        if c.hz0 != 0 {
            out.append(row("RC clock as found", String(format: "%d Hz (%+.3f %% from %d)", c.hz0, pct(Double(c.hz0), nominal), mclockNominalHz)))
        }
        let used = (c.status == 1 || c.status == 7) && c.hz != 0
        if used {
            out.append(row("RC clock in use", String(format: "%d Hz (%+.3f %%), trim %d, %d measurements", c.hz,
                                                     pct(Double(c.hz), nominal), c.trim, c.steps)))
        }
        let clk = used ? c.hz : c.hz0
        if c.brr != 0 && clk != 0 {
            let bd = Double(clk) / Double(c.brr)
            out.append(row("Bluetooth serial baud", String(format: "%.0f (BRR %d; %+.2f %% from %d)", bd, c.brr,
                                                           pct(bd, Double(mclockBaud)), mclockBaud)))
        } else if c.brr != 0 {
            out.append(row("Bluetooth serial baud", "BRR \(c.brr) (clock not measured)"))
        }
        if let run = c.calRun, let now = c.calNow {
            out.append(row("MSICAL", String(format: "0x%02X after the measurement, 0x%02X now%@", run, now,
                                            run == now ? "" : " (changed since)")))
        }
        return out
    }

    /// "F2 0A 00": the bytes as hex pairs separated by spaces.
    public static func hexSpaced<C: Collection>(_ d: C) -> String where C.Element == UInt8 {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// feed(chunk) -> every complete, checked frame in the stream so far (companion frames.Reassembler).
public final class Reassembler {
    public private(set) var buffer: [UInt8] = []
    public private(set) var dropped = 0                   // bytes skipped while resynchronising
    /// (length, first bytes) of the skipped runs; shared across connections when the caller passes the same store.
    public var pieces: [(Int, [UInt8])] = []
    private var run: [UInt8] = []
    private var runLength = 0

    public init() {}

    public func feed<C: Collection>(_ chunk: C) -> [Frame] where C.Element == UInt8 {
        buffer.append(contentsOf: chunk)
        var out: [Frame] = []
        var start = 0
        while start < buffer.count {
            let got = take(buffer[start...])
            switch got {
            case .wait:
                buffer.removeFirst(start)
                return out
            case .none:
                if run.count < Frames.damagedBytes { run.append(buffer[start]) }
                runLength += 1
                dropped += 1
                start += 1
            case let .frame(kind, n):
                endRun()
                out.append(Frame(kind, Array(buffer[start..<start + n])))
                start += n
            }
        }
        buffer.removeAll(keepingCapacity: true)
        return out
    }

    private func endRun() {
        if runLength > 0 {
            pieces.append((runLength, run))
            if pieces.count > Frames.damagedKeep { pieces.removeFirst(pieces.count - Frames.damagedKeep) }
        }
        run = []
        runLength = 0
    }

    /// The last runs of bytes skipped, oldest first, the run in progress last.
    public func damaged() -> [(Int, [UInt8])] {
        var out = pieces
        if runLength > 0 { out.append((runLength, run)) }
        return Array(out.suffix(Frames.damagedKeep))
    }

    enum Take { case wait, none, frame(FrameKind, Int) }

    func take(_ b: ArraySlice<UInt8>) -> Take {
        let s = b.first!
        let n = b.count
        func fixed(_ len: Int, _ kind: FrameKind, _ ok: () -> Bool) -> Take {
            n < len ? .wait : (ok() ? .frame(kind, len) : .none)
        }
        let i0 = b.startIndex
        switch s {
        case 0xF2:
            return fixed(19, .status) { Frames.xor(b.prefix(19)) == 0 }
        case 0xF6, 0xF7:
            return fixed(7, s == 0xF6 ? .version : .blVersion) {
                Frames.xor(b.prefix(7)) == 0 && b[(i0 + 1)..<(i0 + 6)].allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            }
        case 0xF9:
            return fixed(Frames.xdiagLength, .xdiag) { Frames.xor(b.prefix(Frames.xdiagLength)) == 0 }
        case 0xFA:
            return fixed(Frames.mclockLength, .mclock) { Frames.xor(b.prefix(Frames.mclockLength)) == 0 }
        case 0xF4:
            return fixed(5, .keyEcho) {
                guard let p1 = Frames.pair(b, 1), let p2 = Frames.pair(b, 3) else { return false }
                return p1 == p2
            }
        case 0xF8:
            return fixed(15, .clockEcho) {
                var v: [UInt8] = []
                for i in stride(from: 1, to: 15, by: 2) {
                    guard let p = Frames.pair(b, i) else { return false }
                    v.append(p)
                }
                return v[6] == Frames.xor(v[0..<6])
            }
        case 0xB5:
            if n < 2 { return .wait }
            if b[i0 + 1] != 0x5B { return .none }
            if n < 6 { return .wait }
            let len = 8 + Int(b[i0 + 5])
            if n < len { return .wait }
            let crc = Frames.crc16(b[(i0 + 2)..<(i0 + len - 2)])
            return crc == UInt16(b[i0 + len - 2]) | UInt16(b[i0 + len - 1]) << 8 ? .frame(.bft, len) : .none
        default:
            return .none
        }
    }
}
