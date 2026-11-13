// Voice notes in a recording (GitHub issue 1 of the iPhone app): a spoken phrase goes into the "note" column of the
// reading row nearest to the moment the phrase began.  Speech becomes text a few seconds after it is spoken, so the
// rows are held back for `hold` seconds before they are written; a phrase that arrives later than that, or that has no
// reading within `maxGap` of its start, gets a row of its own (time and note only), so nothing is lost.

import Foundation

/// One recognised phrase: when it began (wall clock) and its text.
public struct NotePhrase: Equatable, Sendable {
    public var start: Date
    public var text: String

    public init(start: Date, text: String) {
        self.start = start
        self.text = text
    }
}

/// A row to write: a reading with the notes placed on it, or a note alone (reading nil) at `time`.
public struct NoteRow: Equatable {
    public var time: Date
    public var reading: Reading?
    public var note: String

    public init(time: Date, reading: Reading?, note: String) {
        self.time = time
        self.reading = reading
        self.note = note
    }
}

public final class NotePlacer {
    public let hold: TimeInterval            // seconds a row waits for the phrases spoken at its time
    public let maxGap: TimeInterval          // a phrase further than this from every held reading gets its own row
    private var held: [NoteRow] = []         // rows not written yet, in time order
    private var phrases: [NotePhrase] = []   // phrases not placed yet
    private var released: Date?              // time of the last row handed out: a phrase before it is late

    public init(hold: TimeInterval = 8, maxGap: TimeInterval = 2) {
        self.hold = hold
        self.maxGap = maxGap
    }

    /// A reading arrived; returns the rows that are now old enough to write, in time order.
    public func add(_ r: Reading) -> [NoteRow] {
        held.append(NoteRow(time: r.t, reading: r, note: ""))
        return release(before: r.t.addingTimeInterval(-hold))
    }

    /// A phrase was recognised; returns a row at once only when the phrase is late (its rows are written already).
    public func add(_ p: NotePhrase) -> [NoteRow] {
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let released, p.start < released {
            return [NoteRow(time: p.start, reading: nil, note: text)]
        }
        phrases.append(NotePhrase(start: p.start, text: text))
        return []
    }

    /// The recording ends: every row and every phrase still waiting.
    public func finish() -> [NoteRow] {
        release(before: .distantFuture)
    }

    /// Places the phrases that began before `cutoff`, then hands out the rows before it.
    private func release(before cutoff: Date) -> [NoteRow] {
        var alone: [NoteRow] = []
        var keep: [NotePhrase] = []
        for p in phrases.sorted(by: { $0.start < $1.start }) {   // spoken order, whatever order they were recognised in
            guard p.start < cutoff else { keep.append(p); continue }
            if let i = nearest(p.start), abs(held[i].time.timeIntervalSince(p.start)) <= maxGap {
                held[i].note = held[i].note.isEmpty ? p.text : held[i].note + " / " + p.text
            } else {
                alone.append(NoteRow(time: p.start, reading: nil, note: p.text))
            }
        }
        phrases = keep
        let n = held.firstIndex { $0.time >= cutoff } ?? held.count
        let out = (Array(held[..<n]) + alone).sorted { $0.time < $1.time }
        held.removeFirst(n)
        if let last = out.last { released = max(released ?? last.time, last.time) }
        return out
    }

    private func nearest(_ t: Date) -> Int? {
        held.indices.min { abs(held[$0].time.timeIntervalSince(t)) < abs(held[$1].time.timeIntervalSince(t)) }
    }
}
