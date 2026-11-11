// The meter's SETUP settings over the page Ld link: read all, change one (GET / PUT of firmware ble/bftset.s;
// companion settings.py).
//
//     0x16 GET    -                   answer: field = count, data = id:u16 value:u8 entries
//     0x17 PUT    id:u16 value:u8     answer: field = id, data = the value now in effect
// F-1.33 on: GET start:u8 max:u8 flags:u8 = 1 answers id:u16 value:u16 entries, and PUT id:u16 value:u16.
// The id 0x020 is one byte with four fields (REL view, trigger, clock, anti-hunting), shown as rows 0x120..0x420; a
// change of one row is a read-modify-write here.  Every PUT is compared with its answer and read back.

import Foundation

public struct SettingDef: Equatable, Sendable {
    public var id: Int, wire: Int
    public var code: String, name: String
    public var min: Int, max: Int
    public var choices: [String]?
    public var shift = 0, mask = 0xFF
    public var wide = false
}

public struct SettingItem: Equatable, Identifiable, Sendable {
    public var id: Int
    public var code: String, tag: String, name: String
    public var value: Int, min: Int, max: Int
    public var choices: [String]?
    public var text: String
    public var texts: [String]?          // the text of every value min..max (nil: too many values)
    public var unit: String?
    public var scale: Double
}

public enum MeterSettings {
    public static let tGet: UInt8 = 0x16, tPut: UInt8 = 0x17
    public static let b20 = 0x020
    public static let huntID = 0x420, buzzerID = 0x01E, contID = 0x014
    public static let getPageFirst = 8, getRetries = 8, getPageWait = 3.0
    public static let textsMax = 101
    public static let units: [String: (String, Double)] = ["Ch": ("", 1), "th": ("ohm", 1), "HY": ("ohm", 0.1)]

    static func s(_ id: Int, _ code: String, _ name: String, _ lo: Int, _ hi: Int, _ choices: [String]? = nil,
                  wire: Int? = nil, shift: Int = 0, mask: Int = 0xFF, wide: Bool = false) -> SettingDef {
        SettingDef(id: id, wire: wire ?? id, code: code, name: name, min: lo, max: hi, choices: choices, shift: shift,
                   mask: mask, wide: wide)
    }

    /// bftset.s bfs_tab, in its order.
    public static let table: [SettingDef] = [
        s(0x00F, "tc", "Thermocouple type (TEMP)", 0, 5, ["K", "J", "T", "N", "R", "S"]),
        s(0x010, "item 0", "Temperature unit", 0, 1, ["degF", "degC"]),
        s(0x011, "r", "dBm reference (ACV)", 0, 3, ["600 ohm", "50 ohm", "75 ohm", "dBV"]),
        s(0x013, "dSP", "Display level", 0, 1, ["1 (steadiest)", "2 (quicker)"]),
        s(0x014, "item 10", "Continuity threshold (BEEP)", 0, 17),
        s(0x015, "bt", "Bluetooth frame rate", 0, 3, ["2 per second", "4 per second", "10 per second", "20 per second"]),
        s(0x016, "item 2", "Auto power-off disabled", 0, 1, ["no", "yes"]),
        s(0x02B, "APO", "Auto power-off time", 0, 3, ["30 min", "1 min", "15 min", "60 min"]),
        s(0x02C, "CHIrP", "Diode contact chirp (DIODE)", 0, 1, ["off", "on"]),
        s(0x017, "bL", "Backlight auto-off", 0, 100),
        s(0x01A, "item 4", "LCD contrast", 10, 17),
        s(0x01B, "item 11", "VA burden \"bd\"", 0, 1, ["off", "on"]),
        s(0x01E, "item 3", "Buzzer", 0, 2, ["off", "on", "quiet (keys silent)"]),
        s(0x120, "rEL", "REL display", 0, 1, ["difference", "percent"], wire: b20, shift: 0, mask: 0x01),
        s(0x220, "tr", "Logging trigger", 0, 2, ["interval", "on change", "on limit verdict"], wire: b20, shift: 1, mask: 0x03),
        s(0x320, "CL", "Clock", 0, 1, ["24 hour", "12 hour"], wire: b20, shift: 3, mask: 0x01),
        s(0x420, "HUnt", "Capacitance anti-hunting", 0, 1, ["off", "on"], wire: b20, shift: 4, mask: 0x01),
        s(0x021, "bH", "Continuity beep hold (BEEP)", 0, 3, ["100 ms", "50 ms", "25 ms", "off (15 ms)"]),
        s(0x022, "Ch", "Logging change threshold", 1, 255),
        s(0x023, "bAt", "Battery type", 0, 1, ["alkaline (4.1 V)", "NiMH (4.7 V)"]),
        s(0x028, "LP", "Current loop view (DC mA)", 0, 2, ["off", "4-20 mA", "0-20 mA"]),
        s(0x029, "Pt", "RTD temperature view (ohm)", 0, 2, ["off", "Pt100", "Pt1000"]),
        s(0x02A, "BAT", "Battery voltage trim", 50, 150),
        s(0x02F, "HY", "Continuity hysteresis, user codes (BEEP)", 1, 250),
        s(0x02D, "th", "Continuity threshold, user codes (BEEP)", 1, 500, wide: true),
    ]
    public static let byID = Dictionary(uniqueKeysWithValues: table.map { ($0.id, $0) })

