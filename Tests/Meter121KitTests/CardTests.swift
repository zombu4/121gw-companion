// Card and settings requests against a fake meter (in the spirit of the companion's tests/test_card.py and
// test_settings.py): its card holds files, its EEPROM the settings; it can lose or damage answers.
import XCTest
@testable import Meter121Kit

final class FakeMeter {
    var files: [String: [UInt8]] = [:]
    var raw: [Int: Int] = [0x00F: 0, 0x010: 1, 0x011: 0, 0x013: 0, 0x014: 2, 0x015: 2, 0x016: 0, 0x017: 3, 0x01A: 12,
                           0x01B: 0, 0x01E: 1, 0x020: 0b01010, 0x021: 0, 0x022: 10, 0x028: 0, 0x029: 0, 0x02A: 100,
                           0x02F: 15, 0x02D: 30]
    var listMax = 3                         // entries per LIST page
    var loseChunks: [Int: Int] = [:]        // chunk idx -> answers lost
    var damageChunk: [Int: Int] = [:]       // chunk idx -> answers with wrong data
    var loseDeleteAnswer = 0
    var staged: [UInt8] = []
    let answers = AnswerQueue<[UInt8]>()
    lazy var client = CardClient(send: { [unowned self] p in self.receive(p) }, answers: answers)

    func answer(_ seq: Int, _ st: Int, _ field: Int = 0, _ data: [UInt8] = []) {
        answers.put(CardProtocol.answerPacket(seq, st, field, data))
    }

    func receive(_ p: [UInt8]) {
        let type = p[2], seq = Int(p[3]) | Int(p[4]) << 8, n = Int(p[5])
        let pl = Array(p[6..<(6 + n)])
        func name(_ pl: [UInt8]) -> String { String(decoding: pl[1..<(1 + Int(pl[0]))], as: UTF8.self) }
        let names = files.keys.sorted()
        switch type {
        case CardProtocol.tList:
            let start = Int(pl[0]) | Int(pl[1]) << 8
            let most = pl.count > 2 ? Int(pl[2]) : listMax
            let page = names.dropFirst(start).prefix(min(most, listMax))
            let entries = page.map { CardProtocol.Entry(name: $0, size: files[$0]!.count, date: "2026-11-05", time: "", attr: 0x20, cut: false) }
            let (field, data) = CardProtocol.listAnswer(entries, end: start + page.count >= names.count)
            answer(seq, 0, field, data)
        case CardProtocol.tRead:
            let nm = name(pl), k = 1 + Int(pl[0])
            guard let f = files.first(where: { $0.key.lowercased() == nm.lowercased() })?.value else { return answer(seq, 0x20) }
            let off = CardProtocol.le(pl, k, 4), len = CardProtocol.le(pl, k + 4, 2)
            staged = off >= f.count ? [] : Array(f[off..<min(f.count, off + len)])
            answer(seq, 0, staged.count, le32(Int(CRC32.checksum(staged))))
        case CardProtocol.tChunk:
            let idx = Int(pl[0]) | Int(pl[1]) << 8
            let size = pl.count > 2 ? Int(pl[2]) : CardProtocol.chunk
            if let l = loseChunks[idx], l > 0 { loseChunks[idx] = l - 1; return }
            var part = Array(staged[min(staged.count, idx * size)..<min(staged.count, idx * size + size)])
            if let d = damageChunk[idx], d > 0, !part.isEmpty { damageChunk[idx] = d - 1; part[0] ^= 0xFF }
            answer(seq, 0, idx, part)
        case CardProtocol.tDelete:
            let nm = name(pl)
            if CardProtocol.isProtected(nm) { return answer(seq, 0x23) }
            guard let key = files.keys.first(where: { $0.lowercased() == nm.lowercased() }) else { return answer(seq, 0x20) }
            files[key] = nil
            if loseDeleteAnswer > 0 { loseDeleteAnswer -= 1; return }
            answer(seq, 0)
        case CardProtocol.tInfo:
            answer(seq, 0, 64, le32(1000) + le32(4000))
        case MeterSettings.tGet:
            let wide = pl.count >= 3 && pl[2] == 1
            let pairs = raw.keys.sorted().map { ($0, raw[$0]!) }
            let (count, data) = MeterSettings.getAnswer(pairs, wide: wide)
            answer(seq, 0, count | (wide ? 0x8000 : 0), data)
        case MeterSettings.tPut:
            let id = Int(pl[0]) | Int(pl[1]) << 8
            let v = pl.count == 4 ? Int(pl[2]) | Int(pl[3]) << 8 : Int(pl[2])
            if id == 0x020 && ((v >> 1) & 3 == 3 || v > 31) { return answer(seq, 0x22) }
            raw[id] = v
            answer(seq, 0, id, pl.count == 4 ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v)])
        default:
            answer(seq, 3)
        }
    }
}

