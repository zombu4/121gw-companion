// Time for the meter's clock (companion clock.py): the SNTP packet (RFC 4330) and the meter's set-clock frame.
//
// The meter's clock chip keeps local time without a time zone, so the frame carries the phone's local time at the
// moment of sending.  Set-clock frame (analysis/ble_packet.md 6): F8 followed by seven pairs of ASCII hex digits
// v0..v6: year 0..99, month, day, hour 0..23, minute, second as plain numbers, v6 = XOR of v0..v5.  The fast
// firmware applies every valid frame (IMP-31) and echoes it.
// The UDP exchange itself is in the app (Network framework); this file has the pure parts.

import Foundation

public enum MeterClock {
    public static let defaultServer = "pool.ntp.org"
    static let ntpEpoch: Double = 2_208_988_800            // seconds from 1900-01-01 to 1970-01-01

    /// The set-clock frame for the local time of `date` in `timeZone`.
    public static func clockFrame(_ date: Date, timeZone: TimeZone = .current) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let v = [c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!].map { UInt8($0) }
        let x = Frames.xor(v)
        return [0xF8] + (v + [x]).flatMap { Frames.hex2($0) }
    }

    /// A 48-byte SNTP client request carrying `t1` (unix seconds) as its transmit timestamp.
    public static func ntpRequest(t1: Double) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 48)
        req[0] = (0 << 6) | (4 << 3) | 3                   // leap 0, version 4, mode 3 (client)
        put(&req, 40, t1)
        return req
    }

    public struct NTPResult: Equatable, Sendable {
        public var offset: Double                          // server - local clock, s
        public var delay: Double                           // round trip, s
    }

    public enum NTPError: Error, Equatable { case short, unusable(mode: Int, stratum: Int) }

    /// Offset and round trip from the answer, t1 = local send time, t4 = local receive time (unix seconds).
    public static func ntpParse(_ data: [UInt8], t1: Double, t4: Double) throws -> NTPResult {
        guard data.count >= 48 else { throw NTPError.short }
        let mode = Int(data[0] & 7), stratum = Int(data[1])
        guard mode == 4, stratum != 0, stratum <= 15 else { throw NTPError.unusable(mode: mode, stratum: stratum) }
        let t2 = get(data, 32), t3 = get(data, 40)
        return NTPResult(offset: ((t2 - t1) + (t3 - t4)) / 2, delay: (t4 - t1) - (t3 - t2))
    }

    static func put(_ b: inout [UInt8], _ o: Int, _ t: Double) {
        let s = UInt32(truncatingIfNeeded: Int64(t.rounded(.down)) + Int64(ntpEpoch))
        let f = UInt32(truncatingIfNeeded: Int64((t - t.rounded(.down)) * 4_294_967_296))
        for i in 0..<4 {
            b[o + i] = UInt8(truncatingIfNeeded: s >> (24 - 8 * i))
            b[o + 4 + i] = UInt8(truncatingIfNeeded: f >> (24 - 8 * i))
        }
    }

    static func get(_ b: [UInt8], _ o: Int) -> Double {
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(b[o + $1]) } }
        return Double(u32(o)) - ntpEpoch + Double(u32(o + 4)) / 4_294_967_296
    }
}