    public static func parseGet(_ count: Int, _ data: [UInt8], wide: Bool = false) throws -> [(Int, Int)] {
        let size = wide ? 4 : 3
        guard data.count == size * count else {
            throw CardError("GET answer: \(count) entries but \(data.count) bytes of data")
        }
        return stride(from: 0, to: data.count, by: size).map { i in
            (Int(data[i]) | Int(data[i + 1]) << 8, wide ? Int(data[i + 2]) | Int(data[i + 3]) << 8 : Int(data[i + 2]))
        }
    }

    public static func getAnswer(_ pairs: [(Int, Int)], wide: Bool = false) -> (Int, [UInt8]) {
        (pairs.count, pairs.flatMap { i, v in
            [UInt8(i & 0xFF), UInt8(i >> 8)] + (wide ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v)])
        })
    }

    public static func putRequest(_ wire: Int, _ value: Int, wide: Bool = false) -> [UInt8] {
        [UInt8(wire & 0xFF), UInt8(wire >> 8)] + (wide ? [UInt8(value & 0xFF), UInt8(value >> 8)] : [UInt8(value)])
    }

    public static func parsePut(_ wire: Int, _ field: Int, _ data: [UInt8], wide: Bool = false) throws -> Int {
        let n = wide ? 2 : 1
        guard field == wire, data.count == n else {
            throw CardError(String(format: "PUT answer for id 0x%03X with %d bytes of data, expected 0x%03X and %d", field, data.count, wire, n))
        }
        return wide ? Int(data[0]) | Int(data[1]) << 8 : Int(data[0])
    }

    public static func field(_ s: SettingDef, _ raw: Int) -> Int { s.wide ? raw : (raw >> s.shift) & s.mask }

    public static func merge(_ s: SettingDef, _ raw: Int, _ value: Int) -> Int {
        s.wide ? value : (raw & ~(s.mask << s.shift) & 0xFF) | ((value & s.mask) << s.shift)
    }

    public static func text(_ s: SettingDef, _ v: Int) -> String {
        guard v >= s.min && v <= s.max else { return "invalid (\(v))" }
        if let c = s.choices { return c[v] }
        if s.code == "bL" { return v == 0 ? "off" : v == 1 ? "30 s" : "\(v - 1) min" }
        if s.id == contID { return Display.beepText[v] }
        if s.id == 0x01A { return "Lcd-\(v - 10)" }
        if s.code == "BAT" { return String(format: "%+.1f %%", Double(v - 100) * 0.2) }
        if s.code == "HY" { return String(format: "%.1f ohm", Double(v) / 10) }
        if s.code == "th" { return "\(v) ohm" }
        return String(v)
    }

    public static func tag(_ s: SettingDef) -> String { s.code.hasPrefix("item ") ? "page " + s.code.dropFirst(5) : s.code }

    public static func texts(_ s: SettingDef) -> [String]? {
        if s.max - s.min + 1 > textsMax || units[s.code] != nil { return nil }
        return (s.min...s.max).map { text(s, $0) }
    }

    public static func item(_ s: SettingDef, _ raw: Int) -> SettingItem {
        let v = field(s, raw)
        let u = units[s.code]
        return SettingItem(id: s.id, code: s.code, tag: tag(s), name: s.name, value: v, min: s.min, max: s.max,
                           choices: s.choices, text: text(s, v), texts: texts(s), unit: u?.0, scale: u?.1 ?? 1)
    }
}

/// Read and change the meter's settings.  `hunt` (F-1.16), `quiet` (F-1.24), `paged` (old module, F-1.25),
/// `userCont` (F-1.33): what the connected firmware knows.
public final class SettingsClient {
    let c: CardClient
    let hunt: Bool, quiet: Bool, paged: Bool, userCont: Bool

