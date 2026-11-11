// The app's model of the connected meter (companion app.py, class Companion): what runs on the meter, the readings,
// page Ld (desk mode), the heartbeat, link 2 and its pace, remote keys, time sync and recording.  All on the main actor;
// background loops are tasks that look once a second, as the companion's threads do.

import Foundation
import Meter121Kit
import SwiftUI

enum FirmwareKind: String { case unknown, fast, other }
enum MeterMode: String { case unknown, firmware, bootloader }

struct LogEvent: Identifiable {
    let id = UUID()
    let t: Date
    let text: String
}

struct ClockStatus {
    var last: String?          // "YYYY-MM-DD HH:MM:SS" the meter was set to
    var offset: Double?
    var delay: Double?
    var auto = ""              // result of the clock on connect
}

struct Link2Control {
    var on = false
    var pace = MeterController.paceStart
    var clean = 0
    var window: (Date, Int, Int, Int)?     // (time, lost, blocks, status frames) at the start of the window
}

@MainActor
final class Flag { var done = false }

@MainActor
final class MeterController: ObservableObject {
    // timings (companion app.py)
    static let keyEchoWait = 1.0
    static let versionWait = 2.0
    static let versionRetry = 10.0
    static let versionTries = 3
    static let blAskTries = 3
    static let xdiagTries = 3
    static let xdiagWait = 2.0
    static let deskStale = 4.0
    static let deskProbeTimeout = 1.5
    static let hbSend = 5.0
    static let aliveGap = 8.0
    static let offlineAfter = 60.0
    static let paceTicks = [30, 25, 20, 17, 14, 12, 10, 8, 7]
    static let paceStart = 2
    static let paceWindow = 10.0
    static let paceUpClean = 3
    static let paceDown = 2
    static let staleAfter = 3.0                  // a reading older than this is shown as stale

    let link = MeterLink()

    @Published var prefs = Preferences.load() { didSet { if prefs != oldValue { prefs.save() } } }
    @Published private(set) var session = Session()
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var fwKind = FirmwareKind.unknown
    @Published private(set) var version: String?
    @Published private(set) var bootloader: String?
    @Published private(set) var mode = MeterMode.unknown
    @Published private(set) var desk = false
    @Published private(set) var offline = false
    @Published private(set) var l2c = Link2Control()
    @Published private(set) var clock = ClockStatus()
    @Published private(set) var events: [LogEvent] = []
    @Published private(set) var recording = false
    @Published private(set) var recordingRows = 0
    @Published private(set) var recordingURL: URL?
    @Published private(set) var recordingStart: Date?
    @Published private(set) var statusFrames = 0
    @Published private(set) var framesPerSecond: Double?
    @Published var busyText = ""                 // the operation that holds the link, for the UI
    @Published private(set) var hb = (sent: 0, probes: 0, dead: 0)
    @Published private(set) var derived = DerivedValues()   // REL %, loop %, Pt, limit (Meter121Kit.Derived)
    @Published var card = CardState()            // the SD card page (MeterController+Desk.swift)
    @Published var settings = SettingsState()    // the meter's SETUP settings
    @Published var diag = DiagState()            // the transfer diagnosis
    var cardCancel: (() -> Void)?
    @Published var update = UpdateState()        // firmware and bootloader updates (MeterController+Update.swift)
    var updateSender: Sender?
    var updateCancelled = false
    private var lastReleaseCheck = Date.distantPast

    private let recorder = Recorder()

    // answers the waiting operations look for
    private var keyEcho: [UInt8]?
    private var versionEcho: Date?
    private var versionAnswer: String?
    private var blAnswer: String?
    private var clockEcho: [UInt8]?
    var xdiagFrame: [UInt8]?                     // the last F9 answer (extended diagnosis)
    var mclockFrame: [UInt8]?                    // the last FA answer (clock measurement)
    private var derivedState = Derived()
    private var stFirst: Date?
    private var opsBusy: String?                // the exclusive use of the link by one operation
    private(set) var sender: Sender?            // the page Ld sender of the running operation
    let extAnswers = AnswerQueue<[UInt8]>()     // answers of type 0x82 (card and settings requests)
    private var askTask: Task<Void, Never>?
    private var loops: [Task<Void, Never>] = []
    private var alive = (Date.distantPast, -1)
    private var lostSince: Date?
    private var hbQuiet = false
    var updateActive = false                    // a firmware or bootloader update owns the link (stage 3)

