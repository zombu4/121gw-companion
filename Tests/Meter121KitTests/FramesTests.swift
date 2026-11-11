import XCTest
@testable import Meter121Kit

/// A B5 5B answer frame of type `typ` (layout of the firmware's ble/bft.s: B5 5B type seq_lo seq_hi n payload crc).
func bftFrame(_ typ: UInt8, _ seq: UInt16, _ payload: [UInt8]) -> [UInt8] {
    let body: [UInt8] = [typ, UInt8(seq & 0xFF), UInt8(seq >> 8), UInt8(payload.count)] + payload
    let crc = Frames.crc16(body)
    return [0xB5, 0x5B] + body + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
}

final class FramesTests: XCTestCase {
    func testCRC16CCITTFalseCheckValue() {
        XCTAssertEqual(Frames.crc16(Array("123456789".utf8)), 0x29B1)
    }

    func testKeyFrames() {
        XCTAssertEqual(Frames.versionRequest, [0xF4] + Array("9090".utf8))
        XCTAssertEqual(MeterKey.rel.frame(), [0xF4] + Array("0303".utf8))
        XCTAssertEqual(MeterKey.mem.frame(long: true), [0xF4] + Array("8787".utf8))
        XCTAssertEqual(MeterKey(name: "min/max"), .minmax)
    }

    func testEveryFrameKindSplitAtEveryByte() {
        let status = L2Fixture.f2(1234, 12)
        let version = { () -> [UInt8] in
            var f: [UInt8] = [0xF6] + Array("F-133".utf8).prefix(0) + Array("F-133".utf8)
            f = Array(f.prefix(6))
            return f + [Frames.xor(f)]
        }()
        let clock = MeterClock.clockFrame(Date(timeIntervalSince1970: 1_762_900_000), timeZone: TimeZone(identifier: "UTC")!)
        let bft = bftFrame(0x82, 0x1234, [0xF2, 0xF4, 0xB5, 0x5B, 0x82, 0x00])
        let stream = status + Frames.versionRequest + version + clock + bft
        for k in 1..<stream.count {
            let r = Reassembler()
            let got = r.feed(stream[..<k]) + r.feed(stream[k...])
            XCTAssertEqual(got.map(\.kind), [.status, .keyEcho, .version, .clockEcho, .bft], "split at \(k)")
            XCTAssertEqual(r.dropped, 0)
        }
        XCTAssertEqual(Frames.versionText(version), "F-1.33")
    }

    func testDamagedFrameIsSkippedAndTheNextFound() {
        let a = bftFrame(0x82, 1, Array("abc".utf8)), b = bftFrame(0x82, 3, Array("xyz".utf8))
        var bad = bftFrame(0x82, 2, Array("mid".utf8))
        bad[8] ^= 0x55
        let r = Reassembler()
        var out: [Frame] = []
        let s = a + bad + b + [0, 1]
        for i in stride(from: 0, to: s.count, by: 5) { out += r.feed(s[i..<min(i + 5, s.count)]) }
        XCTAssertEqual(out.map(\.bytes), [a, b])
        XCTAssertGreaterThan(r.dropped, 0)
        XCTAssertFalse(r.damaged().isEmpty)
    }

    func testClockFrame() {
        // 2025-11-11 22:26:40 UTC
        let f = MeterClock.clockFrame(Date(timeIntervalSince1970: 1_762_900_000), timeZone: TimeZone(identifier: "UTC")!)
        let v: [UInt8] = [25, 11, 11, 22, 26, 40]
        XCTAssertEqual(f, [0xF8] + Array(String(format: "%02X%02X%02X%02X%02X%02X%02X", 25, 11, 11, 22, 26, 40, Int(Frames.xor(v))).utf8))
    }

    func testNTPRoundTrip() throws {
        var answer = MeterClock.ntpRequest(t1: 1000.25)
        answer[0] = 0x24; answer[1] = 2
        MeterClock.put(&answer, 32, 1010.5)
        MeterClock.put(&answer, 40, 1010.75)
        let r = try MeterClock.ntpParse(answer, t1: 1000.25, t4: 1001.0)
        XCTAssertEqual(r.offset, 10.0, accuracy: 1e-6)
        XCTAssertEqual(r.delay, 0.5, accuracy: 1e-6)
    }

    func testVersions() {
        XCTAssertEqual(Version(meterText: "F-1.33"), Version(1, 3, 3))
        XCTAssertEqual(Version(meterText: "B-1.15", prefix: "B"), Version(1, 1, 5))
        XCTAssertNil(Version(meterText: "v2.05"))
        XCTAssertEqual(Version(tag: "bl-v1.1.5", prefix: "bl-v"), Version(1, 1, 5))
        XCTAssertEqual(Version(tag: "companion-v1.3.14", prefix: "companion-v"), Version(1, 3, 14))
        XCTAssertTrue(Version(1, 3, 1).has(.link2))
        XCTAssertFalse(Version(1, 3, 0).has(.link2))
    }
}

