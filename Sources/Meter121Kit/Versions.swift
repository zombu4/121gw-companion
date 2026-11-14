// Versions of the meter's firmware and bootloader, and which features each brings (companion app.py *_MIN_VERSION,
// releases.py).  The meter shows its firmware as F-A.BC (release tag vA.B.C) and the two-part bootloader as B-A.BC
// (tag bl-vA.B.C); "EEV" is EEVblog's original bootloader.

import Foundation

public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var a: Int, b: Int, c: Int
    public init(_ a: Int, _ b: Int, _ c: Int) { self.a = a; self.b = b; self.c = c }

    public static func < (l: Version, r: Version) -> Bool { (l.a, l.b, l.c) < (r.a, r.b, r.c) }
    public var description: String { "\(a).\(b).\(c)" }

    /// (A, B, C) from "F-A.BC" (firmware) or "B-A.BC" (bootloader).
    public init?(meterText text: String?, prefix: Character = "F") {
        guard let t = text, t.count == 6 else { return nil }
        let ch = Array(t)
        guard ch[0] == prefix, ch[1] == "-", ch[3] == ".",
              let a = ch[2].wholeNumberValue, let b = ch[4].wholeNumberValue, let c = ch[5].wholeNumberValue
        else { return nil }
        self.init(a, b, c)
    }

    /// From a release tag "vA.B.C" / "bl-vA.B.C" / "companion-vA.B.C".
    public init?(tag: String, prefix: String) {
        guard tag.hasPrefix(prefix) else { return nil }
        let parts = tag.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }
        if prefix != "companion-v" && (a > 9 || b > 9 || c > 9 || parts.contains { $0.count != 1 }) { return nil }
        self.init(a, b, c)
    }

    public var firmwareText: String { "F-\(a).\(b)\(c)" }
    public var bootloaderText: String { "B-\(a).\(b)\(c)" }
}

/// What the connected firmware can do, by the first version that brought it.
public enum Feature: CaseIterable, Sendable {
    case bootloaderVersion   // F-1.03: key code 0x92, answer F7
    case extendedDiagnosis   // F-1.15: key codes 0x93..0x95, STATUS 40..48
    case hunt                // F-1.16: setting 0x020 bit 4 (HUnt)
    case clockMeasurement    // F-1.17: key code 0x96, frame FA, STATUS 49..55
    case leaveLd             // F-1.17: page Ld request LEAVE
    case careful             // F-1.19: key codes 0x97 / 0x98, LIST max, CHUNK len
    case quiet               // F-1.24: buzzer value qUiEt
    case linkAdapt           // F-1.25: reading rate, settings in pages
    case heartbeat           // F-1.26: 0xFE / 0xFD watch
    case link2               // F-1.31: link 2 blocks (key codes 0xA8, 0xAA..0xB2)
    case packed              // F-1.32: READZ and packed page Ld transfers
    case userContinuity      // F-1.33: continuity codes 16 / 17, settings 0x02D and 0x02F
    case clamp               // F-1.35: setting 0x020 bits 7..5 (CLP), clamp code in status byte 13 (issue 39)

    public var since: Version {
        switch self {
        case .bootloaderVersion: Version(1, 0, 3)
        case .extendedDiagnosis: Version(1, 1, 5)
        case .hunt: Version(1, 1, 6)
        case .clockMeasurement, .leaveLd: Version(1, 1, 7)
        case .careful: Version(1, 1, 9)
        case .quiet: Version(1, 2, 4)
        case .linkAdapt: Version(1, 2, 5)
        case .heartbeat: Version(1, 2, 6)
        case .link2: Version(1, 3, 1)
        case .packed: Version(1, 3, 2)
        case .userContinuity: Version(1, 3, 3)
        case .clamp: Version(1, 3, 5)
        }
    }
}

public extension Version {
    func has(_ f: Feature) -> Bool { self >= f.since }
    /// B-1.15: packed transfers in the two-part bootloader's update mode.
    static let packedBootloader = Version(1, 1, 5)
}

/// The old Bluegiga BLE112 module negotiates only the minimum ATT MTU (the BGM220S: 247).
public let carefulMTU = 23
