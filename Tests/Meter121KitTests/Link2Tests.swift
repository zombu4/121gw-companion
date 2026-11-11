// Ported from the companion's tests/test_frames.py (class Link2): blocks built here with a parity from polynomial
// division, independent of the decoder's syndrome check.
import XCTest
@testable import Meter121Kit

enum L2Fixture {
    static func block(_ typ: Int, _ seq: Int, _ payload: [Int]) -> [UInt8] {
        let msg = [typ << 6 | seq] + payload + [Int](repeating: 0, count: 16 - payload.count)
        var r = msg + [0, 0, 0]
        for i in 0..<17 {
            let c = r[i]
            if c != 0 {
                for (j, g) in [7, 14, 8].enumerated() { r[i + j + 1] ^= GF256.mul(g, c) }
            }
        }
        return (msg + Array(r[17...])).map { UInt8($0) }
    }

    static let state7: [Int] = [0x01, 0x02, 0x69, 0x01, 0x0E, 0x40, 0x00]
    static let ident: [Int] = [0x17, 0x81, 0x23, 0x45]
    static let sub0: [UInt8] = [0x01, 0x00, 0xFA]

    static func stateBlock(_ seq: Int, ver: Int = 1, dropped: Int = 0) -> [UInt8] {
        block(3, seq, [ver] + state7 + ident + [5, 0x02, 0x0C, dropped])
    }

    static func f2(_ v: Int, _ bar: Int, sub: [UInt8] = sub0, ovl: Int = 0, bsign: Int = 0) -> [UInt8] {
        let a = abs(v), neg = v < 0
        var f = [UInt8](repeating: 0, count: 19)
        f[0] = 0xF2
        for i in 0..<4 { f[1 + i] = UInt8(ident[i]) }
        f[5] = UInt8(state7[0] | ((a >> 16) & 3) << 6)
        f[6] = UInt8(state7[1] | ovl << 7 | (neg ? 0x40 : 0))
        f[7] = UInt8((a >> 8) & 0xFF); f[8] = UInt8(a & 0xFF)
        f[9] = UInt8(state7[2])
        f[10] = sub[0]; f[11] = sub[1]; f[12] = sub[2]
        f[13] = UInt8(state7[3] | bsign << 2)
        f[14] = UInt8(bar)
        f[15] = UInt8(state7[4]); f[16] = UInt8(state7[5]); f[17] = UInt8(state7[6])
        f[18] = Frames.xor(f[0..<18])
        return f
    }

    /// 1234 with bar 12, +2 and -1 (one byte each), +55 with bar 13.
    static func readBlock(_ seq: Int, ver: Int = 1, age: Int = 3) -> [UInt8] {
        block(1, seq, [ver, age] + sub0.map(Int.init) + [0xE2, 0x00, 0x04, 0xD2, 12, 0x82, 0xBF, 0xC0 + 13, 55])
    }

    static func subBlock(_ seq: Int, ver: Int = 1) -> [UInt8] {
        block(1, seq, [ver, 0] + sub0.map(Int.init) + [0xE2, 0x80, 0x00, 0x05, 0, 0xF0, 0x02, 0x00, 0xFB, 0x80 | (-1 & 0x3F)])
    }

    static let expect = [f2(1234, 12), f2(1236, 12), f2(1235, 12), f2(1290, 13)]
}

final class Link2Tests: XCTestCase {
    typealias F = L2Fixture
    func stream() -> [UInt8] { F.stateBlock(0) + F.readBlock(1) }

    func testReadingsRebuiltAsStatusFrames() {
        let d = Link2Decoder()
        let (plain, got) = d.feed(stream())
        XCTAssertEqual(plain, [])
        XCTAssertEqual(got.map { $0.0 }, F.expect)
        let ages = got.map { $0.1 }
        XCTAssertEqual(ages.last!, 3 * Link2Block.tick, accuracy: 1e-9)
        XCTAssertTrue(zip(ages, ages.dropFirst()).allSatisfy { $0 > $1 })
    }

    func testNegativeValuesAndANewSubDisplay() {
        let d = Link2Decoder()
        let (_, got) = d.feed(F.stateBlock(0) + F.subBlock(1))
        XCTAssertEqual(got.map { $0.0 }, [F.f2(-5, 0), F.f2(-6, 0, sub: [0x02, 0x00, 0xFB])])
    }

    func testEverySingleDamagedByteIsCorrected() {
        let good = F.readBlock(1)
        for pos in 0..<20 {
            for e: UInt8 in [0x01, 0x80, 0xFF, 0x5A] {
                var bad = good
                bad[pos] ^= e
                XCTAssertEqual(Link2Block.correct(bad), good, "\(pos) \(e)")
            }
        }
    }

    func testTwoDamagedBytesNeverAWrongBlock() {
        var rng = SystemRandomNumberGenerator()
        let good = F.readBlock(1)
        for _ in 0..<20000 {
            var bad = good
            let p = Int.random(in: 0..<20, using: &rng)
            var q = Int.random(in: 0..<19, using: &rng)
            if q >= p { q += 1 }
            bad[p] ^= UInt8.random(in: 1...255, using: &rng)
            bad[q] ^= UInt8.random(in: 1...255, using: &rng)
            XCTAssertNil(Link2Block.correct(bad))
        }
    }

    func testPlainBytesBeforeTheLockPassOn() {
        let d = Link2Decoder()
        let echo = Frames.keyFrame(0xA8)
        let (plain, got) = d.feed(echo + stream())
        XCTAssertEqual(plain, echo)
        XCTAssertEqual(got.count, 4)
    }

    func testADamagedBlockAfterTheLockIsCorrectedAndCounted() {
        var s = stream() + F.readBlock(2)
        s[40 + 7] ^= 0x40
        let d = Link2Decoder()
        let (_, got) = d.feed(s)
        XCTAssertEqual(got.map { $0.0 }, F.expect + F.expect)
        XCTAssertEqual(d.stats.corrected, 1)
    }

    func testAReadingOfAnotherVersionIsNeverShown() {
        let d = Link2Decoder()
        let (_, got) = d.feed(F.stateBlock(0, ver: 1) + F.readBlock(1, ver: 2) + F.readBlock(2, ver: 1))
        XCTAssertEqual(got.map { $0.0 }, F.expect)
        XCTAssertEqual(d.stats.stale, 1)
    }

    func testTextBlocksGoToTheReassembler() {
        let echo = Frames.keyFrame(0x90) + [0xF6] + Array("F-1311".utf8)
        let d = Link2Decoder()
        let (plain, _) = d.feed(F.stateBlock(0) + F.block(2, 1, [echo.count] + echo.map(Int.init)))
        XCTAssertEqual(plain, echo)
    }

    func testBackToPlainAfterThreeBadBlocks() {
        let d = Link2Decoder()
        _ = d.feed(stream())
        let plainFrames = Array([[UInt8]](repeating: F.f2(1, 1), count: 4).joined())
        let (plain, got) = d.feed(plainFrames)
        XCTAssertTrue(got.isEmpty)
        XCTAssertFalse(d.locked)
        XCTAssertEqual(plain + d.buffer, plainFrames)
    }

    func testLostBlockCountedFromTheSequence() {
        let d = Link2Decoder()
        _ = d.feed(F.stateBlock(0) + F.readBlock(1) + F.readBlock(3))
        XCTAssertEqual(d.stats.lost, 1)
    }
}
