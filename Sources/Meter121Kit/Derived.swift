// Values derived from the decoded reading on the phone; the meter is not involved (companion derived.py).
//
//   relPct    percent change against the value the reading had when REL was switched on
//   loopPct   DC current as percent of a 4-20 mA or 0-20 mA loop
//   ptC       temperature of a Pt100 / Pt1000 sensor from the measured resistance (IEC 60751)
//   limit     PASS / HI / LO against a low and a high limit of the user
// Each is nil where it cannot be told, never guessed.  The maths is in the SI base unit of the reading.

import Foundation

public enum DerivedUnits {
    /// displayed unit -> (quantity, factor to the SI base unit)
    public static let units: [String: (String, Double)] = [
        "V": ("V", 1), "mV": ("V", 1e-3), "Hz": ("Hz", 1), "kHz": ("Hz", 1e3), "ms": ("s", 1e-3), "%": ("%", 1),
        "Ω": ("ohm", 1), "kΩ": ("ohm", 1e3), "MΩ": ("ohm", 1e6), "nF": ("F", 1e-9), "µF": ("F", 1e-6),
        "µVA": ("VA", 1e-6), "mVA": ("VA", 1e-3), "VA": ("VA", 1), "µA": ("A", 1e-6), "mA": ("A", 1e-3), "A": ("A", 1),
        "°C": ("degC", 1), "°F": ("degF", 1),
    ]
    public static let aliases = ["ohm": "Ω", "kohm": "kΩ", "mohm": "MΩ", "uF": "µF", "uA": "µA", "uVA": "µVA",
                                 "degC": "°C", "degF": "°F"]

    public static func scale(_ unit: String) -> (String, Double)? { units[aliases[unit] ?? unit] }
}

public enum LoopRange: String, CaseIterable, Codable, Sendable {
    case fourTwenty = "4-20", zeroTwenty = "0-20"
    var span: (Double, Double) { self == .fourTwenty ? (4, 20) : (0, 20) }
}

public enum PtType: String, CaseIterable, Codable, Sendable {
    case pt100 = "Pt100", pt1000 = "Pt1000"
    public var r0: Double { self == .pt100 ? 100 : 1000 }
}

public struct Limit: Codable, Equatable, Sendable {
    public var lo: Double?, hi: Double?
    public var unit: String
    public init(lo: Double?, hi: Double?, unit: String) { self.lo = lo; self.hi = hi; self.unit = unit }
}

public struct DerivedOptions: Codable, Equatable, Sendable {
    public var loopRange = LoopRange.fourTwenty
    public var ptType: PtType?
    public var limit: Limit?
    public init() {}
}

public struct DerivedValues: Equatable, Sendable {
    public var relPct: Double?
    public var loopPct: Double?
    public var ptC: Double?
    public var verdict: String?          // "PASS", "HI", "LO"
}

public struct Derived: Sendable {
    public static let cvdA = 3.9083e-3, cvdB = -5.775e-7, cvdC = -4.183e-12
    public static let ptMin = -200.0, ptMax = 850.0
    public static let modeOhm = 9
    public static let dcCurrentModes: Set<Int> = [17, 19, 21]

    public var options = DerivedOptions()
    private var last: Reading?
    private var abs_: (Int, String, Double)?
    private var ref: (Int, String, Double)?
    private var relOn = false

    public init() {}

    public static func ptResistance(_ t: Double, _ r0: Double) -> Double {
        var r = 1 + cvdA * t + cvdB * t * t
        if t < 0 { r += cvdC * (t - 100) * t * t * t }
        return r0 * r
    }

    public static func ptTemperature(_ r: Double, _ r0: Double) -> Double? {
        guard r.isFinite else { return nil }
        var lo = ptMin, hi = ptMax
        if r < ptResistance(lo, r0) || r > ptResistance(hi, r0) { return nil }
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            if ptResistance(mid, r0) < r { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static func base(_ r: Reading) -> (Int, String, Double)? {
        guard let v = r.value, let s = DerivedUnits.scale(r.unit) else { return nil }
        return (r.mode, s.0, v * s.1)
    }

    /// Track REL from every decoded reading, in order.
    public mutating func feed(_ r: Reading) {
        last = r
        let b = Self.base(r)
        guard r.symbols.contains("REL") else {
            abs_ = b
            ref = nil
            relOn = false
            return
        }
        if !relOn {                                     // REL has just gone on: the reference is the reading before
            relOn = true
            if let a = abs_, let b, a.0 == b.0, a.1 == b.1 { ref = a } else { ref = nil }
        } else if let rf = ref, b == nil || rf.0 != b!.0 || rf.1 != b!.1 {
            ref = nil                                   // mode or quantity changed while REL stayed on
        }
    }

    public func values() -> DerivedValues {
        var out = DerivedValues()
        guard let r = last, let b = Self.base(r) else { return out }
        let (mode, quantity, v) = b
        let rel = r.symbols.contains("REL")
        if rel, let rf = ref, rf.2 != 0 { out.relPct = v / rf.2 * 100 }
        if Self.dcCurrentModes.contains(mode) && !rel {
            let (lo, hi) = options.loopRange.span
            out.loopPct = (v * 1000 - lo) / (hi - lo) * 100
        }
        if mode == Self.modeOhm, let pt = options.ptType { out.ptC = Self.ptTemperature(v, pt.r0) }
        if let lim = options.limit, !rel, let s = DerivedUnits.scale(lim.unit), s.0 == quantity {
            let lf = s.1
            func sign(_ x: Double) -> Double { x >= 0 ? 1 : -1 }
            if let lo = lim.lo, v < lo * lf * (1 - 1e-9 * sign(lo)) {
                out.verdict = "LO"
            } else if let hi = lim.hi, v > hi * lf * (1 + 1e-9 * sign(hi)) {
                out.verdict = "HI"
            } else {
                out.verdict = "PASS"
            }
        }
        return out
    }
}
