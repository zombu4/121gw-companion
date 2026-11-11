// Link 2 decoder (firmware F-1.31 ble/link2.s, IMP-62; companion frames.Link2).  Old BLE112 module only: while the
// app asks (key code 0xA8) the meter sends 20-byte blocks with three Reed-Solomon parity bytes; READ blocks carry the
// readings in a compact form (rebuilt here as F2 status frames), TEXT blocks the plain bytes of other frames, STATE
// blocks the settings the READ blocks refer to.
//
// Sync as ATM cell delineation: hunting, a block is taken only when it and the block 20 bytes later are exact
// codewords with consecutive sequence numbers; locked, every 20 bytes is a block, one damaged byte is corrected, three
// bad blocks in a row give the held bytes back and the hunt starts again.

import Foundation

enum GF256 {
    // GF(256) with the polynomial 0x11D, alpha = 2 (the firmware's l2_rs_feed)
    static let tables: ([Int], [Int]) = {
        var exp = [Int](repeating: 0, count: 512), log = [Int](repeating: 0, count: 256)
        var v = 1
        for i in 0..<255 {
            exp[i] = v
            log[v] = i
            v <<= 1
            if v & 0x100 != 0 { v ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()
    static var exp: [Int] { tables.0 }
    static var log: [Int] { tables.1 }

    @inline(__always) static func mul(_ a: Int, _ b: Int) -> Int {
        a == 0 || b == 0 ? 0 : tables.0[tables.1[a] + tables.1[b]]
    }
}

public enum Link2Block {
    public static let length = 20
    public static let read = 1, text = 2, state = 3          // block types (H bits 7..6)
    public static let textMax = 15                           // answer bytes in one TEXT block
    public static let tick = 0.01002                          // the meter's TIM2 tick in seconds
    public static let lose = 3                               // bad blocks in a row before hunting again

    /// The three Reed-Solomon syndromes (roots 1, alpha, alpha^2; firmware l2_parity).
    public static func syndromes<C: Collection>(_ cw: C) -> [Int] where C.Element == UInt8 {
        (0..<3).map { k in
            var acc = 0
            let ak = GF256.exp[k]
            for b in cw { acc = GF256.mul(acc, ak) ^ Int(b) }
            return acc
        }
    }

    /// The block as sent: as received when all syndromes are 0, one damaged byte corrected, else nil.
    public static func correct(_ cw: [UInt8]) -> [UInt8]? {
        let s = syndromes(cw)
        let (s0, s1, s2) = (s[0], s[1], s[2])
        if s0 == 0 && s1 == 0 && s2 == 0 { return cw }
        if s0 == 0 || s1 == 0 || s2 == 0 || GF256.mul(s1, s1) != GF256.mul(s0, s2) { return nil }
        let d = ((GF256.log[s1] - GF256.log[s0]) % 255 + 255) % 255
        let pos = length - 1 - d
        guard pos >= 0 && pos < length else { return nil }
        var out = cw
        out[pos] ^= UInt8(s0)
        return syndromes(out) == [0, 0, 0] ? out : nil
    }

    static func exact(_ cw: ArraySlice<UInt8>) -> Bool {
        let t = Int(cw[cw.startIndex] >> 6)
        return (t == read || t == text || t == state) && syndromes(cw) == [0, 0, 0]
    }
}

public struct Link2Stats: Equatable, Sendable {
    public var blocks = 0, corrected = 0, lost = 0, stale = 0, readings = 0, meterDropped = 0, locks = 0
}

public final class Link2Decoder {
    public private(set) var buffer: [UInt8] = []
    public private(set) var locked = false
    public private(set) var stats = Link2Stats()
    private var bad = 0
    private var held: [UInt8] = []
    private var seq: Int?
    private var droppedMark: Int?
    // (version, 7 settings bytes, 4 id bytes, period ticks, battery)
    private var state: (version: UInt8, st: [UInt8], ident: [UInt8], period: Int, battery: Int)?

    public init() {}

    struct DecodeError: Error { let why: String }

    /// (plain bytes for the Reassembler, [(status frame F2, seconds before the chunk arrived)]).
    public func feed<C: Collection>(_ chunk: C) -> (plain: [UInt8], readings: [([UInt8], Double)]) where C.Element == UInt8 {
        buffer.append(contentsOf: chunk)
        var plain: [UInt8] = [], readings: [([UInt8], Double)] = []
        let L = Link2Block.length
        while true {
            if !locked {
                if buffer.count < 2 * L { break }
                let a = buffer[0..<L], b = buffer[L..<(2 * L)]
                if Link2Block.exact(a) && Link2Block.exact(b) && (b[L] & 0x3F) == ((a[0] &+ 1) & 0x3F) {
                    locked = true; bad = 0; seq = nil
                    stats.locks += 1
                    continue
                }
                plain.append(buffer.removeFirst())
                continue
            }
            if buffer.count < L { break }
            let cw = Array(buffer[0..<L])
            var got: (String, [UInt8], [([UInt8], Double)])?
            var fixed = Link2Block.correct(cw)
            if let f = fixed, [Link2Block.read, Link2Block.text, Link2Block.state].contains(Int(f[0] >> 6)) {
                got = try? block(f)
            } else {
                fixed = nil
            }
            guard let f = fixed, let g = got else {
                stats.lost += 1
                bad += 1
                held += cw
                buffer.removeFirst(L)
                if bad >= Link2Block.lose {                 // not link 2 any more (or bytes lost): hunt again
                    buffer.insert(contentsOf: held, at: 0)
                    held = []
                    locked = false
                    bad = 0
                }
                continue
            }
            let (kind, text, reads) = g
            bad = 0
            held = []
            if f != cw { stats.corrected += 1 }
            stats.blocks += 1
            let s = Int(f[0] & 0x3F)
            if let last = seq, s != (last + 1) & 0x3F { stats.lost += (s - last - 1) & 0x3F }
            seq = s
            buffer.removeFirst(L)
            if kind == "text" { plain += text } else { readings += reads }
        }
        return (plain, readings)
    }

    /// The bytes held while hunting (none while locked).
    public func flush() -> [UInt8] {
        if locked { return [] }
        let out = buffer
        buffer.removeAll()
        return out
    }

    private func block(_ b: [UInt8]) throws -> (String, [UInt8], [([UInt8], Double)]) {
        let typ = Int(b[0] >> 6)
        let p = Array(b[1..<17])
        if typ == Link2Block.text {
            guard p[0] <= Link2Block.textMax else { throw DecodeError(why: "TEXT length") }
            return ("text", Array(p[1..<(1 + Int(p[0]))]), [])
        }
        if typ == Link2Block.state {
            state = (p[0], Array(p[1..<8]), Array(p[8..<12]), p[12] == 0 ? 50 : Int(p[12]), Int(p[13]) << 8 | Int(p[14]))
            if let d = droppedMark { stats.meterDropped += (Int(p[15]) - d) & 0xFF }
            droppedMark = Int(p[15])
            return ("state", [], [])
        }
        return ("read", [], try readPayload(p))
    }

    private struct Cur { var v: Int; var negzero: Bool; var ovl: Int; var bar: Int; var bsign: Int }

    private func readPayload(_ p: [UInt8]) throws -> [([UInt8], Double)] {
        guard let st = state, p[0] == st.version else {
            stats.stale += 1
            return []
        }
        let period = Double(st.period) * Link2Block.tick
        var sub = Array(p[2..<5])
        let r = Array(p[5...])
        guard r[0] == 0xE2 || r[0] == 0xE3 else { throw DecodeError(why: "READ without a full first reading") }
        var out: [[UInt8]] = []
        var cur: Cur?
        var k = 0
        var slots: [Int?] = []
        while k < r.count && r[k] != 0x00 {
            let t = r[k]
            if t == 0xF4 {
                guard k + 1 < r.count else { throw DecodeError(why: "GAP cut") }
                slots.append(Int(r[k + 1]))
                k += 2
                continue
            }
            if t == 0xF0 {
                guard k + 3 < r.count else { throw DecodeError(why: "SUB cut") }
                sub = Array(r[(k + 1)...(k + 3)])
                k += 4
                continue
            }
            if t & 0xC0 == 0x80 {
                guard var c = cur else { throw DecodeError(why: "difference without a base") }
                let d = Int(t & 0x3F)
                c.v += d & 0x20 != 0 ? d - 64 : d
                c.negzero = false
                cur = c
                k += 1
            } else if t >= 0xC0 && t <= 0xD9 {
                guard var c = cur, k + 1 < r.count else { throw DecodeError(why: "bar record") }
                let x = Int(r[k + 1])
                let d = x & 0x7F
                c.v += d & 0x40 != 0 ? d - 128 : d
                c.bar = Int(t) - 0xC0
                c.bsign = x >> 7
                c.negzero = false
                cur = c
                k += 2
            } else if (0xE0...0xE3).contains(t) {
                if k + 3 >= r.count || (t & 2 != 0 && k + 4 >= r.count) { throw DecodeError(why: "absolute record cut") }
                let v2 = Int(r[k + 1]), v1 = Int(r[k + 2]), v0 = Int(r[k + 3])
                let a = (v2 & 3) << 16 | v1 << 8 | v0
                let neg = v2 & 0x80 != 0
                if cur == nil && t & 2 == 0 { throw DecodeError(why: "first reading without its bar") }
                var c = cur ?? Cur(v: 0, negzero: false, ovl: 0, bar: 0, bsign: 0)
                c.v = neg ? -a : a
                c.negzero = neg && a == 0
                c.ovl = Int(t & 1)
                k += 4
                if t & 2 != 0 {
                    c.bar = Int(r[k] & 0x1F)
                    c.bsign = Int(r[k] >> 5) & 1
                    k += 1
                }
                cur = c
            } else {
                throw DecodeError(why: String(format: "unknown record %02X", t))
            }
            guard let c = cur, abs(c.v) < 1 << 18, c.bar <= 25 else { throw DecodeError(why: "value out of range") }
            out.append(frame(c, sub, st.st, st.ident))
            slots.append(nil)
        }
        // ages: the last reading is p[1] ticks old; each earlier one a period (plus the gaps noted) before the next
        var gaps: [Int] = []
        var g = 0
        for s in slots {
            if let s { g += s } else { gaps.append(g); g = 0 }
        }
        var ages = [Double](repeating: 0, count: out.count)
        var age = Double(p[1]) * Link2Block.tick
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            ages[i] = age
            age += period * Double(1 + gaps[i])
        }
        stats.readings += out.count
        return Array(zip(out, ages))
    }

    private func frame(_ c: Cur, _ sub: [UInt8], _ st: [UInt8], _ ident: [UInt8]) -> [UInt8] {
        let a = abs(c.v)
        let neg = c.v < 0 || c.negzero
        var f = [UInt8](repeating: 0, count: 19)
        f[0] = 0xF2
        f[1..<5] = ident[0..<4]
        f[5] = st[0] | UInt8((a >> 16) & 3) << 6
        f[6] = st[1] | UInt8(c.ovl << 7) | (neg ? 0x40 : 0)
        f[7] = UInt8((a >> 8) & 0xFF)
        f[8] = UInt8(a & 0xFF)
        f[9] = st[2]
        f[10..<13] = sub[0..<3]
        f[13] = st[3] | UInt8(c.bsign << 2)
        f[14] = UInt8(c.bar)
        f[15..<18] = st[4..<7]
        f[18] = Frames.xor(f[0..<18])
        return f
    }
}