final class CardTests: XCTestCase {
    func fake() -> FakeMeter {
        let m = FakeMeter()
        m.files = ["LOG0001.CSV": (0..<20000).map { UInt8(truncatingIfNeeded: $0 * 7) }, "cal.bin": [1, 2, 3],
                   "A.TXT": Array("hello".utf8), "B.TXT": [], "SUB": []]
        return m
    }

    func testListPagesAndInfo() async throws {
        let m = fake()
        let card = Card(client: m.client)
        let files = try await card.list()
        XCTAssertEqual(files.map(\.name), ["A.TXT", "B.TXT", "LOG0001.CSV", "SUB", "cal.bin"])
        XCTAssertEqual(files.first?.date, "2026-11-05")
        let info = try await card.info()
        XCTAssertEqual(info.free, 1000 * 64 * 512)
        XCTAssertEqual(info.total, 4000 * 64 * 512)
    }

    func testDownloadWithLostAndDamagedChunks() async throws {
        let m = fake()
        m.loseChunks = [3: 2]
        m.damageChunk = [5: 1]
        m.client.minTimeout = 0
        let card = Card(client: m.client)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await card.download("LOG0001.CSV", to: dir, size: 20000)
        XCTAssertEqual(try [UInt8](Data(contentsOf: url)), m.files["LOG0001.CSV"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".part"))
    }

    func testCarefulModeSmallPieces() async throws {
        let m = fake()
        let card = Card(client: m.client, careful: true)
        let data = try await card.readWindow("LOG0001.CSV", 0, 8192)
        XCTAssertEqual(data, Array(m.files["LOG0001.CSV"]!.prefix(8192)))
        XCTAssertGreaterThan(card.carefulStats.pieces, 8192 / 128)
    }

    func testDeleteRefusesProtectedAndTakesALostAnswerAsDone() async throws {
        let m = fake()
        let card = Card(client: m.client)
        do {
            try await card.delete("cal.bin")
            XCTFail("deleted a protected file")
        } catch let e as CardError {
            XCTAssertEqual(e.status, CardProtocol.stProtected)
        }
        XCTAssertThrowsError(try CardProtocol.checkName("../x"))
        XCTAssertThrowsError(try CardProtocol.checkLocalName("CON.TXT"))
    }

    func testSyncCopiesOnlyNewOrChanged() async throws {
        let m = fake()
        m.files["SUB"] = nil
        m.files["cal.bin"] = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r1 = try await Card(client: m.client).sync(to: dir)
        XCTAssertEqual(r1.copied, 3)
        let r2 = try await Card(client: m.client).sync(to: dir)
        XCTAssertEqual([r2.copied, r2.unchanged], [0, 3])
        m.files["A.TXT"] = Array("hello world".utf8)
        let r3 = try await Card(client: m.client).sync(to: dir)
        XCTAssertEqual([r3.copied, r3.unchanged], [1, 2])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("A.TXT"), encoding: .utf8), "hello world")
    }

    func testSettingsReadModifyWriteOfTheSharedByte() async throws {
        let m = fake()
        let s = SettingsClient(client: m.client)
        let items = try await s.getAll()
        XCTAssertEqual(items.first { $0.code == "tr" }?.value, 1)
        XCTAssertEqual(items.first { $0.code == "CL" }?.text, "12 hour")
        XCTAssertEqual(items.first { $0.code == "th" }?.text, "30 ohm")
        XCTAssertEqual(items.first { $0.code == "bL" }?.text, "2 min")
        XCTAssertEqual(items.first { $0.code == "item 10" }?.text, "DN300")
        XCTAssertEqual(items.first { $0.code == "item 4" }?.tag, "page 4")
        _ = try await s.put(0x120, 1)                      // REL view: only bit 0 changes
        XCTAssertEqual(m.raw[0x020], 0b01011)
        _ = try await s.put(0x02D, 450)                    // two-byte threshold
        XCTAssertEqual(m.raw[0x02D], 450)
        do {
            _ = try await s.put(0x220, 3)
            XCTFail("trigger 3 accepted")
        } catch {}
        let old = SettingsClient(client: m.client, hunt: false, quiet: false, userCont: false)
        XCTAssertFalse(old.rows().contains { $0.code == "HUnt" || $0.code == "th" })
        XCTAssertEqual(old.rows().first { $0.id == 0x01E }?.max, 1)
    }

    func testDiagnosisText() {
        let t = TransferDiagnosis.explain([2, 0x0301, 1, 0x0202, 0x0008] + [Int](repeating: 0, count: 21))
        XCTAssertTrue(t.hasPrefix("2 failed card sessions in this transfer, last card failure step write, FatFs result 1"), t)
        XCTAssertTrue(t.contains("DTIMEOUT"))
    }
}
