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
