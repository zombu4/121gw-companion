// In the spirit of the companion's tests/test_derived.py.
import XCTest
@testable import Meter121Kit

final class DerivedTests: XCTestCase {
    func reading(mode: Int, range: Int, value: Int, rel: Bool = false, neg: Bool = false) -> Reading {
        var f = [UInt8](repeating: 0, count: 19)
        f[0] = 0xF2; f[5] = UInt8(mode); f[6] = UInt8(range) | (neg ? 0x40 : 0)
        f[7] = UInt8((value >> 8) & 0xFF); f[8] = UInt8(value & 0xFF); f[13] = 0x10
        f[16] = rel ? 0x10 : 0
        f[18] = Frames.xor(f[0..<18])
        return Display.decode(f)
    }

    func testPt100AtKnownPoints() {
        XCTAssertEqual(Derived.ptTemperature(100, 100)!, 0, accuracy: 1e-9)
        XCTAssertEqual(Derived.ptTemperature(138.5055, 100)!, 100, accuracy: 1e-3)
        XCTAssertEqual(Derived.ptTemperature(18.52008, 100)!, -200, accuracy: 1e-3)
        XCTAssertNil(Derived.ptTemperature(10, 100))
    }

    func testRelPercentFromTheReadingBeforeREL() {
        var d = Derived()
        d.feed(reading(mode: 1, range: 0, value: 20000))          // 2.0000 V
        d.feed(reading(mode: 1, range: 0, value: 1000, rel: true)) // +0.1 V difference
        XCTAssertEqual(d.values().relPct!, 5, accuracy: 1e-9)
        var cold = Derived()
        cold.feed(reading(mode: 1, range: 0, value: 1000, rel: true))
        XCTAssertNil(cold.values().relPct)
    }

    func testLoopAndLimit() {
        var d = Derived()
        d.feed(reading(mode: 19, range: 1, value: 12000))         // DCmA 12.000 mA
        XCTAssertEqual(d.values().loopPct!, 50, accuracy: 1e-9)
        d.options.limit = Limit(lo: 11.5, hi: 12.0, unit: "mA")
        XCTAssertEqual(d.values().verdict, "PASS")
        d.options.limit = Limit(lo: 0.0125, hi: nil, unit: "A")
        XCTAssertEqual(d.values().verdict, "LO")
        d.options.limit = Limit(lo: 1, hi: 2, unit: "V")
        XCTAssertNil(d.values().verdict)
    }
}