final class DisplayTests: XCTestCase {
    func frame(mode: Int, range: Int, value: Int, neg: Bool = false, ovl: Bool = false, r6: UInt8 = 0,
               sub: [UInt8] = [0, 0, 0, 0], s13: UInt8 = 0x10, s14: UInt8 = 0, sym: [UInt8] = [0, 0, 0]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 19)
        f[0] = 0xF2
        f[5] = UInt8(mode) | UInt8((value >> 16) & 3) << 6
        f[6] = UInt8(range) | (ovl ? 0x80 : 0) | (neg ? 0x40 : 0) | r6
        f[7] = UInt8((value >> 8) & 0xFF); f[8] = UInt8(value & 0xFF)
        f[9] = sub[0]; f[10] = sub[1]; f[11] = sub[2]; f[12] = sub[3]
        f[13] = s13; f[14] = s14
        f[15] = sym[0]; f[16] = sym[1]; f[17] = sym[2]
        f[18] = Frames.xor(f[0..<18])
        return f
    }

    func testVoltsDecimalPointFromTheRange() {
        let r = Display.decode(frame(mode: 1, range: 0, value: 12345, neg: true))
        XCTAssertEqual(r.text, "-1.2345"); XCTAssertEqual(r.unit, "V"); XCTAssertEqual(r.value, -1.2345)
        XCTAssertEqual(Display.decode(frame(mode: 1, range: 3, value: 2301)).text, "230.1")
    }

    func testOhmsAndCapacitancePrefixes() {
        let r = Display.decode(frame(mode: 9, range: 4, value: 47012))
        XCTAssertEqual(r.text, "470.12"); XCTAssertEqual(r.unit, "kΩ")
        XCTAssertEqual(Display.decode(frame(mode: 12, range: 5, value: 12)).text, "12")
        XCTAssertEqual(Display.decode(frame(mode: 12, range: 5, value: 12)).unit, "µF")
    }

    func testEighteenBitMagnitudeThroughREL() {
        let r = Display.decode(frame(mode: 3, range: 0, value: 123456))
        XCTAssertEqual(r.text, "123.45"); XCTAssertEqual(r.dp, 2)
    }

    func testOverloadAndUnknownRange() {
        let o = Display.decode(frame(mode: 9, range: 6, value: 0, ovl: true))
        XCTAssertTrue(o.overload); XCTAssertNil(o.value); XCTAssertEqual(o.text, "OFL"); XCTAssertEqual(o.unit, "MΩ")
        let u = Display.decode(frame(mode: 3, range: 5, value: 1))
        XCTAssertEqual(u.text, "-----"); XCTAssertNil(u.value)
    }

    func testTemperatureUnitFromTheRangeByte() {
        let r = Display.decode(frame(mode: 5, range: 0, value: 235, r6: 0x20))
        XCTAssertEqual(r.text, "23.5"); XCTAssertEqual(r.unit, "°C")
    }

    func testSubDisplays() {
        let freq = Display.decode(frame(mode: 2, range: 1, value: 0, sub: [6, 0x22, 0x00, 0x7B]))
        XCTAssertEqual([freq.subLabel, freq.subText, freq.subUnit], ["freq", "1.23", "kHz"])
        let temp = Display.decode(frame(mode: 1, range: 0, value: 0, sub: [100, 0x40, 0x00, 0x2D]))
        XCTAssertEqual([temp.subText, temp.subUnit], ["-4.5", "°C"])
        let beep = Display.decode(frame(mode: 10, range: 0, value: 0, sub: [0xBB, 0, 0, 42]))
        XCTAssertEqual([beep.subLabel, beep.subText, beep.subUnit], ["threshold", "UP 42", "Ω"])
        let time = Display.decode(frame(mode: 1, range: 0, value: 0, sub: [140, 0, 9, 5]))
        XCTAssertEqual(time.subText, "09:05")
    }

    func testSymbolsAndBar() {
        let r = Display.decode(frame(mode: 1, range: 0, value: 0, s13: 0x06, s14: 40,
                                     sym: [0x34, 0x12, 0x18]))
        XCTAssertEqual(r.symbols, ["AC", "AUTO", "PEAK", "REL", "MIN", "HOLD", "MEM"])
        XCTAssertEqual(r.bar, Bargraph(shown: true, lit: 26, negative: true, label: "500"))
        XCTAssertFalse(Display.decode(frame(mode: 1, range: 0, value: 0)).bar.shown)
    }
}

final class SessionTests: XCTestCase {
    func testStatsRestartOnScaleChange() {
        var s = Session()
        let f = { (v: Int, rng: Int) -> Reading in
            var b = [UInt8](repeating: 0, count: 19); b[0] = 0xF2; b[5] = 1; b[6] = UInt8(rng); b[7] = UInt8(v >> 8); b[8] = UInt8(v & 0xFF); b[13] = 0x10
            b[18] = Frames.xor(b[0..<18]); return Display.decode(b)
        }
        for v in [10000, 20000, 30000] { s.add(f(v, 0)) }
        XCTAssertEqual(s.stats.n, 3); XCTAssertEqual(s.stats.mean!, 2.0, accuracy: 1e-12); XCTAssertEqual(s.stats.sd!, 1.0, accuracy: 1e-12)
        s.add(f(5000, 1))
        XCTAssertEqual(s.stats.n, 1); XCTAssertEqual(s.stats.min, 5.0)
        XCTAssertEqual(s.trendInScale().compactMap(\.value), [5.0])
    }

    func testCSVRow() {
        var b = [UInt8](repeating: 0, count: 19); b[0] = 0xF2; b[5] = 1; b[7] = 0x30; b[8] = 0x39; b[13] = 0x10
        b[18] = Frames.xor(b[0..<18])
        let r = Display.decode(b, at: Date(timeIntervalSince1970: 1_762_900_000.25))
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Session.csvRow(r, format: .comma, timeZone: utc), "2025-11-11 22:26:40.250,DCV,1.2345,V,1.2345,,,\r\n")
        XCTAssertEqual(Session.csvRow(r, format: .semicolon, timeZone: utc), "2025-11-11 22:26:40,250;DCV;1,2345;V;1,2345;;;\r\n")
        XCTAssertEqual(Session.recordingName(r.t, timeZone: utc), "121GW_2025-11-11_22-26-40.csv")
    }
}
