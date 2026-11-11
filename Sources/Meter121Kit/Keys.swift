// Remote keys: the meter's eight keys as key frames F4 (firmware ble/commands.s fn_0800C332, key/keys.s fn_08014AE6;
// companion keys.py).  Short press 1..8, long press the same with bit 7 set.  A remote SETUP is refused by the meter
// while logging and starts an offset calibration in calibration mode, so the app asks for a deliberate confirmation.

public enum MeterKey: String, CaseIterable, Sendable {
    case range = "RANGE", hold = "HOLD", rel = "REL", peak = "PEAK", mode = "MODE", minmax = "MINMAX", mem = "MEM",
         setup = "SETUP"

    public var shortCode: UInt8 {
        switch self {
        case .range: 1
        case .hold: 2
        case .rel: 3
        case .peak: 4
        case .mode: 5
        case .minmax: 6
        case .mem: 7
        case .setup: 8
        }
    }

    public var label: String { self == .minmax ? "MIN/MAX" : rawValue }

    public func code(long: Bool = false) -> UInt8 { shortCode | (long ? 0x80 : 0) }

    public func frame(long: Bool = false) -> [UInt8] { Frames.keyFrame(code(long: long)) }

    /// A key from its name in any case; MIN/MAX, MIN_MAX and MIN-MAX also.
    public init?(name: String) {
        var k = name.trimmingCharacters(in: .whitespaces).uppercased()
        if ["MIN/MAX", "MIN_MAX", "MIN-MAX"].contains(k) { k = "MINMAX" }
        self.init(rawValue: k)
    }
}

import Foundation
