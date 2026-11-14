// Current clamp (firmware F-1.35, GitHub issue 39): byte [13] bits 7..5 of the status frame carry the ratio code; the
// app shows amps with the point moved, mA when more than four places would follow the point, OFL when the current does
// not fit the five digits; the settings row CLP is bits 7..5 of the setting id 0x020, listed for F-1.35 and newer.

import XCTest
@testable import Meter121Kit

final class ClampTests: XCTestCase {
    func frame(_ mode: Int, _ rng: Int, _ mag: Int, clamp: Int = 0, neg: Bool = false, ovl: Bool = false) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 19)
        f[0] = 0xF2
        f[5] = UInt8(mode) | UInt8((mag >> 16) & 3) << 6
        f[6] = UInt8(rng) | (neg ? 0x40 : 0) | (ovl ? 0x80 : 0)
        f[7] = UInt8((mag >> 8) & 0xFF)
        f[8] = UInt8(mag & 0xFF)
        f[13] = UInt8(clamp << 5) | 0x10
        f[18] = Frames.xor(f[0..<18])
        return f
    }

    func shown(_ mode: Int, _ rng: Int, _ mag: Int, _ clamp: Int, neg: Bool = false) -> (String, String, Double?) {
        let r = Display.decode(frame(mode, rng, mag, clamp: clamp, neg: neg))
        return (r.text, r.unit, r.value)
    }

    func check(_ got: (String, String, Double?), _ text: String, _ unit: String, _ value: Double?,
               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.0, text, file: file, line: line)
        XCTAssertEqual(got.1, unit, file: file, line: line)
        if let value { XCTAssertEqual(got.2!, value, accuracy: 1e-9, file: file, line: line) } else { XCTAssertNil(got.2, file: file, line: line) }
    }

    func testOffIsVolts() {
        check(shown(1, 0, 2534, 0), "0.2534", "V", 0.2534)
        check(shown(3, 1, 25340, 0), "253.40", "mV", 253.4)
    }

    func testDCVEveryRatio() {
        check(shown(1, 0, 2534, 1), "253.4", "A", 253.4)
        check(shown(1, 0, 2534, 2), "25.34", "A", 25.34)
        check(shown(1, 0, 2534, 3), "2.534", "A", 2.534)
        check(shown(1, 0, 2534, 4), "0.2534", "A", 0.2534)
    }

    func testMilliVoltRangesAndMilliamps() {
        check(shown(3, 1, 25340, 1), "253.40", "A", 253.4)
        check(shown(3, 1, 25340, 2), "25.340", "A", 25.34)
        check(shown(3, 1, 25340, 3), "2.5340", "A", 2.534)
        check(shown(3, 1, 25340, 4), "253.40", "mA", 253.4)
        check(shown(3, 0, 50000, 3), "500.00", "mA", 500.0)
        check(shown(2, 0, 12345, 2), "123.45", "A", 123.45)            // 1.2345 V at 10 mV/A
        check(shown(4, 0, 12345, 4), "12.345", "mA", 12.345)
    }

    func testTooLargeShowsOFL() {
        let r = Display.decode(frame(1, 3, 2300, clamp: 1))
        XCTAssertEqual(r.text, "OFL")
        XCTAssertEqual(r.unit, "A")
        XCTAssertNil(r.value)
        XCTAssertTrue(r.overload)
        check(shown(1, 2, 2300, 2), "2300", "A", 2300)
        XCTAssertEqual(Display.decode(frame(1, 3, 2300, clamp: 2)).text, "OFL")
    }

    func testSignOverloadOtherModesAndBadCodes() {
        check(shown(1, 0, 2534, 2, neg: true), "-25.34", "A", -25.34)
        let o = Display.decode(frame(1, 0, 0, clamp: 2, ovl: true))
        XCTAssertEqual(o.text, "OFL")
        XCTAssertEqual(o.unit, "A")
        check(shown(19, 0, 12345, 2), "1.2345", "mA", 1.2345)             // DCmA unchanged
        check(shown(1, 0, 2534, 5), "0.2534", "V", 0.2534)                // codes 5..7: off
        check(shown(1, 0, 2534, 7), "0.2534", "V", 0.2534)
    }

    func testSettingsRow() {
        let s = MeterSettings.table.first { $0.id == 0x520 }!
        XCTAssertEqual(s.code, "CLP")
        XCTAssertEqual(s.wire, 0x020)
        XCTAssertEqual(s.shift, 5)
        XCTAssertEqual(s.mask, 7)
        XCTAssertEqual(s.max, 4)
        XCTAssertEqual(s.choices!, ["off", "1 mV/A", "10 mV/A", "100 mV/A", "1 V/A"])
        XCTAssertTrue(Version(1, 3, 5).has(.clamp))
        XCTAssertFalse(Version(1, 3, 4).has(.clamp))
    }
}
