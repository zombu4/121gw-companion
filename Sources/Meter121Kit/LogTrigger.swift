// Which readings go into the CSV rows of a recording (GitHub issue 40 of the iPhone app).  The meter's own logging
// trigger (settings tr, In, Ch; USER_GUIDE "Logging trigger") drives the log on the SD card; this applies the same rules
// on the iPhone to the readings it receives, and adds one that only the iPhone has: a row when a sentence is spoken.
//
//   every reading   a row for every reading (the behaviour before the trigger existed)
//   interval        a row every `interval` seconds (0: every reading)
//   on change       a row when the displayed digits changed by at least `threshold` counts since the last row, checked once
//                   a second; a change of mode, unit, range or clamp ratio, or between a number and OFL / blank counts as
//                   a change; with an interval above 0 also a row every interval
//   on limit        a row when the limit verdict (PASS / HI / LO, Derived.swift) changes; with an interval above 0 also a
//                   row every interval while the reading is outside the limits (HI or LO) or no limit is set (as the
//                   meter's tr-Lt without a test, firmware log/trigger.s log_trig_interval)
//   on voice        a row only where a sentence is placed (Notes.swift): all readings go to the NotePlacer, and the rows it
//                   hands out without a note are dropped (keepsVoiceRow); needs voice notes
// The first reading of a recording is always written (not in voice mode).  Only the CSV rows follow the trigger; the live
// display, the statistics and the trend get every reading.

import Foundation

public enum LogTriggerMode: String, CaseIterable, Codable, Sendable {
    case every, interval, change, limit, voice

    public var label: String {
        switch self {
        case .every: "every reading"
        case .interval: "interval"
        case .change: "on change"
        case .limit: "on limit verdict"
        case .voice: "on voice"
        }
    }
}

public struct LogTrigger: Sendable {
    public static let intervalRange = 0...999                    // seconds, as the meter's In
    public static let thresholdRange = 1...255                   // counts, as the meter's Ch
    public static let defaultInterval = 1, defaultThreshold = 10 // when the meter's values are not known
    public static let checkPeriod: TimeInterval = 1              // the meter looks for a change once a second

    public let mode: LogTriggerMode
    public let interval: Int
    public let threshold: Int
    private var lastRow: Date?                                   // time and reading of the last row written
    private var lastReading: Reading?
    private var lastCheck: Date?                                 // the last once-a-second change check
    private var lastVerdict: String?                             // verdict of the reading before

    public init(mode: LogTriggerMode = .every, interval: Int = defaultInterval, threshold: Int = defaultThreshold) {
        self.mode = mode
        self.interval = min(max(interval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
        self.threshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }

    /// The displayed digits as an integer, sign included (1.2345 V with 4 places: 12345); nil on OFL or blank.
    public static func counts(_ r: Reading) -> Int? {
        r.value.map { Int(($0 * pow(10, Double(r.dp ?? 0))).rounded()) }
    }

    /// Whether `r` differs from the reading of the last row by `threshold` counts, or by kind.
    static func changed(_ last: Reading, _ r: Reading, _ threshold: Int) -> Bool {
        if last.scaleKey != r.scaleKey { return true }
        switch (counts(last), counts(r)) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) >= threshold
        default: return true                                     // a number against OFL / blank
        }
    }

    /// The next reading, in time order, with its limit verdict (nil without a limit); true when it gets a row.
    public mutating func accept(_ r: Reading, verdict: String? = nil) -> Bool {
        if mode == .every || mode == .voice { return true }
        let before = lastVerdict
        lastVerdict = verdict
        guard let at = lastRow, let last = lastReading else {   // the first reading of the recording
            lastCheck = r.t
            return write(r)
        }
        let due = interval > 0 && r.t.timeIntervalSince(at) >= Double(interval)
        switch mode {
        case .interval:
            return interval == 0 || due ? write(r) : false
        case .change:
            var hit = due
            if r.t.timeIntervalSince(lastCheck ?? r.t) >= Self.checkPeriod {
                lastCheck = r.t
                if Self.changed(last, r, threshold) { hit = true }
            }
            return hit ? write(r) : false
        case .limit:
            let outside = verdict != "PASS"                      // HI, LO, or no limit set (nil): interval rows
            return verdict != before || (due && outside) ? write(r) : false
        case .every, .voice:
            return true
        }
    }

    private mutating func write(_ r: Reading) -> Bool {
        lastRow = r.t
        lastReading = r
        return true
    }

    /// Voice mode: a row that came out of the NotePlacer is written when it carries a note (a reading without a note is
    /// dropped; a note alone, from a late phrase, is kept).
    public static func keepsVoiceRow(_ row: NoteRow) -> Bool { !row.note.isEmpty }
}
