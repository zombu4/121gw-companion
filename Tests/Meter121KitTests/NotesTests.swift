// Voice notes (Notes.swift): a phrase lands in the reading row nearest to where it began; rows wait `hold` seconds
// for their phrases; a late phrase, or one with no reading near it, gets a row of its own; the CSV gets a note column.

import XCTest
@testable import Meter121Kit

final class NotesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_762_900_000)
    let utc = TimeZone(identifier: "UTC")!

    /// A DCV reading of 1.2345 V at t0 + s.
    func reading(_ s: Double) -> Reading {
        var b = [UInt8](repeating: 0, count: 19); b[0] = 0xF2; b[5] = 1; b[7] = 0x30; b[8] = 0x39; b[13] = 0x10
        b[18] = Frames.xor(b[0..<18])
        return Display.decode(b, at: t0.addingTimeInterval(s))
    }

    func phrase(_ s: Double, _ text: String) -> NotePhrase { NotePhrase(start: t0.addingTimeInterval(s), text: text) }

    /// Readings every 0.5 s from 0 to `until`, the phrases given after their reading at `after`; all rows out.
    func run(until: Double, phrases: [(after: Double, NotePhrase)], hold: TimeInterval = 8) -> [NoteRow] {
        let p = NotePlacer(hold: hold)
        var out: [NoteRow] = []
        var s = 0.0
        while s <= until {
            out += p.add(reading(s))
            for (after, ph) in phrases where after == s { out += p.add(ph) }
            s += 0.5
        }
        return out + p.finish()
    }

    func notes(_ rows: [NoteRow]) -> [(Double, Bool, String)] {
        rows.filter { !$0.note.isEmpty }.map { ($0.time.timeIntervalSince(t0), $0.reading != nil, $0.note) }
    }

    func testPhraseLandsInTheNearestRow() {
        // spoken at 3.2 s, recognised 2 s later: the row of 3.0 s (nearer than 3.5 s) carries it
        let rows = run(until: 20, phrases: [(5.0, phrase(3.2, "probe on TP3"))])
        XCTAssertEqual(rows.count, 41)                                  // every reading once, no extra row
        let n = notes(rows)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].0, 3.0, accuracy: 1e-9)
        XCTAssertTrue(n[0].1)
        XCTAssertEqual(n[0].2, "probe on TP3")
        XCTAssertEqual(rows.map { $0.time }, rows.map { $0.time }.sorted())
    }

    func testRowsAreHeldUntilTheirPhrasesCanArrive() {
        let p = NotePlacer(hold: 8)
        var out: [NoteRow] = []
        for s in stride(from: 0.0, through: 7.5, by: 0.5) { out += p.add(reading(s)) }
        XCTAssertEqual(out.count, 0)                                    // nothing older than 8 s yet
        out += p.add(reading(8.5))
        XCTAssertEqual(out.count, 1)                                    // the row of 0.0 s
        XCTAssertEqual(out[0].time, t0)
    }

    func testTwoPhrasesInOneRowAreJoinedInSpokenOrder() {
        // spoken at 3.9 s and 4.1 s, recognised the other way round, both nearest the row of 4.0 s
        let rows = run(until: 20, phrases: [(6.0, phrase(4.1, "said second")), (6.0, phrase(3.9, "said first"))])
        let n = notes(rows)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].0, 4.0, accuracy: 1e-9)
        XCTAssertEqual(n[0].2, "said first / said second")
    }

    func testPhrasesPlacedTogetherKeepSpokenOrder() {
        // both arrive in the same step and are placed in the same release
        let p = NotePlacer(hold: 8)
        var out: [NoteRow] = []
        for s in stride(from: 0.0, through: 3.0, by: 0.5) { out += p.add(reading(s)) }
        out += p.add(phrase(2.1, "B"))
        out += p.add(phrase(1.9, "A"))
        out += p.finish()
        XCTAssertEqual(notes(out).map { $0.2 }, ["A / B"])
    }

    func testLatePhraseGetsItsOwnRow() {
        // spoken at 1.0 s but recognised only at 15 s: the row of 1.0 s is written already
        let rows = run(until: 20, phrases: [(15.0, phrase(1.0, "late one"))])
        XCTAssertEqual(rows.count, 42)                                  // 41 readings + the note alone
        let n = notes(rows)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].0, 1.0, accuracy: 1e-9)
        XCTAssertFalse(n[0].1)
    }

    func testPhraseFarFromEveryReadingGetsItsOwnRow() {
        // readings stop at 5 s (meter off), a phrase at 12 s: no reading within 2 s
        let p = NotePlacer(hold: 8)
        var out: [NoteRow] = []
        for s in stride(from: 0.0, through: 5.0, by: 0.5) { out += p.add(reading(s)) }
        out += p.add(phrase(12, "meter switched off"))
        out += p.finish()
        let n = notes(out)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].0, 12.0, accuracy: 1e-9)
        XCTAssertFalse(n[0].1)
        XCTAssertEqual(out.last?.note, "meter switched off")            // in time order: after the last reading
    }

    func testEmptyPhrasesAreDropped() {
        let rows = run(until: 10, phrases: [(4.0, phrase(2.0, "   ")), (4.0, phrase(2.0, ""))])
        XCTAssertEqual(rows.count, 21)
        XCTAssertTrue(notes(rows).isEmpty)
    }

    func testPhrasesBeforeTheFirstReading() {
        let p = NotePlacer(hold: 8)
        XCTAssertEqual(p.add(phrase(0.2, "start")), [])
        var out: [NoteRow] = []
        for s in stride(from: 0.0, through: 12.0, by: 0.5) { out += p.add(reading(s)) }
        out += p.finish()
        let n = notes(out)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].0, 0.0, accuracy: 1e-9)
        XCTAssertTrue(n[0].1)
    }

    func testCSVWithNotes() {
        XCTAssertEqual(Session.csvLine(Session.csvHeaderNotes, format: .comma),
                       "time,mode,display,unit,value,sub display,sub unit,symbols,note\r\n")
        let r = reading(0.25)
        XCTAssertEqual(Session.csvRow(NoteRow(time: r.t, reading: r, note: "TP3, 5 V"), format: .comma, timeZone: utc),
                       "2025-11-11 22:26:40.250,DCV,1.2345,V,1.2345,,,,\"TP3, 5 V\"\r\n")
        XCTAssertEqual(Session.csvRow(NoteRow(time: r.t, reading: r, note: ""), format: .semicolon, timeZone: utc),
                       "2025-11-11 22:26:40,250;DCV;1,2345;V;1,2345;;;;\r\n")
        XCTAssertEqual(Session.csvRow(NoteRow(time: t0.addingTimeInterval(1.5), reading: nil, note: "alone"), format: .comma, timeZone: utc),
                       "2025-11-11 22:26:41.500,,,,,,,,alone\r\n")
        XCTAssertEqual(Session.csvRow(r, format: .comma, timeZone: utc), "2025-11-11 22:26:40.250,DCV,1.2345,V,1.2345,,,\r\n")
    }
}
