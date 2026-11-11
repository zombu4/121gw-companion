// Firmware and bootloader updates (companion app.py _check_release, _run_update, _update_firmware,
// _update_bootloader; FEATURES.md 2.10, 2.10a, 2.11 stage 4).
//
// With the two-part bootloader the meter restarts into its update mode (key code 0x91) and receives the file over
// Bluetooth, then restarts into it.  With EEVblog's bootloader the firmware goes to the SD card on the page Ld-bt and
// the key sequence installs it; the first install of the two-part bootloader also goes through Ld-bt (F-1.03 on).

import Foundation
import Meter121Kit

enum UpdatePhase: String {
    case none, available, downloading, waitingLd = "waiting_ld", restarting, sending, done, error
}

struct UpdateState {
    var phase = UpdatePhase.none
    var firmware: Releases.Entry?           // a newer firmware than the meter has
    var bootloader: Releases.Entry?         // a newer (or first) bootloader
    var latest: [Releases.Kind: [Releases.Entry]] = [:]
    var checked: Date?
    var checkError = ""
    var what = ""                           // "firmware" / "bootloader" of the running step
    var step = ""                           // label of the running step
    var done = 0, total = 0
    var message = ""
    var later = false
    var lastTransfer = ""
    var appNewer: Releases.Entry?
    var active: Bool { [.downloading, .waitingLd, .restarting, .sending].contains(phase) }
}

/// A chosen release or a checked file of the user's own.
struct InstallPick {
    var kind: Releases.Kind
    var text: String
    var tag: String?
    var data: [UInt8]?
    var expect: String?                     // the version the meter reports afterwards (nil: a file of the user's own)
}

extension MeterController {
    static let releaseRecheck = 1800.0
    static let restartPoll = 1.0

    var meterFacts: MeterFacts {
        MeterFacts(connected: connected, firmware: versionNumber, bootloader: bootloader, inUpdateMode: mode == .bootloader)
    }

    // MARK: release check

    func fetchReleases() async throws -> [Releases.Kind: [Releases.Entry]] {
        var all: [Any] = []
        for page in 1...5 {
            var req = URLRequest(url: URL(string: Releases.api + "&page=\(page)")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("121GW-iOS", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let part = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw TransferError("the release list could not be read")
            }
            all += part
            if part.count < 100 { break }
        }
        return try Releases.parse(JSONSerialization.data(withJSONObject: all))
    }

    /// Offer what is newer than the meter has (a meter in update mode is offered the newest firmware; a meter with
    /// EEVblog's bootloader the two-part bootloader).
    func checkRelease(force: Bool = false) async {
        guard ![.downloading, .waitingLd, .restarting, .sending].contains(update.phase) else { return }
        if prefs.updateCheck == .never && !force {
            update.checkError = "update check off (App settings)"
            return
        }
        if prefs.updateCheck == .daily && !force, let c = update.checked, Date().timeIntervalSince(c) < 86_400 { return }
        do {
            let r = try await fetchReleases()
            update.latest = r
            var fw: Releases.Entry?, bl: Releases.Entry?
            if let newest = r[.firmware]?.first, mode == .bootloader || (versionNumber.map { newest.version > $0 } ?? false) {
                fw = newest
            }
            if let newest = r[.bootloader]?.first {
                if let have = Version(meterText: bootloader, prefix: "B"), newest.version > have { bl = newest }
                if bootloader == "EEV" { bl = newest }
            }
            if let a = r[.app]?.first, let mine = Version(tag: "ios-v" + AppInfo.version, prefix: "ios-v"), a.version > mine {
                update.appNewer = a
            }
            update.firmware = fw
            update.bootloader = bl
            update.checked = Date()
            update.checkError = ""
            if update.phase == .none || update.phase == .available { update.phase = fw != nil || bl != nil ? .available : .none }
        } catch {
            update.checkError = "releases: \(error.localizedDescription)"
        }
    }

    // MARK: downloads (kept in the cache folder, so a second meter needs no download)

    private static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("releases", isDirectory: true)
    }

