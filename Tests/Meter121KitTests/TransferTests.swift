// Ported from the companion's tests/test_transfer.py: a fake meter that loses or damages chosen answers.
import XCTest
@testable import Meter121Kit

final class FakeReceiver {
    let sender: Sender
    var lose: [String: Int], damage: [String: Int]
    var expected = 0
    var data: [UInt8] = []
    var start: [UInt8]?
    let boot: Bool

    init(lose: [String: Int] = [:], damage: [String: Int] = [:], boot: Bool = false) {
        self.lose = lose; self.damage = damage; self.boot = boot
        var me: FakeReceiver?
        sender = Sender { pkt in me!.receive(pkt) }
        me = self
        sender.timeoutData = 0.2; sender.timeoutEnd = 0.2; sender.timeoutStart = 0.2
    }

    func answer(_ seq: Int, _ status: Int, _ next: Int) { sender.answers.put(Transfer.Answer(seq: seq, status: status, next: next)) }

    func receive(_ pkt: [UInt8]) {
        let type = pkt[2], seq = Int(pkt[3]) | Int(pkt[4]) << 8, n = Int(pkt[5])
        let key = "\(type)/\(seq)"
        if let d = damage[key], d > 0 { damage[key] = d - 1; answer(seq, 1, expected); return }
        var lost = false
        if let l = lose[key], l > 0 { lose[key] = l - 1; lost = true }
        if type == Transfer.tStart { start = Array(pkt[6..<(6 + n)]) }
        if type == Transfer.tData {
            if seq == expected {
                data += pkt[6..<(6 + n)]
                expected += 1
            } else if seq > expected {
                if !lost { answer(seq, 2, expected) }
                return
            }
        }
        if !lost { answer(seq, 0, expected) }
    }
}

final class TransferTests: XCTestCase {
    let image: [UInt8] = Array([[UInt8]](repeating: Array(0...255), count: 10).joined())
    var n: Int { (image.count + Transfer.maxPayload - 1) / Transfer.maxPayload }

    func testCleanTransfer() async throws {
        let m = FakeReceiver()
        _ = try await m.sender.run(image)
        XCTAssertEqual(m.data, image)
        let st = m.sender.stats
        XCTAssertEqual([st.packets, st.sends, st.timeouts, st.crcWrong, st.resync], [n + 2, n + 2, 0, 0, 0])
        XCTAssertTrue(st.text().contains("none sent again"))
        XCTAssertEqual(m.start, le32(image.count) + le32(Int(CRC32.checksum(image))))
    }

    func testLostAndDamagedAnswersAreCounted() async throws {
        let m = FakeReceiver(lose: ["2/3": 1, "2/7": 1], damage: ["2/5": 1])
        _ = try await m.sender.run(image)
        XCTAssertEqual(m.data, image)
        let st = m.sender.stats
        XCTAssertEqual([st.sends, st.timeouts, st.crcWrong], [n + 2 + 3, 2, 1])
        let text = st.text(dropped: 5)
        for part in ["3 sent again", "2 answers missing", "1 packets arrived damaged", "5 received bytes damaged"] {
            XCTAssertTrue(text.contains(part), text)
        }
    }

    func testBootloaderTransferWithLostAnswers() async throws {
        let m = FakeReceiver(lose: ["2/4": 1, "2/9": 1], boot: true)
        try await m.sender.runBoot(image, kind: Transfer.kindFirmware, version: 0x010105)
        XCTAssertEqual(m.data, image)
        XCTAssertEqual(m.start, le32(image.count) + le32(Int(CRC32.checksum(image))) + [0] + le32(0x010105))
    }

    func testPackedStreamWithoutDeflaterIsRawPieces() {
        let data = [UInt8](repeating: 7, count: 5000)
        let s = Transfer.packStream(data, deflate: nil)
        XCTAssertEqual(s.count, 5000 + 3 * 4)
        XCTAssertEqual(Array(s[0..<4]), [0x00, 0x08, 0x00, 0x88])
        XCTAssertEqual(Array(s[(2 * 2052)..<(2 * 2052 + 4)]), [0x88, 0x03, 0x88, 0x83])   // 904 = 0x388
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testAnswerParse() {
        let f = bftFrame(0x81, 0x0102, [0x00, 0x34, 0x12])
        XCTAssertEqual(Transfer.answer(f), Transfer.Answer(seq: 0x0102, status: 0, next: 0x1234))
        XCTAssertNil(Transfer.answer(bftFrame(0x82, 1, [0, 0, 0])))
        XCTAssertEqual(Transfer.packet(Transfer.tStatus, 3, [3]), bftFrame(Transfer.tStatus, 3, [3]))
    }
}
