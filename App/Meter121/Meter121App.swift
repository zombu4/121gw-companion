// 121GW for iPhone: the companion of the open firmware (branch companion) as a native iOS app.

import SwiftUI

@main
struct Meter121App: App {
    @StateObject private var meter = MeterController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(meter)
                .environmentObject(meter.link)
                .preferredColorScheme(meter.prefs.theme == .dark ? .dark : meter.prefs.theme == .light ? .light : nil)
                .tint(Bench.yellow)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var meter: MeterController
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LiveView().tabItem { Label("Live", systemImage: "gauge.with.dots.needle.33percent") }.tag(0)
            ScopeView().tabItem { Label("Scope", systemImage: "waveform.path.ecg") }.tag(1)
            LogView().tabItem { Label("Log", systemImage: "record.circle") }.tag(2)
            CardView().tabItem { Label("Card", systemImage: "sdcard") }.tag(3)
            NavigationStack {
                MeterInfoView().toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Meter", systemImage: "cpu") }.tag(4)
        }
        .overlay {
            if meter.offline && meter.prefs.offlineWindow { OfflineOverlay() }
        }
    }
}

/// "Your meter is offline" after a minute without a connection (companion OFFLINE_AFTER).
struct OfflineOverlay: View {
    @EnvironmentObject var meter: MeterController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption("Meter offline")
            Text("Your meter is offline").font(.title3.weight(.semibold))
            Text("No connection for a minute. Is the meter on, with Bluetooth on (long PEAK), and no other app connected to it? The app keeps looking.")
                .font(.callout).foregroundStyle(Bench.dim(scheme))
            HStack {
                Button("Keep looking") { meter.connect() }.benchButton(accent: true)
                Button("Stop") { Task { await meter.disconnect() } }.benchButton()
            }
        }
        .padding(20)
        .background(Bench.panel(scheme))
        .overlay(Rectangle().stroke(Bench.hairline(scheme)))
        .padding(24)
    }
}

/// The header of every page: the page name, the link state, connect / disconnect.
struct ConnectBar: View {
    @EnvironmentObject var meter: MeterController
    @EnvironmentObject var link: MeterLink
    @Environment(\.colorScheme) private var scheme
    let title: String
    @State private var picking = false

    var stateColor: Color {
        switch link.state {
        case .connected: meter.stale && !meter.desk ? Bench.yellow.opacity(0.5) : Bench.yellow
        case .scanning, .connecting: Bench.dim(scheme)
        case .lost: Bench.bad
        case .idle: Bench.hairline(scheme)
        }
    }

    var stateText: String {
        switch link.state {
        case .connected:
            var t = link.deviceName ?? "121GW"
            if let v = meter.version { t += " · \(v)" }
            if meter.desk { t += " · page Ld" }
            if meter.mode == .bootloader { t += " · update mode" }
            return t
        case .idle: return link.detail.isEmpty ? "not connected" : link.detail
        default: return link.detail.isEmpty ? link.state.rawValue : link.detail
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.system(size: 13, weight: .bold)).tracking(1.6)
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(stateText).font(.system(size: 12)).foregroundStyle(Bench.dim(scheme)).lineLimit(2)
                }
            }
            Spacer()
            if link.state == .idle {
                Button("Connect") { meter.connect() }.benchButton(accent: true)
                    .contextMenu {
                        Button("Choose a meter…") { picking = true }
                    }
            } else {
                Button(link.state == .connected ? "Disconnect" : "Stop") { Task { await meter.disconnect() } }.benchButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Bench.panel(scheme))
        .sheet(isPresented: $picking) { MeterPicker() }
    }
}

/// The meters heard in the last search; one tap connects to it (and it is searched first next time).
struct MeterPicker: View {
    @EnvironmentObject var meter: MeterController
    @EnvironmentObject var link: MeterLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Meters heard") {
                    if link.found.isEmpty { Text("Searching…").foregroundStyle(.secondary) }
                    ForEach(link.found) { m in
                        Button {
                            meter.connect(m.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(m.name)
                                Spacer()
                                Text("\(m.rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Any meter (the first one heard)") {
                        meter.prefs.meter = nil
                        meter.connect(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Choose a meter")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { link.browse() }
        }
    }
}