    public init(client: CardClient, hunt: Bool = true, quiet: Bool = true, paged: Bool = false, userCont: Bool = true) {
        c = client
        self.hunt = hunt
        self.quiet = quiet
        self.paged = paged
        self.userCont = userCont
    }

    public func rows() -> [SettingDef] {
        MeterSettings.table.compactMap { d in
            var s = d
            if s.id == MeterSettings.huntID && !hunt { return nil }
            if s.id == MeterSettings.buzzerID && !quiet {
                s.max = 1
                s.choices = Array(s.choices!.prefix(2))
            }
            if !userCont {
                if s.wide { return nil }
                if s.id == MeterSettings.contID { s.max = 15 }
            }
            return s
        }
    }

    /// wire id -> value as the meter reports; ids the table does not know are dropped.
    public func rawAll() async throws -> [Int: Int] {
        let known = Set(MeterSettings.table.map(\.wire))
        let pairs: [(Int, Int)]
        if paged {
            pairs = try await pagedGet()
        } else if userCont {
            let (field, data) = try await c.ok(MeterSettings.tGet, [0, 255, 1])
            if field & 0x8000 == 0 {
                throw CardError(String(format: "GET: the meter did not answer every setting (field 0x%04X)", field))
            }
            pairs = try MeterSettings.parseGet(field & 0x7FFF, data, wide: true)
        } else {
            let (field, data) = try await c.ok(MeterSettings.tGet)
            pairs = try MeterSettings.parseGet(field, data)
        }
        var out: [Int: Int] = [:]
        for (i, v) in pairs where known.contains(i) { out[i] = v }
        return out
    }

    private func pagedGet() async throws -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = 0, most = MeterSettings.getPageFirst
        for _ in 0..<64 {
            var answer: (Int, Int, [UInt8])?
            for _ in 0..<MeterSettings.getRetries {
                do {
                    answer = try await c.request(MeterSettings.tGet, [UInt8(start), UInt8(most)] + (userCont ? [1] : []),
                                                 timeout: MeterSettings.getPageWait, retries: 1)
                    break
                } catch {
                    if c.cancelled { throw error }
                    most = max(1, most / 2)
                }
            }
            guard let (status, field, data) = answer.map({ ($0.0, $0.1, $0.2) }) else {
                throw CardError("no answer from the meter (is \"Ld-bt\" still shown on it?)")
            }
            if status != 0 { throw CardError(CardProtocol.describe(status, field), status: status) }
            let count = field & 0x7FFF, end = field & 0x8000 != 0
            out += try MeterSettings.parseGet(count, data, wide: userCont)
            start += count
            if end || count == 0 { return out }
        }
        throw CardError("GET: the settings did not end after 64 pages")
    }

    public func getAll() async throws -> [SettingItem] {
        let raw = try await rawAll()
        return rows().compactMap { s in raw[s.wire].map { MeterSettings.item(s, $0) } }
    }

    /// Change one setting (range checked first, written, answer and read-back compared); returns getAll().
    public func put(_ id: Int, _ value: Int) async throws -> [SettingItem] {
        guard let def = MeterSettings.byID[id] else { throw CardError("setting \(id) is not one the app changes") }
        guard value >= def.min && value <= def.max else { throw CardError("\(def.code): the value must be \(def.min)..\(def.max)") }
        guard let s = rows().first(where: { $0.id == id }) else {
            throw CardError("\(def.code) needs firmware \(def.wide ? "F-1.33" : "F-1.16") or newer")
        }
        if value > s.max {
            throw CardError("\(s.code) \(def.choices?[value] ?? String(value)) needs firmware \(id == MeterSettings.contID ? "F-1.33" : "F-1.24") or newer")
        }
        let raw = try await rawAll()
        guard let cur = raw[s.wire] else { throw CardError("the meter does not report \(s.code)") }
        if s.wire == MeterSettings.b20 && (cur > 31 || (s.code != "tr" && (cur >> 1) & 3 == 3)) {
            throw CardError(String(format: "%@: the meter reports the value 0x%02X of its shared setting, which it would refuse; set the logging trigger (tr) first", s.code, cur))
        }
        let send = MeterSettings.merge(s, cur, value)
        let (status, field, data) = try await c.request(MeterSettings.tPut, MeterSettings.putRequest(s.wire, send, wide: s.wide))
        if status != 0 { throw CardError("\(s.code): \(CardProtocol.describe(status, field))", status: status) }
        let applied = try MeterSettings.parsePut(s.wire, field, data, wide: s.wide)
        if applied != send { throw CardError("\(s.code): the meter applied \(applied) instead of \(send)") }
        let after = try await rawAll()
        guard let a = after[s.wire], MeterSettings.field(s, a) == value else {
            throw CardError("\(s.code): the meter did not keep the value (read back \(after[s.wire].map { String(MeterSettings.field(s, $0)) } ?? "nothing"))")
        }
        return rows().compactMap { t in after[t.wire].map { MeterSettings.item(t, $0) } }
    }
}

