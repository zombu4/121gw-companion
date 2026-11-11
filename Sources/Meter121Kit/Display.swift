// Decode the 121GW status frame into the reading as the meter's display shows it (companion display.py).
//
// The decimal point of the main value is not in the frame: the meter takes it from dec_table[mode][range]
// (mode/mode.s:968-994), and the unit prefix from the annunciator routines (lcd/annun.s).  Both are tables here, taken
// from the firmware sources, not from the official app.  What the frame cannot tell is not shown rather than guessed.

import Foundation

public struct Bargraph: Equatable, Sendable {
    public var shown: Bool
    public var lit: Int            // segments lit including segment 0
    public var negative: Bool
    public var label: String       // full-scale label "5", "50", "500", "1000"

    public init(shown: Bool, lit: Int, negative: Bool, label: String) {
        self.shown = shown
        self.lit = lit
        self.negative = negative
        self.label = label
    }
}

public struct Reading: Equatable, Sendable {
    public var t: Date
    public var mode: Int
    public var modeName: String
    public var range: Int
    public var text: String        // the main display as shown ("-----" when the mode/range is not one the meter has)
    public var value: Double?      // in the displayed unit; nil on overload or blank
    public var unit: String
    public var dp: Int?
    public var overload: Bool
    public var subLabel: String
    public var subText: String
    public var subUnit: String
    public var symbols: [String]
    public var bar: Bargraph
    public var raw: [UInt8]

    /// mode / unit / range: the key the statistics and the trend restart on.
    public var scaleKey: String { "\(mode)/\(unit)/\(range)" }
}

public enum Display {
    public static let modes = ["LowZ", "DCV", "ACV", "DCmV", "ACmV", "TEMP", "FREQ", "PULSE", "DUTY", "OHM", "BEEP",
                               "DIODE", "CAP", "uVA", "mVA", "VA", "ACuA", "DCuA", "ACmA", "DCmA", "ACA", "DCA",
                               "DCuVA", "DCmVA", "DCVA"]

    // (digits after the point, unit as lit on the glass) per reachable range (dec_table, lcd/annun.s)
    static let table: [Int: [(Int, String?)]] = [
        0: [(1, "V")],
        1: [(4, "V"), (3, "V"), (2, "V"), (1, "V")],
        2: [(4, "V"), (3, "V"), (2, "V"), (1, "V")],
        3: [(3, "mV"), (2, "mV")],
        4: [(3, "mV"), (2, "mV")],
        5: [(1, nil)],                                                  // unit from [6]
        6: [(3, "Hz"), (2, "Hz"), (4, "kHz"), (3, "kHz"), (2, "kHz")],
        7: [(4, "ms"), (3, "ms"), (2, "ms")],
        8: [(1, "%")],
        9: [(3, "Ω"), (2, "Ω"), (4, "kΩ"), (3, "kΩ"), (2, "kΩ"), (4, "MΩ"), (3, "MΩ")],
        10: [(2, "Ω")],
        11: [(4, "V"), (3, "V")],
        12: [(3, "nF"), (2, "nF"), (4, "µF"), (3, "µF"), (2, "µF"), (0, "µF")],
        13: [(2, "µVA"), (1, "µVA"), (1, "µVA"), (0, "µVA")],
        14: [(3, "mVA"), (2, "mVA"), (2, "mVA"), (1, "mVA")],
        15: [(1, "mVA"), (0, "mVA"), (3, "VA"), (2, "VA")],
        16: [(3, "µA"), (2, "µA")],
        17: [(3, "µA"), (2, "µA")],
        18: [(4, "mA"), (3, "mA")],
        19: [(4, "mA"), (3, "mA")],
        20: [(2, "mA"), (4, "A"), (3, "A")],
        21: [(2, "mA"), (4, "A"), (3, "A")],
        22: [(2, "µVA"), (1, "µVA"), (1, "µVA"), (0, "µVA")],
        23: [(3, "mVA"), (2, "mVA"), (2, "mVA"), (1, "mVA")],
        24: [(1, "mVA"), (0, "mVA"), (3, "VA"), (2, "VA")],
    ]

    /// Continuity threshold texts (BEEP, sub codes 0xAA + 0..17; set/setup.s set_cont_text).
    public static let beepText = ["DN 30", "UP 30", "DN300", "UP300", "DN  1", "DN  5", "DN 10", "DN 50",
                                  "DN100", "DN200", "UP  1", "UP  5", "UP 10", "UP 50", "UP100", "UP200", "DNUSr", "UPUSr"]

    static func pow10(_ n: Int) -> Double { (0..<n).reduce(1.0) { a, _ in a * 10 } }

    static func fixed(_ mag: Int, _ dp: Int) -> String {
        if dp == 0 { return String(mag) }
        let p = Int(pow10(dp))
        let whole = mag / p, frac = mag % p
        return "\(whole)." + String(repeating: "0", count: dp - String(frac).count) + String(frac)
    }

