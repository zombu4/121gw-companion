import XCTest
@testable import Meter121Kit

final class ReleaseTests: XCTestCase {
    func testSHA256() {
        XCTAssertEqual(SHA256.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex([UInt8](repeating: 0x61, count: 1000)).prefix(16), "41edece42d63e8d9")
    }

    func testZipStoredMembers() throws {
        let z = try ZipReader([UInt8](Data(base64Encoded: "UEsDBBQAAAAAAPsua10q38CwAAMAAAADAAASAAAAMl9mYXN0L0VFVkJsb2cuYmluAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/wABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5/gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp+goaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+v8DBwsPExcbHyMnKy8zNzs/Q0dLT1NXW19jZ2tvc3d7f4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/UEsDBBQAAAAAAPsua12GphA2BQAAAAUAAAAKAAAAUkVBRE1FLnR4dGhlbGxvUEsBAhQDFAAAAAAA+y5rXSrfwLAAAwAAAAMAABIAAAAAAAAAAAAAAIABAAAAADJfZmFzdC9FRVZCbG9nLmJpblBLAQIUAxQAAAAAAPsua12GphA2BQAAAAUAAAAKAAAAAAAAAAAAAACAATADAABSRUFETUUudHh0UEsFBgAAAAACAAIAeAAAAF0DAAAAAA==")!), inflate: nil)
        XCTAssertEqual(z.names, ["2_fast/EEVBlog.bin", "README.txt"])
        XCTAssertEqual(try z.read("2_fast/EEVBlog.bin"), Array([[UInt8]](repeating: Array(0...255), count: 3).joined()))
        XCTAssertEqual(try z.read("README.txt"), Array("hello".utf8))
        XCTAssertThrowsError(try z.read("nope"))
    }

    func testParseReleases() throws {
        let json = """
        [{"tag_name": "v1.3.3", "published_at": "2026-11-09T10:00:00Z"},
         {"tag_name": "v1.3.10", "draft": true},
         {"tag_name": "bl-v1.1.5", "published_at": "2026-11-08T10:00:00Z"},
         {"tag_name": "companion-v1.3.4"}, {"tag_name": "ios-v0.2.0"}, {"tag_name": "like205-v1.0.0"},
         {"tag_name": "v1.2.9", "prerelease": true}, {"tag_name": "v1.0.2"}]
        """
        let r = try Releases.parse(Data(json.utf8))
        XCTAssertEqual(r[.firmware]!.map(\.text), ["F-1.33", "F-1.02"])
        XCTAssertEqual(r[.bootloader]!.map(\.text), ["B-1.15"])
        XCTAssertEqual(r[.app]!.map(\.tag), ["ios-v0.2.0"])
        XCTAssertEqual(r[.firmware]!.first?.published, "2026-11-09")
    }

    func image(sp: Int = 0x2000_8000, reset: Int = 0x0800_6101, size: Int = 4096) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: size)
        for i in 0..<4 { d[i] = UInt8((sp >> (8 * i)) & 0xFF); d[4 + i] = UInt8((reset >> (8 * i)) & 0xFF) }
        return d
    }

    func testImageChecks() {
        XCTAssertNil(Releases.checkImage(image()))
        XCTAssertNotNil(Releases.checkImage(image(reset: 0x0800_6100)))
        XCTAssertNotNil(Releases.checkImage(image(sp: 0x1000_0000)))
        XCTAssertNotNil(Releases.checkImage(image(size: 100)))
        var bl = [UInt8](repeating: 0, count: 1024)
        func put(_ i: Int, _ v: Int) { for k in 0..<4 { bl[4 * i + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        put(0, Releases.blStackTop)
        for i in 1..<Releases.blVectors { put(i, Releases.blBase + 0x101) }
        XCTAssertNil(Releases.checkBootloaderImage(bl))
        put(5, 0x0800_6001)
        XCTAssertNotNil(Releases.checkBootloaderImage(bl))
    }

    func testInstallPlans() {
        let fw = Releases.Entry(version: Version(1, 2, 0), tag: "v1.2.0", text: "F-1.20", published: "")
        let meter = MeterFacts(connected: true, firmware: Version(1, 3, 3), bootloader: "B-1.15", inUpdateMode: false)
        let down = InstallPlan.make(kind: .firmware, meter: meter, release: fw)
        XCTAssertEqual(down.relation, .older)
        XCTAssertTrue(down.needsConfirm)
        XCTAssertTrue(down.warnings.contains { $0.contains("F-1.33: the continuity codes") })
        XCTAssertFalse(down.warnings.contains { $0.contains("F-1.19") })
        let up = InstallPlan.make(kind: .firmware, meter: MeterFacts(connected: true, firmware: Version(1, 1, 0), bootloader: "EEV", inUpdateMode: false), release: fw)
        XCTAssertEqual(up.relation, .newer)
        XCTAssertFalse(up.needsConfirm)
        let own = InstallPlan.make(kind: .bootloader, meter: MeterFacts(connected: true, firmware: Version(1, 3, 3), bootloader: "EEV", inUpdateMode: false), customName: "x.bin")
        XCTAssertNotNil(own.refusal)
        let big = InstallPlan.make(kind: .firmware, meter: meter, customName: "big.bin", customSize: Releases.blFirmwareMax + 1)
        XCTAssertNotNil(big.refusal)
        XCTAssertTrue(InstallPlan.make(kind: .firmware, meter: MeterFacts(connected: false, firmware: nil, bootloader: nil, inUpdateMode: false), release: fw).needsMeter)
    }
}
