// The app's own settings (SETTINGS view), stored in UserDefaults; the meter's SETUP settings are on the meter
// (companion app.py PREF_DEFAULTS).

import Foundation
import Meter121Kit

enum Theme: String, CaseIterable, Codable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
}

enum UpdateCheck: String, CaseIterable, Codable, Identifiable {
    case connect, daily, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .connect: "at every connection and every 30 min"
        case .daily: "daily"
        case .never: "never"
        }
    }
}

struct Preferences: Codable, Equatable {
    var ntpServer = MeterClock.defaultServer
    var clockOnConnect = false
    var updateCheck = UpdateCheck.connect
    var csvFormat = "comma"                       // CSVFormat raw value
    var theme = Theme.system
    var extendedDiagnosis = false
    var offlineWindow = true
    var meter: UUID?                              // the meter last connected, searched first
    var linkPaces: [String: Int] = [:]            // link 2 block pace per meter, measured by this app version
    var linkPacesBy = ""
    var derived = DerivedOptions()                // loop range, Pt type, limits of the derived values
    var voiceNotes = false                        // recordings listen and write what is said into a "note" column
    var logTrigger = LogTriggerMode.every         // which readings get a CSV row (LogTrigger.swift)
    var logInterval: Int?                         // the user's interval (s) and threshold (counts); nil: not changed by the user
    var logChange: Int?
    var meterLogInterval: Int?                    // the meter's In and Ch as of the last settings read
    var meterLogChange: Int?

    init() {}

    // every key optional: a setting added in a later version keeps the others of an older file
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Preferences()
        ntpServer = (try? c.decode(String.self, forKey: .ntpServer)) ?? def.ntpServer
        clockOnConnect = (try? c.decode(Bool.self, forKey: .clockOnConnect)) ?? def.clockOnConnect
        updateCheck = (try? c.decode(UpdateCheck.self, forKey: .updateCheck)) ?? def.updateCheck
        csvFormat = (try? c.decode(String.self, forKey: .csvFormat)) ?? def.csvFormat
        theme = (try? c.decode(Theme.self, forKey: .theme)) ?? def.theme
        extendedDiagnosis = (try? c.decode(Bool.self, forKey: .extendedDiagnosis)) ?? def.extendedDiagnosis
        offlineWindow = (try? c.decode(Bool.self, forKey: .offlineWindow)) ?? def.offlineWindow
        meter = try? c.decode(UUID.self, forKey: .meter)
        linkPaces = (try? c.decode([String: Int].self, forKey: .linkPaces)) ?? [:]
        linkPacesBy = (try? c.decode(String.self, forKey: .linkPacesBy)) ?? ""
        derived = (try? c.decode(DerivedOptions.self, forKey: .derived)) ?? DerivedOptions()
        voiceNotes = (try? c.decode(Bool.self, forKey: .voiceNotes)) ?? def.voiceNotes
        logTrigger = (try? c.decode(LogTriggerMode.self, forKey: .logTrigger)) ?? def.logTrigger
        logInterval = try? c.decode(Int.self, forKey: .logInterval)
        logChange = try? c.decode(Int.self, forKey: .logChange)
        meterLogInterval = try? c.decode(Int.self, forKey: .meterLogInterval)
        meterLogChange = try? c.decode(Int.self, forKey: .meterLogChange)
    }

    /// Interval (s) and threshold (counts) of the trigger: the user's value, else the meter's as last read, else the default.
    var triggerInterval: Int { logInterval ?? meterLogInterval ?? LogTrigger.defaultInterval }
    var triggerChange: Int { logChange ?? meterLogChange ?? LogTrigger.defaultThreshold }

    var csv: CSVFormat { CSVFormat(rawValue: csvFormat) ?? .comma }

    static let key = "preferences"

    static func load() -> Preferences {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(Preferences.self, from: d) else { return Preferences() }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