    static func main(_ f: [UInt8], _ mode: Int, _ rng: Int) -> (String?, Double?, String, Int?) {
        var mag = Int((f[5] >> 6) & 3) << 16 | Int(f[7]) << 8 | Int(f[8])
        let neg = f[6] & 0x40 != 0
        guard let rows = table[mode], rng < rows.count else { return (nil, nil, "", nil) }
        var (dp, unit) = (rows[rng].0, rows[rng].1 ?? "")
        if mode == 5 { unit = f[6] & 0x20 != 0 ? "°C" : f[6] & 0x10 != 0 ? "°F" : "" }
        if f[6] & 0x80 != 0 { return ("OFL", nil, unit, dp) }     // overload: value bytes are stale
        if mag > 99999 {                                          // only through REL: trunc(D/10), dp - 1
            mag /= 10
            dp = max(dp - 1, 0)
        }
        var text = fixed(mag, dp)
        var value = Double(mag) / pow10(dp)
        if neg {
            text = "-" + text
            value = -value
        }
        return (text, value, unit, dp)
    }

    static func sub(_ f: [UInt8], _ mode: Int) -> (String, String, String) {
        let code = Int(f[9]), fl = f[10]
        let v = Int(f[11]) << 8 | Int(f[12])
        let d = Int(fl & 0x0F)
        let sign = fl & 0x40 != 0 ? "-" : ""
        func num(_ val: Int, _ dp: Int) -> String { sign + fixed(val, dp) }
        if mode == 10 && code >= 0xAA && code < 0xAA + beepText.count {
            var text = beepText[code - 0xAA]
            if code >= 0xAA + 16 { text = String(text.prefix(2)) + " \(v)" }
            return ("threshold", text, code >= 0xAA + 16 ? "Ω" : "")
        }
        switch code {
        case 100, 105:
            if fl & 0x80 != 0 { return ("temp", "OPEN", "") }
            return ("temp", num(v, 1), code == 100 ? "°C" : "°F")
        case 110: return ("battery", fixed(v, 1), "V")
        case 120, 125: return ("auto off", code == 120 ? "on" : "off", "")
        case 130: return ("year", String(2000 + Int(f[12])), "")
        case 135: return ("date", String(format: "%02d-%02d", f[11], f[12]), "")
        case 140: return ("time", String(format: "%02d:%02d", f[11], f[12]), "")
        case 160: return ("contrast", String(f[12]), "")
        case 6:
            if fl & 0x80 != 0 { return ("freq", "OFL", "") }
            return ("freq", num(v, d), fl & 0x20 != 0 ? "kHz" : "Hz")
        case 180:
            if fl & 0x80 != 0 { return ("dB", "OFL", "") }
            return ("dB", num(v, d), "dB")
        case 150: return ("burden", num(v, d), (16...21).contains(mode) ? "mV" : "")
        case 0x9B, 0x9C: return ("burden", code == 0x9B ? "on" : "off", "")
        case 1, 2:
            if fl & 0x80 != 0 { return ("voltage", "OFL", "") }
            return ("voltage", num(v, d), "V")
        case 0x10...0x15:
            if fl & 0x80 != 0 { return ("current", "OFL", "") }
            return ("current", num(v, d), (mode == 15 || mode == 24) && d == 3 ? "A" : "mA")
        case 11: return ("source", String(v), "V")
        default: return ("", "", "")
        }
    }

    static func symbols(_ f: [UInt8]) -> [String] {
        let s15 = f[15], s16 = f[16], s17 = f[17]
        var out: [String] = []
        if s15 & 0x10 != 0 { out.append("AC") }
        if s15 & 0x08 != 0 { out.append("DC") }
        if s15 & 0x04 != 0 { out.append("AUTO") }
        if s15 & 0x02 != 0 { out.append("APO") }
        if s15 & 0x01 != 0 { out.append("BAT") }
        if s15 & 0x40 != 0 { out.append("1kHz") }
        let peak = s15 & 0x20 != 0
        if peak { out.append("PEAK") }
        if s16 & 0x40 != 0 { out.append("BT") }
        if s16 & 0x20 != 0 { out.append("HV") }
        if s16 & 0x10 != 0 { out.append("REL") }
        let mm = Int(s16 & 0x07)
        if peak {
            out += [1: ["MAX"], 2: ["MIN"]][mm] ?? []
        } else {
            out += [1: ["MAX"], 2: ["MIN"], 3: ["AVG"], 4: ["MIN", "MAX", "AVG"]][mm] ?? []
        }
        switch (s17 >> 2) & 3 {
        case 1: out.append("A-HOLD")
        case 2: out.append("HOLD")
        default: break
        }
        if s17 & 0x10 != 0 { out.append("MEM") }
        return out
    }

    static func bar(_ f: [UInt8]) -> Bargraph {
        if f[13] & 0x10 != 0 { return Bargraph(shown: false, lit: 0, negative: false, label: "") }
        return Bargraph(shown: true, lit: min(Int(f[14]), 25) + 1, negative: f[13] & 0x04 != 0,
                        label: ["5", "50", "500", "1000"][Int(f[13] & 0x03)])
    }

    /// Reading of a checked 19-byte status frame received at time t.
    public static func decode(_ f: [UInt8], at t: Date = Date()) -> Reading {
        let mode = Int(f[5] & 0x3F), rng = Int(f[6] & 0x0F)
        let (text, value, unit, dp) = main(f, mode, rng)
        let (label, subText, subUnit) = sub(f, mode)
        return Reading(t: t, mode: mode, modeName: mode < modes.count ? modes[mode] : "mode \(mode)", range: rng,
                       text: text ?? "-----", value: value, unit: unit, dp: dp, overload: text == "OFL",
                       subLabel: label, subText: subText, subUnit: subUnit, symbols: symbols(f), bar: bar(f), raw: f)
    }
}