/// Diagnosis values of the file transfer (STATUS 0..25, ble/bft.s bft_diag_tab) and their readable text
/// (companion diag.py).
public enum TransferDiagnosis {
    public static let count = 26
    public static let baseCount = 21
    static let cardStep = [1: "open", 2: "seek", 3: "write", 4: "short write (card full?)", 5: "close", 6: "read back"]

    public static func cardDiag(_ v: Int) -> String {
        "step \(cardStep[v >> 8] ?? String(v >> 8)), FatFs result \(v & 0xFF)"
    }

    public static func explain(_ v: [Int]) -> String {
        guard v.count >= 7 else { return "" }
        let op = v[3] & 0xFF, reason = v[3] >> 8
        let why: [String: String] = [
            "1/1": "read: card did not return to the transfer state", "1/2": "read: SDIO error flag",
            "1/3": "read: data end / DMA end not seen in time", "2/1": "write: card did not return to the transfer state",
            "2/2": "write: the end-of-write wait ran out of polls (or CMD12 failed)", "2/3": "write: SDIO error code",
        ]
        let sta = v[4]
        let flags = [(1, "DCRCFAIL"), (3, "DTIMEOUT"), (4, "TXUNDERR"), (5, "RXOVERR"), (9, "STBITERR")]
            .filter { sta >> $0.0 & 1 != 0 }.map(\.1)
        var text = String(format: "%d failed card sessions in this transfer, last card failure %@; driver: %d failed calls since power-on, last %@, SDIO_STA 0x%04X [%@], transfer error %d, wait result %d",
                          v[0], cardDiag(v[1]), v[2], why["\(op)/\(reason)"] ?? "op \(op) reason \(reason)", sta,
                          flags.joined(separator: ", "), v[5], v[6])
        if v.count >= 13 {
            let f = v[7]
            text += String(format: "; at the last end-wait timeout: data end flag %d, DMA end flag %d, DMA ch4 flags 0x%X, DMA words left %d, SDIO bytes left %d, SDIO_STA high 0x%04X; %d reads taken on the hardware counters",
                           f >> 1 & 1, f & 1, v[8], v[9], v[10], v[11], v[12])
        }
        if v.count >= 16 {
            let r1 = v[13] | v[14] << 16
            let states = ["idle", "ready", "ident", "stby", "tran", "data", "rcv", "prg", "dis"]
            let card: String
            if r1 == 0xFFFF_FFFF {
                card = "no CMD13 answer"
            } else {
                let st = r1 >> 9 & 0xF
                let errs = [(31, "OUT_OF_RANGE"), (30, "ADDRESS_ERROR"), (29, "BLOCK_LEN_ERROR"), (28, "ERASE_SEQ_ERROR"),
                            (27, "ERASE_PARAM"), (26, "WP_VIOLATION"), (23, "COM_CRC_ERROR"), (22, "ILLEGAL_COMMAND"),
                            (21, "CARD_ECC_FAILED"), (20, "CC_ERROR"), (19, "ERROR"), (8, "READY_FOR_DATA")]
                    .filter { r1 >> $0.0 & 1 != 0 }.map(\.1)
                card = String(format: "card status 0x%08X: state %@ [%@]", r1, st < states.count ? states[st] : String(st),
                              errs.joined(separator: ", "))
            }
            text += "; last CMD13 before the failure: \(card); the polling lasted \(v[15]) ticks of 10 ms"
        }
        if v.count >= 18 { text += "; \(v[16]) failed card start-ups since power-on, last sd_init error \(v[17])" }
        if v.count >= 21 {
            text += "; \(v[18]) SCR reads since power-on, \(v[19]) of them with no word and \(v[20]) with one word read before the block end"
        }
        if v.count >= 26 {
            let phase = [0: "none", 1: "wait 1 (DMA / transfer end)", 2: "wait 2 (the card's busy)"][v[21]] ?? String(v[21])
            let a22 = v[23]
            let ans = a22 & 0x8000 == 0 ? "none" : "SD error \(a22 >> 8 & 0x7F), \(a22 & 0xFF) block(s) written"
            text += "; last write wait that ran out: \(phase) after \(v[22]) ticks of 10 ms (the end-wait values above are from that moment); last ACMD22 answer: \(ans); \(v[24]) late block(s) confirmed, \(v[25]) block(s) written again"
        }
        return text
    }
}