    init() {
        link.onFrame = { [weak self] f, t in self?.frame(f, t) }
        link.onState = { [weak self] s, d in self?.linkState(s, d) }
        loops = [
            every(1.0) { await $0.watchDesk() },
            every(1.0) { await $0.heartbeatStep(Date()) },
            every(1.0) { await $0.paceStep(Date()) },
            every(60.0) { await $0.recheckReleases() },
        ]
    }

    private func every(_ s: Double, _ f: @escaping @MainActor @Sendable (MeterController) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                guard let self else { return }
                await f(self)
            }
        }
    }

    // MARK: derived state

    var reading: Reading? { session.last }
    var connected: Bool { link.state == .connected }
    var versionNumber: Version? { fwKind == .fast ? Version(meterText: version) : nil }
    func has(_ f: Feature) -> Bool { versionNumber?.has(f) ?? false }
    var stale: Bool { lastFrameAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true }

    /// The old BLE112 module (MTU 23) with firmware that knows careful mode (F-1.19 on).
    var carefulWanted: Bool { link.mtu == carefulMTU && has(.careful) }
    var link2Supported: Bool { carefulWanted && has(.link2) }

    var link2Note: String? {
        guard connected, carefulWanted, !link2Supported else { return nil }
        return "this meter's old Bluetooth module damages and loses readings; firmware F-1.31 or newer sends them "
            + "protected and faster (link 2): update the firmware"
    }

    /// Why no card, settings or diagnosis command can start now, or nil.
    var lockReason: String? {
        if !connected { return "not connected to a meter" }
        if updateActive { return "a firmware or bootloader update is running" }
        if mode == .bootloader { return "the meter is in its update mode" }
        if !desk { return "show the SETUP page Ld on the meter first (Bluetooth on, logging off)" }
        if let b = opsBusy { return "the link is busy: \(b)" }
        return nil
    }

    func event(_ text: String) {
        events.append(LogEvent(t: Date(), text: text))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    // MARK: connection

    func connect(_ id: UUID? = nil) {
        hbQuiet = false
        link.connect(id ?? prefs.meter)
    }

    /// Disconnect by the user: the heartbeat stops, the meter's watch is switched off with one 0xFD, then the link
    /// is closed.
    func disconnect() async {
        hbQuiet = true
        if connected {
            let flag = Flag()
            Task { @MainActor in
                try? await self.link.send(Frames.heartbeatOff)
                flag.done = true
            }
            await waitFor(1.0) { flag.done }           // at most 1 s: a dead link must not hold up the disconnect
        }
        link.disconnect()
    }

    private func linkState(_ s: LinkState, _ d: String) {
        event("link \(s.rawValue)" + (d.isEmpty ? "" : ": \(d)"))
        desk = false
        lastFrameAt = nil
        l2c = Link2Control()
        statusFrames = 0
        stFirst = nil
        framesPerSecond = nil
        if s == .connected {
            fwKind = .unknown
            version = nil
            mode = .unknown
            if let id = link.deviceID { prefs.meter = id }
            if [.none, .available, .done, .error].contains(update.phase) {
                update.phase = .none
                update.later = false
                update.message = ""
            }
            askTask?.cancel()
            askTask = Task { await self.askVersion() }
        }
        objectWillChange.send()
    }

    // MARK: frames

    private func frame(_ f: Frame, _ t: Date) {
        switch f.kind {
        case .status:
            let r = Display.decode(f.bytes, at: t)
            session.add(r)
            recorder.add(r)
            derivedState.options = prefs.derived
            derivedState.feed(r)
            derived = derivedState.values()
            if recording { recordingRows = recorder.rows }
            statusFrames += 1
            if stFirst == nil { stFirst = t }
            if let s = stFirst, statusFrames > 10 { framesPerSecond = Double(statusFrames - 1) / max(0.001, t.timeIntervalSince(s)) }
            if desk { event("page Ld left (status frames again)") }
            lastFrameAt = t
            desk = false
        case .version: versionAnswer = Frames.versionText(f.bytes)
        case .blVersion: blAnswer = Frames.blVersionText(f.bytes)
        case .xdiag: xdiagFrame = f.bytes
        case .mclock: mclockFrame = f.bytes
        case .keyEcho:
            keyEcho = f.bytes
            if f.bytes == Frames.versionRequest { versionEcho = t }
        case .clockEcho: clockEcho = f.bytes
        case .bft:
            if f.bytes[2] == 0x82 {
                extAnswers.put(f.bytes)
            } else if let a = Transfer.answer(f.bytes) {
                sender?.answers.put(a)
                updateSender?.answers.put(a)
            }
        }
    }

    // MARK: what runs on the meter

    /// After each connection: the firmware answers the version request with its echo and a version frame (then the
    /// bootloader question); the bootloader's update mode answers only its own status request; nothing at all: the
    /// link was not ready (page Ld shown or an SD access running): ask again later.
    private func askVersion() async {
        var echoOnly = 0
        var ldNoted = false
        while connected && mode == .unknown && !Task.isCancelled {
            if desk {
                if !ldNoted {
                    event("page Ld shown: the version is asked when the meter leaves it")
                    ldNoted = true
                }
                await sleep(1.0)
                continue
            }
            versionEcho = nil
            versionAnswer = nil
            blAnswer = nil
            do { try await link.send(Frames.versionRequest) } catch { break }
            await waitFor(Self.versionWait) { self.versionAnswer != nil }
            event("version question: " + (versionAnswer.map { "answer \($0)" } ?? (versionEcho != nil ? "echo only" : "no answer")))
            if let v = versionAnswer {
                fwKind = .fast
                version = v
                bootloader = await askBootloader()
                mode = .firmware
                await xdiagConnect()
                await link2Connect()
                await releaseCheckNow()
                if prefs.clockOnConnect { await clockOnConnect() }
            } else if versionEcho != nil {
                echoOnly += 1
                if echoOnly < Self.versionTries { continue }
                fwKind = .other
                mode = .firmware
                event("the meter echoed the version question without a version: not the open firmware's fast build")
            } else if let v = await bootProbe() {
                setBootloaderMode(v)
                event("update-mode probe: bootloader \(v)")
                await releaseCheckNow()
            } else {
                event("update-mode probe: no answer")
                await sleep(Self.versionRetry)
            }
        }
    }

    /// One version question (after an update, on a link that survived the restarts).
    func askVersionOnce() async {
        versionAnswer = nil
        do { try await link.send(Frames.versionRequest) } catch { return }
        await waitFor(Self.versionWait) { self.versionAnswer != nil }
        guard let v = versionAnswer else { return }
        event("version question on the kept link: answer \(v)")
        fwKind = .fast
        version = v
        bootloader = await askBootloader()
        mode = .firmware
    }

    func setBootloaderMode(_ v: Version) {
        bootloader = v.bootloaderText
        mode = .bootloader
    }

    func stopLink2() {
        l2c = Link2Control()
        link.link2Expected = false
    }

    private func releaseCheckNow() async {
        lastReleaseCheck = Date()
        await checkRelease()
    }

    /// Every 30 minutes while connected (setting "at every connection").
    private func recheckReleases() async {
        guard connected, mode != .unknown, !update.active, prefs.updateCheck == .connect,
              Date().timeIntervalSince(lastReleaseCheck) >= Self.releaseRecheck else { return }
        await releaseCheckNow()
    }

    private func askBootloader() async -> String? {
        for _ in 0..<Self.blAskTries {
            blAnswer = nil
            do { try await link.send(Frames.blVersionRequest) } catch { return nil }
            await waitFor(Self.versionWait) { self.blAnswer != nil }
            event("bootloader question: \(blAnswer ?? "no answer")")
            if let b = blAnswer { return b }
        }
        return nil
    }

    private func bootProbe() async -> Version? {
        guard opsBusy == nil else { return nil }
        opsBusy = "update-mode probe"
        defer { opsBusy = nil; sender = nil }
        let s = Sender { [link] in try await link.send($0) }
        sender = s
        return try? await s.bootVersion()
    }

    // MARK: exclusive use of the link (companion _ops)

    enum OpsError: LocalizedError {
        case refused(String)
        var errorDescription: String? {
            switch self {
            case let .refused(s): return s
            }
        }
    }

    /// Runs `job` with the link to itself: a page Ld sender and the 0x82 answer queue cleared.  Refused when not
    /// connected, during an update, while another operation runs after `wait`, or (needDesk) without page Ld.
    func ops<T>(_ what: String, needDesk: Bool = true, wait: Double = 0,
                _ job: (Sender) async throws -> T) async throws -> T {
        if !connected { throw OpsError.refused("not connected to a meter") }
        if updateActive && what != "update" { throw OpsError.refused("a firmware or bootloader update is running") }
        if needDesk && !desk { throw OpsError.refused("show the SETUP page Ld on the meter first (Bluetooth on, logging off)") }
        let end = Date().addingTimeInterval(wait)
        while opsBusy != nil {
            if Date() >= end { throw OpsError.refused("the link is busy: \(opsBusy ?? "another operation")") }
            await sleep(0.05)
        }
        if needDesk && !desk { throw OpsError.refused("show the SETUP page Ld on the meter first (Bluetooth on, logging off)") }
        opsBusy = what
        busyText = what
        let s = Sender { [link] in try await link.send($0) }
        sender = s
        extAnswers.clear()
        defer {
            sender = nil
            opsBusy = nil
            busyText = ""
        }
        return try await job(s)
    }

    /// Desk mode: no status frame for deskStale seconds on a connected meter with the transfer -> ask; an answer
    /// means page Ld.  Any status frame ends desk.
    private func watchDesk() async {
        guard connected, !updateActive, mode != .bootloader, fwKind != .other, opsBusy == nil else { return }
        if let t = lastFrameAt, Date().timeIntervalSince(t) < Self.deskStale { return }
        do {
            let was = desk
            let now = try await ops("page check", needDesk: false) { try await $0.probe(timeout: Self.deskProbeTimeout) }
            desk = now
            if now && !was { event("page Ld shown") }
        } catch is OpsError {
            return
        } catch {
            desk = false
        }
    }

    /// Leave page Ld from the phone (keys do not reach the meter there); F-1.17 on.
    func leaveLd() async throws {
        guard has(.leaveLd) else {
            throw OpsError.refused("this firmware (\(version ?? "unknown")) cannot be told to leave the page Ld: press SETUP on the meter")
        }
        try await ops("leave page Ld", wait: 2.5) { try await $0.leave() }
        event("page Ld left by the app (LEAVE request)")
    }

    // MARK: keys

    /// Send a key frame and wait for its echo (several tries); true when echoed.
    func keyWithEcho(_ code: UInt8, tries: Int = MeterController.xdiagTries, wait: Double = MeterController.xdiagWait) async throws -> Bool {
        let f = Frames.keyFrame(code)
        for _ in 0..<tries {
            keyEcho = nil
            try await link.send(f)
            await waitFor(wait) { self.keyEcho == f }
            if keyEcho == f { return true }
        }
        return false
    }

    func press(_ key: MeterKey, long: Bool = false) async throws {
        if !connected { throw OpsError.refused("not connected to a meter") }
        if mode == .bootloader { throw OpsError.refused("the meter is in its update mode: no keys") }
        if desk { throw OpsError.refused("page Ld owns the link: leave it on the meter before using the keys") }
        let ok = try await ops("key", needDesk: false, wait: 2.5) { _ -> Bool in
            if self.desk { throw OpsError.refused("page Ld owns the link: leave it on the meter before using the keys") }
            return try await self.keyWithEcho(key.code(long: long), tries: 1, wait: Self.keyEchoWait)
        }
        if !ok {
            throw OpsError.refused("the meter did not confirm the key (page Ld shown, an SD access running, or the link is not ready); try again")
        }
    }

    // MARK: extended diagnosis (F-1.15 on)

    private func xdiagConnect() async {
        guard prefs.extendedDiagnosis else { return }
        guard has(.extendedDiagnosis) else {
            event("extended diagnosis: not switched on, the meter has \(version ?? "?") (F-1.15 or newer needed)")
            return
        }
        let ok = (try? await ops("extended diagnosis on", needDesk: false, wait: 2.5) { _ in try await self.keyWithEcho(0x93) }) ?? false
        event("extended diagnosis on: " + (ok ? "confirmed" : "no echo"))
    }

    // MARK: link 2 (old BLE112 module, F-1.31 on)

    private var paceKey: String? { link.deviceID?.uuidString }

    private func paceSaved() -> Int? {
        guard prefs.linkPacesBy == AppInfo.version, let k = paceKey, let v = prefs.linkPaces[k],
              v >= 0, v < Self.paceTicks.count else { return nil }
        return v
    }

    private func paceSave(_ idx: Int) {
        guard let k = paceKey else { return }
        if prefs.linkPacesBy != AppInfo.version { prefs.linkPaces = [:] }
        prefs.linkPaces[k] = idx
        prefs.linkPacesBy = AppInfo.version
    }

    static func blocksPerSecond(_ idx: Int) -> Double { 1.0 / (Double(paceTicks[idx]) * Link2Block.tick) }

    private func link2Connect() async {
        guard link2Supported else { return }
        let idx = paceSaved() ?? Self.paceStart
        do {
            let ok = try await ops("link 2", needDesk: false, wait: 2.5) { _ -> Bool in
                if self.desk { throw OpsError.refused("page Ld owns the link") }
                guard try await self.keyWithEcho(0xAA + UInt8(idx)) else { return false }
                self.link.link2Expected = true          // from the 0xA8 echo on the meter sends blocks
                guard try await self.keyWithEcho(0xA8) else {
                    self.link.link2Expected = false
                    return false
                }
                return true
            }
            guard ok else {
                event("link 2: no echo after \(Self.xdiagTries) tries")
                return
            }
        } catch {
            event("link 2: the meter was not told (\(error.localizedDescription))")
            return
        }
        l2c = Link2Control(on: true, pace: idx, clean: 0, window: nil)
        event(String(format: "link 2 on: readings in blocks with repair bytes, %.1f blocks a second", Self.blocksPerSecond(idx)))
    }

    private func paceChange(_ newIdx: Int, _ why: String) async throws {
        let idx = max(0, min(Self.paceTicks.count - 1, newIdx))
        guard idx != l2c.pace else { return }
        let ok = try await ops("link 2 pace", needDesk: false) { _ in try await self.keyWithEcho(0xAA + UInt8(idx)) }
        guard ok else { throw OpsError.refused("the meter did not echo the pace") }
        l2c.pace = idx
        l2c.clean = 0
        paceSave(idx)
        event(String(format: "link 2: %.1f blocks a second (%@)", Self.blocksPerSecond(idx), why))
    }

    private func paceFail(_ why: String) {
        guard l2c.on else { return }
        let idx = max(0, l2c.pace - Self.paceDown)
        l2c.pace = idx
        paceSave(idx)
        event(String(format: "link 2: %@; %.1f blocks a second saved for the next connection", why, Self.blocksPerSecond(idx)))
    }

    /// Every paceWindow seconds (link 2 on): a lost block -> paceDown steps slower; paceUpClean clean windows -> one
    /// step faster; readings but no blocks -> the meter left link 2: asked again.
    private func paceStep(_ now: Date) async {
        guard l2c.on else { return }
        guard connected, !desk, !updateActive, mode == .firmware else {
            l2c.window = nil
            return
        }
        let s = link.link2.stats
        let cur = (now, s.lost, s.blocks, statusFrames)
        guard let w = l2c.window else {
            l2c.window = cur
            return
        }
        guard now.timeIntervalSince(w.0) >= Self.paceWindow else { return }
        l2c.window = cur
        do {
            if s.blocks == w.2 && statusFrames > w.3 {
                let ok = try await ops("link 2", needDesk: false) { _ -> Bool in
                    guard try await self.keyWithEcho(0xAA + UInt8(self.l2c.pace)) else { return false }
                    return try await self.keyWithEcho(0xA8)
                }
                event(ok ? "link 2 set again (the meter had left it)" : "link 2: the meter did not echo")
                return
            }
            let lost = s.lost - w.1
            if lost > 0 {
                try await paceChange(l2c.pace - Self.paceDown, String(format: "%d blocks lost in %.0f s", lost, Self.paceWindow))
                return
            }
            l2c.clean += 1
            if l2c.clean >= Self.paceUpClean && l2c.pace < Self.paceTicks.count - 1 {
                try await paceChange(l2c.pace + 1, String(format: "no block lost for %.0f s", Double(Self.paceUpClean) * Self.paceWindow))
            }
        } catch {
            event("link 2 pace: \(error.localizedDescription)")
        }
    }

    // MARK: heartbeat (IMP-56, F-1.26)

    /// While connected and not on page Ld or in the bootloader: 0xFE when nothing was written for hbSend; when no
    /// byte came from the meter for aliveGap outside page Ld, the version question (3 tries); no answer: the link is
    /// dead, connect again.  While the link is down and wanted: after offlineAfter the meter is offline.
    private func heartbeatStep(_ now: Date) async {
        guard connected else {
            if link.state == .idle || !link.want {
                lostSince = nil
                offline = false
            } else if lostSince == nil {
                lostSince = now
            } else if !offline, let l = lostSince, now.timeIntervalSince(l) >= Self.offlineAfter {
                offline = true
                event(String(format: "the meter is offline: no connection for %.0f s", now.timeIntervalSince(l)))
            }
            return
        }
        lostSince = nil
        offline = false
        if alive.1 != link.rxBytes { alive = (now, link.rxBytes) }
        let quiet = hbQuiet || desk || mode == .bootloader || updateActive
        if !quiet && now.timeIntervalSince(link.lastWrite) >= Self.hbSend {
            if (try? await link.send(Frames.heartbeatOn)) != nil { hb.sent += 1 }
        }
        if quiet || mode != .firmware || now.timeIntervalSince(alive.0) < Self.aliveGap { return }
        let answered: Bool
        do {
            answered = try await ops("alive check", needDesk: false) { _ -> Bool in
                self.hb.probes += 1
                return try await self.keyWithEcho(0x90)
            }
        } catch is OpsError {
            return                                     // the link is busy: next second
        } catch {
            answered = false
        }
        if answered || link.rxBytes != alive.1 {
            alive = (Date(), link.rxBytes)
            return
        }
        hb.dead += 1
        event(String(format: "the meter did not answer for %.0f s (3 questions): connecting again", Date().timeIntervalSince(alive.0)))
        paceFail("the link stalled")
        alive = (Date(), link.rxBytes)
        link.connect(link.deviceID ?? link.address)
    }

    // MARK: clock

    /// Set the meter's clock from NTP: query, wait for the next whole second of the server's time, send the frame for
    /// that second, wait for the echo.
    @discardableResult
    func syncTime(server: String? = nil) async throws -> String {
        let srv = (server ?? prefs.ntpServer).trimmingCharacters(in: .whitespaces)
        if srv.isEmpty { throw OpsError.refused("no NTP server given") }
        if !connected { throw OpsError.refused("not connected to a meter") }
        let a = try await NTPClient.query(srv)
        let target = (a.now.timeIntervalSince1970).rounded(.down) + 1
        let wait = target - (Date().timeIntervalSince1970 + a.offset)
        if wait > 0 { await sleep(wait) }
        let date = Date(timeIntervalSince1970: target)
        let f = MeterClock.clockFrame(date)
        clockEcho = nil
        try await link.send(f)
        await waitFor(2.0) { self.clockEcho == f }
        guard clockEcho == f else { throw OpsError.refused("the meter did not confirm the time (no echo); try again") }
        if srv != prefs.ntpServer { prefs.ntpServer = srv }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = fmt.string(from: date)
        clock.last = text
        clock.offset = a.offset
        clock.delay = a.delay
        event(String(format: "clock set to %@ (phone clock offset %+.3f s, round trip %.3f s)", text, a.offset, a.delay))
        return text
    }

    private func clockOnConnect() async {
        do {
            clock.auto = "set on connect to " + (try await syncTime())
        } catch {
            clock.auto = "not set on connect: \(error.localizedDescription)"
        }
    }

    // MARK: recording

    func startRecording() throws {
        let u = try recorder.begin(format: prefs.csv)
        recording = true
        recordingURL = u
        recordingRows = 0
        recordingStart = recorder.start
        event("recording to \(u.lastPathComponent)")
    }

    func stopRecording() {
        let u = recorder.end()
        recording = false
        if let u { event("recording stopped: \(recorder.rows) rows in \(u.lastPathComponent)") }
    }

    func resetStats() { session.resetStats() }

    // MARK: helpers

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }

    func waitFor(_ s: Double, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end && !cond() { await sleep(0.02) }
    }
}