    private func zipChecked(_ tag: String, _ zname: String) async throws -> ZipReader {
        let (blob, r1) = try await URLSession.shared.data(from: Releases.asset(tag, zname))
        let (sum, r2) = try await URLSession.shared.data(from: Releases.asset(tag, zname + ".sha256"))
        guard (r1 as? HTTPURLResponse)?.statusCode == 200, (r2 as? HTTPURLResponse)?.statusCode == 200 else {
            throw TransferError("\(zname) could not be downloaded")
        }
        let want = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map { $0.lowercased() } ?? ""
        let got = SHA256.hex([UInt8](blob))
        guard got == want.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TransferError("\(zname): SHA-256 \(got) does not match the published \(want)")
        }
        return try ZipReader([UInt8](blob), inflate: Zip.inflate)
    }

    func firmwareImage(_ tag: String) async throws -> [UInt8] {
        let path = Self.cache.appendingPathComponent(tag).appendingPathComponent("EEVBlog.bin")
        if let d = try? [UInt8](Data(contentsOf: path)), Releases.checkImage(d) == nil { return d }
        let zname = "firmware-\(tag).zip"
        let z = try await zipChecked(tag, zname)
        guard z.names.contains("2_fast/EEVBlog.bin") else { throw TransferError("\(zname) has no 2_fast/EEVBlog.bin") }
        let data = try z.read("2_fast/EEVBlog.bin")
        if let bad = Releases.checkImage(data) { throw TransferError("\(zname): not a 121GW application image: \(bad)") }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data).write(to: path, options: .atomic)
        return data
    }

    func bootloaderFiles(_ tag: String) async throws -> (install: [UInt8], image: [UInt8]) {
        let folder = Self.cache.appendingPathComponent(tag)
        let pi = folder.appendingPathComponent("install.bin"), pb = folder.appendingPathComponent("blimage.bin")
        if let i = try? [UInt8](Data(contentsOf: pi)), let b = try? [UInt8](Data(contentsOf: pb)),
           Releases.checkInstall(i) == nil, !b.isEmpty { return (i, b) }
        let zname = "bootloader-\(tag).zip"
        let z = try await zipChecked(tag, zname)
        guard z.names.contains("install.bin"), z.names.contains("blimage.bin") else {
            throw TransferError("\(zname) lacks install.bin or blimage.bin")
        }
        let inst = try z.read("install.bin"), boot = try z.read("blimage.bin")
        if let bad = Releases.checkInstall(inst) { throw TransferError("\(zname): \(bad)") }
        guard inst.count >= 0x500 + boot.count, Array(inst[0x500..<(0x500 + boot.count)]) == boot else {
            throw TransferError("\(zname): install.bin and blimage.bin hold different bootloaders")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(inst).write(to: pi, options: .atomic)
        try Data(boot).write(to: pb, options: .atomic)
        return (inst, boot)
    }

    // MARK: running an update

    /// what: "firmware", "bootloader" or "both" of the newest releases, or the picks of the user (METER view).
    func runUpdate(_ what: String, picks: [Releases.Kind: InstallPick] = [:]) {
        guard !update.active && !updateActive else { return }     // one update at a time, also after a quick double tap
        updateCancelled = false
        updateActive = true
        update.phase = .downloading
        update.message = ""
        Task {
            event("update \(what) started" + (picks.isEmpty ? "" : " (chosen by the user)"))
            do {
                var steps = what == "both" ? ["firmware", "bootloader"] : [what]
                if what == "both" && bootloader != "EEV" { steps.reverse() }   // two-part: the bootloader first
                for s in steps {
                    if s == "firmware" { try await updateFirmware(picks[.firmware]) } else { try await updateBootloader(picks[.bootloader]) }
                }
                update.phase = .done
                update.step = ""
                event("update done")
            } catch {
                update.phase = .error
                update.message = error.localizedDescription
                event("update stopped: \(error.localizedDescription)")
            }
            updateActive = false
            updateSender = nil
            if update.phase == .done { await afterUpdate() }
        }
    }

    func cancelUpdate() {
        updateCancelled = true
        updateSender?.cancelled = true
    }

    private func updateFirmware(_ pick: InstallPick?) async throws {
        let p: InstallPick
        if let pick { p = pick } else {
            guard let fw = update.firmware else { return }
            p = InstallPick(kind: .firmware, text: fw.text, tag: fw.tag, data: nil, expect: fw.text)
        }
        update.phase = .downloading
        update.what = "firmware"
        update.step = p.text
        update.message = p.data == nil ? "getting \(p.text) from the releases" : "checking \(p.text)"
        let data: [UInt8]
        if let d = p.data { data = d } else { data = try await firmwareImage(p.tag!) }
        if mode == .bootloader || Version(meterText: bootloader, prefix: "B") != nil {
            if data.count > Releases.blFirmwareMax {
                throw TransferError("\(p.text) has \(data.count) bytes; the two-part bootloader takes firmware images of at most \(Releases.blFirmwareMax) bytes")
            }
            try await enterUpdateMode()
            try await bootSend(data, kind: Transfer.kindFirmware, version: nil, text: p.text)
            let expect = p.expect
            try await waitRestart({ self.mode == .firmware && (expect == nil || self.version == expect) },
                                  failure: "the meter did not come back with \(p.text)", what: "it starts \(p.text)")
            update.message = ""
        } else {
            let s = Sender { [link] in try await link.send($0) }
            updateSender = s
            try await waitLd(s)
            let deflate: Transfer.Deflate? = has(.packed) ? Zip.deflate : nil
            try await sendTracked(s, text: p.text, total: data.count) { _ = try await s.run(data, deflate: deflate) }
            update.message = "\(p.text) is on the SD card. To install: switch the meter off, hold HOLD and MEM while switching it on, then press SETUP."
        }
    }

    private func updateBootloader(_ pick: InstallPick?) async throws {
        let p: InstallPick
        if let pick { p = pick } else {
            guard let bl = update.bootloader else { return }
            p = InstallPick(kind: .bootloader, text: bl.text, tag: bl.tag, data: nil, expect: bl.text)
        }
        update.phase = .downloading
        update.what = "bootloader"
        update.step = p.text
        update.message = p.data == nil ? "getting \(p.text) from the releases" : "checking \(p.text)"
        var first: [UInt8]?
        let boot: [UInt8]
        if let d = p.data {
            boot = d
        } else {
            let files = try await bootloaderFiles(p.tag!)
            first = files.install
            boot = files.image
        }
        if bootloader == "EEV" {
            guard let first else { throw TransferError("a bootloader file of your own is not sent to EEVblog's bootloader") }
            guard let v = versionNumber, v >= Version(1, 0, 3) else {
                throw TransferError("the first bootloader install needs firmware F-1.03 or newer on the meter: update the firmware first")
            }
            let s = Sender { [link] in try await link.send($0) }
            updateSender = s
            try await waitLd(s)
            let deflate: Transfer.Deflate? = has(.packed) ? Zip.deflate : nil
            do {
                try await sendTracked(s, text: p.text, total: first.count) {
                    _ = try await s.run(first, kind: Transfer.kindInstall, deflate: deflate)
                }
            } catch let e as TransferError where e.message.contains("no answer to packet") {
                // F-1.03 as first built could restart before its END answer: the meter's own report decides
            }
        } else {
            try await enterUpdateMode()
            let ver = p.expect != nil ? Version(meterText: p.text, prefix: "B") : nil
            try await bootSend(boot, kind: Transfer.kindBootloader, version: ver.map { $0.a << 16 | $0.b << 8 | $0.c }, text: p.text)
        }
        let expect = p.expect
        try await waitRestart({ expect != nil ? self.bootloader == expect : self.mode == .firmware },
                              failure: expect != nil ? "the meter did not report bootloader \(p.text)" : "the meter did not restart into its firmware",
                              what: "it starts bootloader \(p.text)")
        update.message = ""
    }

    private func waitLd(_ s: Sender) async throws {
        update.phase = .waitingLd
        update.message = ""
        while true {
            if updateCancelled { throw TransferError("cancelled") }
            if try await s.probe() { return }
            await sleep(1.0)
        }
    }

    /// Restart the meter into the bootloader's update mode (key code 0x91) unless it is there already.
    private func enterUpdateMode() async throws {
        if mode == .bootloader { return }
        stopLink2()
        try? await link.send(Frames.updateModeRequest)       // the confirmation can be lost with the link
        link.quickRetryWanted = true                         // the bootloader waits only 30 s for the first packet
        defer { link.quickRetryWanted = false }
        try await waitRestart({ self.mode == .bootloader }, failure: "the meter did not come back in its update mode",
                              what: "into its update mode", poll: { await self.probeKeptLink() })
    }

    /// The old BLE112 module keeps its connection through the meter's reset: ask the bootloader on the same link.
    private func probeKeptLink() async {
        let s = Sender { [link] in try await link.send($0) }
        updateSender = s
        defer { updateSender = nil }
        if let v = try? await s.bootVersion() {
            event("update-mode probe on the kept link: bootloader \(v)")
            setBootloaderMode(v)
        }
    }

    /// After an update over a link that survived the restarts: ask the version on the same connection.
    private func versionKeptLink() async {
        await askVersionOnce()
    }

    /// The meter restarts: wait for the link to drop and come back (the link reconnects by itself), then for ready().
    private func waitRestart(_ ready: @escaping () -> Bool, failure: String, what: String, timeout: Double = 90,
                             poll: (() async -> Void)? = nil) async throws {
        update.phase = .restarting
        update.message = what
        let end = Date().addingTimeInterval(timeout)
        var nextPoll = Date().addingTimeInterval(Self.restartPoll)
        let pollKept = poll ?? { await self.versionKeptLink() }
        while Date() < end && connected && !ready() {
            if Date() >= nextPoll {
                await pollKept()
                nextPoll = Date().addingTimeInterval(Self.restartPoll)
            }
            await sleep(0.2)
        }
        while Date() < end && !ready() {
            if updateCancelled { throw TransferError("cancelled") }
            await sleep(0.2)
        }
        if !ready() { throw TransferError(failure) }
    }

    private func bootSend(_ data: [UInt8], kind: UInt8, version: Int?, text: String) async throws {
        let s = Sender { [link] in try await link.send($0) }
        updateSender = s
        let packed = Version(meterText: bootloader, prefix: "B").map { $0 >= Version.packedBootloader } ?? false
        try await sendTracked(s, text: text, total: data.count) {
            try await s.runBoot(data, kind: kind, version: version, deflate: packed ? Zip.deflate : nil)
        }
    }

    private func sendTracked(_ s: Sender, text: String, total: Int, _ job: @escaping () async throws -> Void) async throws {
        update.phase = .sending
        update.done = 0
        update.total = total
        update.step = text
        let dropped0 = link.reassembler.dropped
        let progress = Task { @MainActor in
            while !Task.isCancelled {
                self.update.done = s.done
                self.update.total = s.total > 0 ? s.total : total
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { progress.cancel() }
        var failure: Error?
        do { try await job() } catch { failure = error }
        let dropped = max(0, link.reassembler.dropped - dropped0)
        update.lastTransfer = "\(text): " + s.stats.text(dropped: dropped)
        event("transfer of \(update.lastTransfer)")
        if let failure { throw failure }
        update.done = s.total
    }

    private func afterUpdate() async {
        if connected && mode == .firmware {
            await checkRelease(force: true)
        }
    }

    // MARK: a chosen version or a file of the user's own

    /// A file of the user's own, checked as the meter checks a release image; nil and the reason on refusal.
    func stageFile(name: String, data: [UInt8]) -> (InstallPick?, String?) {
        if Releases.checkImage(data) == nil {
            return (InstallPick(kind: .firmware, text: name, tag: nil, data: data, expect: nil), nil)
        }
        if Releases.checkBootloaderImage(data) == nil {
            return (InstallPick(kind: .bootloader, text: name, tag: nil, data: data, expect: nil), nil)
        }
        return (nil, "not a firmware image (\(Releases.checkImage(data)!)) and not a two-part bootloader image (\(Releases.checkBootloaderImage(data)!))")
    }

    func plan(for pick: InstallPick) -> InstallPlan {
        if pick.data != nil {
            return InstallPlan.make(kind: pick.kind, meter: meterFacts, customName: pick.text, customSize: pick.data!.count)
        }
        let entry = update.latest[pick.kind]?.first { $0.tag == pick.tag }
        return InstallPlan.make(kind: pick.kind, meter: meterFacts, release: entry, newest: update.latest[pick.kind]?.first?.version)
    }
}
