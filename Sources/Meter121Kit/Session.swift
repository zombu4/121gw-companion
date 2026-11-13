// Readings of a session: statistics, trend history and the CSV rows of a recording (companion record.py).
//
// Only readings with a numeric value enter the statistics and the trend (an overload or a blank is a gap in the
// trace); every reading goes into the recording.  The statistics restart when the mode, the unit or the range changes.

import Foundation

public struct RunningStats: Equatable, Sendable {
    public private(set) var key: String?
    public private(set) var n = 0
    public private(set) var min: Double?
    public private(set) var max: Double?
    private var mean_ = 0.0, m2 = 0.0

    public init() {}

    public mutating func reset(_ key: String?) {
        self = RunningStats()
        self.key = key
    }

    public mutating func add(_ key: String, _ v: Double) {
        if key != self.key { reset(key) }
        n += 1
        min = Swift.min(min ?? v, v)
        max = Swift.max(max ?? v, v)
        let d = v - mean_                                   // Welford
        mean_ += d / Double(n)
        m2 += d * (v - mean_)
    }

    public var mean: Double? { n > 0 ? mean_ : nil }
    public var sd: Double? { n > 1 ? (m2 / Double(n - 1)).squareRoot() : nil }
}

public struct TrendPoint: Equatable, Sendable {
    public var t: Date
    public var value: Double?
    public var key: String
}

public enum CSVFormat: String, CaseIterable, Sendable {
    case comma, semicolon                               // ", and ." or "; and ," (countries with a decimal comma)
    public var separator: String { self == .comma ? "," : ";" }
    public var decimal: String { self == .comma ? "." : "," }
}

public struct Session: Sendable {
    public static let trendPoints = 6000                // 10 minutes at 10 readings a second, 5 at 20
    public private(set) var stats = RunningStats()
    public private(set) var trend: [TrendPoint] = []
    public private(set) var last: Reading?
    public private(set) var statsDP: Int?
    public private(set) var frames = 0

    public init() {}

    public mutating func add(_ r: Reading) {
        frames += 1
        last = r
        if let v = r.value {
            stats.add(r.scaleKey, v)
            statsDP = r.dp
        }
        trend.append(TrendPoint(t: r.t, value: r.value, key: r.scaleKey))
        if trend.count > Self.trendPoints + 500 { trend.removeFirst(trend.count - Self.trendPoints) }
    }

    public mutating func resetStats() { stats.reset(stats.key) }

    /// The trend in the scale of the statistics (points of another mode/unit/range are gaps).
    public func trendInScale() -> [TrendPoint] {
        trend.suffix(Self.trendPoints).map { p in
            TrendPoint(t: p.t, value: p.key == stats.key ? p.value : nil, key: p.key)
        }
    }

    // MARK: CSV

    public static let csvHeader = ["time", "mode", "display", "unit", "value", "sub display", "sub unit", "symbols"]

    static func csvField(_ s: String, _ sep: String) -> String {
        if s.contains(sep) || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Python repr() of a float, as the companion writes the value column ("1.2345", "-0.5", "12.0").
    static func pyRepr(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e16 { return String(format: "%.1f", v) }
        return "\(v)"
    }

    public static func csvLine(_ fields: [String], format: CSVFormat) -> String {
        fields.map { csvField($0, format.separator) }.joined(separator: format.separator) + "\r\n"
    }

    public static func csvRow(_ r: Reading, format: CSVFormat, timeZone: TimeZone = .current) -> String {
        csvLine(csvFields(r, format: format, timeZone: timeZone), format: format)
    }

    /// The header of a recording with voice notes: the columns of csvHeader and "note".
    public static let csvHeaderNotes = csvHeader + ["note"]

    /// A row of a recording with voice notes: the reading and its note, or (reading nil) the time and the note alone.
    public static func csvRow(_ row: NoteRow, format: CSVFormat, timeZone: TimeZone = .current) -> String {
        let fields = row.reading.map { csvFields($0, format: format, timeZone: timeZone) }
            ?? [csvTime(row.time, format: format, timeZone: timeZone)] + Array(repeating: "", count: csvHeader.count - 1)
        return csvLine(fields + [row.note], format: format)
    }

    static func csvTime(_ t: Date, format: CSVFormat, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ms = Int((t.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1000)
        return f.string(from: t) + format.decimal + String(format: "%03d", ms)
    }

    static func csvFields(_ r: Reading, format: CSVFormat, timeZone: TimeZone) -> [String] {
        let d = format.decimal
        func num(_ s: String) -> String { d == "." ? s : s.replacingOccurrences(of: ".", with: d) }
        return [csvTime(r.t, format: format, timeZone: timeZone), r.modeName, num(r.text), r.unit,
                r.value.map { num(pyRepr($0)) } ?? "", num(r.subText), r.subUnit, r.symbols.joined(separator: " ")]
    }

    public static func recordingName(_ start: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "'121GW_'yyyy-MM-dd'_'HH-mm-ss'.csv'"
        return f.string(from: start)
    }
}
