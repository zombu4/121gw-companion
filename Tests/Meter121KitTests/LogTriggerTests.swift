// The logging trigger of a recording (LogTrigger.swift, issue 40): the meter's rules for interval, on change and on limit
// verdict applied to the readings, and voice mode, which keeps only the rows that carry a note.

import XCTest
@testable import Meter121Kit

final class LogTriggerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_762_900_000)

    /// A DCV reading (4 places) of `value` counts at t0 + s; `range` 0..3 changes the scale, `ofl` is an overload.
    func reading(_ s: Double, _ value: Int = 10000, range: Int = 0, ofl: Bool = false) -> Reading {
        var f = [UInt8](repeating: 0, count: 19)
        f[0] = 0xF2; f[5] = 1; f[6] = UInt8(range) | (ofl ? 0x80 : 0)
        f[7] = UInt8((value >> 8) & 0xFF); f[8] = UInt8(value & 0xFF); f[13] = 0x10
        f[18] = Frames.xor(f[0..<18])
        return Display.decode(f, at: t0.addingTimeInterval(s))
    }

    /// Readings every 0.5 s from 0 to `until`; the times (s) of the ones that got a row.
    func rows(_ trigger: LogTrigger, until: Double, value: (Double) -> Int = { _ in 10000 },
              verdict: (Double) -> String? = { _ in nil }) -> [Double] {
        var t = trigger
        var out: [Double] = []
        var s = 0.0
        while s <= until {
            if t.accept(reading(s, value(s)), verdict: verdict(s)) { out.append(s) }
            s += 0.5
        }
        return out
    }

    func testEveryReadingKeepsAll() {
        XCTAssertEqual(rows(LogTrigger(mode: .every), until: 2).count, 5)
    }

    func testIntervalRowsAndZeroIsEveryReading() {
        XCTAssertEqual(rows(LogTrigger(mode: .interval, interval: 2), until: 6), [0, 2, 4, 6])
        XCTAssertEqual(rows(LogTrigger(mode: .interval, interval: 0), until: 2).count, 5)
        XCTAssertEqual(rows(LogTrigger(mode: .interval, interval: 1000), until: 2), [0])      // clamped to 999
    }

    func testCountsAreTheDisplayedDigits() {
        XCTAssertEqual(LogTrigger.counts(reading(0, 12345)), 12345)
        XCTAssertNil(LogTrigger.counts(reading(0, ofl: true)))
        var neg = reading(0, 500)
        neg.value = -neg.value!
        XCTAssertEqual(LogTrigger.counts(neg), -500)
    }

    func testChangeIsCheckedOnceASecond() {
        // +50 counts at 0.5 s and back at 1.0 s: the check at 1.0 s sees 2 counts; 20 counts at 2.0 s is a row
        let v: (Double) -> Int = { s in s == 0.5 ? 10050 : s == 1.0 ? 10002 : s >= 2.0 ? 10020 : 10000 }
        XCTAssertEqual(rows(LogTrigger(mode: .change, interval: 0, threshold: 10), until: 3, value: v), [0, 2])
        // the threshold itself counts (10 counts is a change, 9 is not)
        XCTAssertEqual(rows(LogTrigger(mode: .change, interval: 0, threshold: 10), until: 2, value: { $0 >= 1 ? 10010 : 10000 }), [0, 1])
        XCTAssertEqual(rows(LogTrigger(mode: .change, interval: 0, threshold: 10), until: 2, value: { $0 >= 1 ? 10009 : 10000 }), [0])
    }

    func testChangeIsAgainstTheLastRowNotTheLastReading() {
        // 4 counts a second: 4, 8 stay below 10, the third second (12 counts from the row) writes
        XCTAssertEqual(rows(LogTrigger(mode: .change, interval: 0, threshold: 10), until: 4, value: { 10000 + Int($0) * 4 }), [0, 3])
    }

    func testChangeWithAnIntervalAlsoWritesEveryInterval() {
        XCTAssertEqual(rows(LogTrigger(mode: .change, interval: 3, threshold: 10), until: 6), [0, 3, 6])
        XCTAssertEqual(rows(LogTrigger(mode: .change, interval: 0, threshold: 10), until: 6), [0])
    }

    func testScaleChangeIsAChange() {
        var t = LogTrigger(mode: .change, interval: 0, threshold: 200)
        XCTAssertTrue(t.accept(reading(0, 1000)))
        XCTAssertFalse(t.accept(reading(0.5, 1000)))
        XCTAssertFalse(t.accept(reading(1.0, 1001)))                          // 1 count
        XCTAssertTrue(t.accept(reading(2.0, 1001, range: 1)))                 // same digits, another range
    }

    func testOverloadAndBlankAreChanges() {
        var t = LogTrigger(mode: .change, interval: 0, threshold: 200)
        XCTAssertTrue(t.accept(reading(0, 1000)))
        XCTAssertTrue(t.accept(reading(1.0, ofl: true)))                      // number -> OFL
        XCTAssertFalse(t.accept(reading(2.0, ofl: true)))                     // OFL -> OFL
        XCTAssertTrue(t.accept(reading(3.0, 1000)))                           // OFL -> number
    }

    func testLimitVerdictChangesAndIntervalWhileOutside() {
        let verdict: (Double) -> String? = { s in s < 1 ? "PASS" : s < 3.5 ? "HI" : "PASS" }
        XCTAssertEqual(rows(LogTrigger(mode: .limit, interval: 0), until: 6, verdict: verdict), [0, 1, 3.5])
        // every 2 s while HI (row at 1.0, again at 3.0), none while PASS
        XCTAssertEqual(rows(LogTrigger(mode: .limit, interval: 2), until: 6, verdict: verdict), [0, 1, 3, 3.5])
    }

    func testNoLimitMeansTheFirstReadingAndTheInterval() {                   // as the meter's tr-Lt without a test
        XCTAssertEqual(rows(LogTrigger(mode: .limit, interval: 0), until: 5), [0])
        XCTAssertEqual(rows(LogTrigger(mode: .limit, interval: 2), until: 5), [0, 2, 4])
    }

    func testVoiceKeepsOnlyRowsWithANote() {
        var t = LogTrigger(mode: .voice)
        XCTAssertTrue(t.accept(reading(0)))                                   // every reading goes to the placer
        let p = NotePlacer(hold: 8)                                           // "too late" comes after its rows
        var out: [NoteRow] = []
        var s = 0.0
        while s <= 20 {
            out += p.add(reading(s))
            if s == 5 { out += p.add(NotePhrase(start: t0.addingTimeInterval(3.2), text: "probe on TP3")) }
            if s == 20 { out += p.add(NotePhrase(start: t0.addingTimeInterval(1), text: "too late")) }    // its rows are out
            s += 0.5
        }
        out += p.finish()
        let kept = out.filter(LogTrigger.keepsVoiceRow)
        XCTAssertEqual(out.count, 42)                                         // 41 readings and the late phrase's row
        XCTAssertEqual(kept.map { $0.note }, ["probe on TP3", "too late"])
        XCTAssertEqual(kept[0].reading?.t, t0.addingTimeInterval(3))          // the row of the reading nearest to 3.2 s
        XCTAssertNil(kept[1].reading)                                         // 19 s late, its reading out of memory: time and note
    }

    func testTheWideSettingsAnswerCarriesTheLoggingInterval() async throws {
        let m = FakeMeter()
        m.raw[0x018] = 600
        let r = try await SettingsClient(client: m.client).read()
        XCTAssertEqual(r.interval, 600)
        XCTAssertEqual(r.items.first { $0.code == "Ch" }?.value, 10)
        XCTAssertFalse(r.items.contains { $0.id == 0x018 })                   // no row for it
        let m1 = FakeMeter()                                                  // a one-byte answer holds no 0..999 interval
        m1.raw[0x018] = 200
        let old = try await SettingsClient(client: m1.client, userCont: false).read()
        XCTAssertNil(old.interval)
    }
}
