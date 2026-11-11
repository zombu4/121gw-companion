// SETTINGS: this app's own settings (the meter's SETUP settings are on the meter): CSV format, colours, time server
// and clock on connect, extended diagnosis, the offline window, reset.

import Meter121Kit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var meter: MeterController
    @State private var server = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Recordings") {
                Picker("CSV format", selection: $meter.prefs.csvFormat) {
                    Text(", and decimal point").tag("comma")
                    Text("; and decimal comma").tag("semicolon")
                }
                Text("Recordings are kept in the Files app under On My iPhone › 121GW.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Colours") {
                Picker("Colours", selection: $meter.prefs.theme) {
                    Text("System").tag(Theme.system)
                    Text("Dark").tag(Theme.dark)
                    Text("Light").tag(Theme.light)
                }
                .pickerStyle(.segmented)
            }
            Section("Meter clock") {
                TextField("Time server", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { save() }
                Toggle("Set the clock after every connection", isOn: $meter.prefs.clockOnConnect)
            }
            Section("Firmware updates") {
                Picker("Check for updates", selection: $meter.prefs.updateCheck) {
                    ForEach(UpdateCheck.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Diagnosis") {
                Toggle("Extended diagnosis", isOn: $meter.prefs.extendedDiagnosis)
                Text("With firmware F-1.15 or newer the meter counts its link errors; the diagnosis report shows them. Applies from the next connection.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Show \"meter offline\" after a minute", isOn: $meter.prefs.offlineWindow)
            }
            Section {
                Button("Reset all settings", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("App settings")
        .onAppear { server = meter.prefs.ntpServer }
        .onDisappear { save() }
        .confirmationDialog("Reset all settings of this app?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                meter.prefs = Preferences()
                server = meter.prefs.ntpServer
            }
        }
    }

    func save() {
        let s = server.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { meter.prefs.ntpServer = s } else { server = meter.prefs.ntpServer }
    }
}
