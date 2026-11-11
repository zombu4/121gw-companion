// Page Ld operations of the controller (companion app.py: card_*, settings_*, diag_read): the SD card, the meter's
// SETUP settings and the transfer diagnosis.  Each runs with the link to itself (ops) and needs the page Ld.

import Foundation
import Meter121Kit

struct CardState {
    var files: [CardFile] = []
    var listed = false
    var free: Int?
    var total: Int?
    var op = ""                       // "list", "info", "download", "delete", "sync", "format" while busy
    var progress = 0.0
    var error: String?
    var result = ""
    var lastSync: Date?
    var busy: Bool { !op.isEmpty }
}

struct SettingsState {
    var items: [SettingItem] = []
    var error: String?
}

struct DiagState {
    var values: [Int] = []
    var text = ""
}

extension MeterController {
    static let l2AnswerMax = 243                     // bytes of the largest page Ld answer (8 + 3 + 232)
    static let packedMinVersion = Version(1, 3, 2)

    static var cardFolder: URL { Recorder.folder.appendingPathComponent("card", isDirectory: true) }

    /// Seconds a card or settings request waits at least with link 2 on.
    var l2AnswerWait: Double {
        guard l2c.on else { return 0 }
        let blocks = (Self.l2AnswerMax + Link2Block.textMax - 1) / Link2Block.textMax
        return 2.0 * Double(blocks) * Double(Self.paceTicks[l2c.pace]) * Link2Block.tick + 1.0
    }

    /// Card and settings answers in small pieces: an old BLE112 link without link 2 blocks on page Ld.
    var smallPieces: Bool {
        let ldBlocks = l2c.on && (versionNumber.map { $0 >= Self.packedMinVersion } ?? false)
        return carefulWanted && !ldBlocks
    }

    /// READZ for card reads: true from F-1.32; nil while the version is not known (asked once); false otherwise.
    var packedCard: Bool? {
        if has(.packed) { return true }
        if version == nil && fwKind != .other { return nil }
        return false
    }

    func cardClient() -> CardClient {
        let c = CardClient(send: { [link] in try await link.send($0) }, answers: extAnswers)
        c.minTimeout = l2AnswerWait
        return c
    }

    private func newCard(_ c: CardClient) -> Card {
        Card(client: c, careful: smallPieces, packed: packedCard, inflate: Zip.inflate)
    }

    /// Run a card operation in the background of the page: one at a time, its progress and result in `card`.
    func cardRun(_ op: String, _ job: @escaping @MainActor (Card, CardClient) async throws -> Void) {
        guard !card.busy else { return }
        card.op = op
        card.progress = 0
        card.error = nil
        card.result = ""
        Task {
            do {
                try await ops(op) { _ in
                    let c = self.cardClient()
                    self.cardCancel = { c.cancelled = true }
                    try await job(self.newCard(c), c)
                }
            } catch {
                card.error = error.localizedDescription
                event("card \(op): \(error.localizedDescription)")
            }
            cardCancel = nil
            card.op = ""
        }
    }

    func cardList() {
        cardRun("list") { card, _ in
            let files = try await card.list()
            let info = try await card.info()
            self.card.files = files
            self.card.listed = true
            self.card.free = info.free
            self.card.total = info.total
            self.card.result = "\(files.count) files"
        }
    }

    func cardDownload(_ f: CardFile) {
        cardRun("download") { card, _ in
            let u = try await card.download(f.name, to: Self.cardFolder, size: f.size) { @Sendable done, total in
                Task { @MainActor in self.card.progress = total > 0 ? Double(done) / Double(total) : 1 }
            }
            self.card.result = "saved \(u.lastPathComponent) (Files: 121GW › card)"
            self.event("card download: \(f.name), \(f.size) bytes")
        }
    }

    func cardDelete(_ f: CardFile) {
        cardRun("delete") { card, _ in
            try await card.delete(f.name)
            self.card.files = try await card.list()
            self.card.result = "deleted \(f.name)"
        }
    }

    func cardSync() {
        cardRun("sync") { card, _ in
            let r = try await card.sync(to: Self.cardFolder) { @Sendable done, total in
                Task { @MainActor in self.card.progress = total > 0 ? Double(done) / Double(total) : 1 }
            }
            self.card.lastSync = Date()
            self.card.result = "\(r.copied) copied, \(r.unchanged) unchanged" + (r.skipped.isEmpty ? "" : ", \(r.skipped.count) skipped")
            self.event("card sync: \(self.card.result)")
        }
    }

    /// Format the card as exFAT (F-1.09 on with the two-part bootloader), after the user typed FORMAT.
    func cardFormat(confirm: String) {
        guard confirm == "FORMAT" else {
            card.error = "type FORMAT to format the card"
            return
        }
        cardRun("format") { card, _ in
            try await card.format()
            self.card.files = []
            self.card.result = "the card was formatted"
            self.event("card formatted")
        }
    }

    func cardStop() { cardCancel?() }

    // MARK: settings

    func settingsClient(_ c: CardClient) -> SettingsClient {
        SettingsClient(client: c, hunt: has(.hunt), quiet: has(.quiet), paged: carefulWanted && has(.linkAdapt),
                       userCont: has(.userContinuity))
    }

    func settingsGet() async {
        settings.error = nil
        do {
            settings.items = try await ops("settings") { _ in try await self.settingsClient(self.cardClient()).getAll() }
        } catch {
            settings.error = error.localizedDescription
        }
    }

    func settingsPut(_ id: Int, _ value: Int) async {
        settings.error = nil
        do {
            settings.items = try await ops("settings") { _ in try await self.settingsClient(self.cardClient()).put(id, value) }
            if let i = settings.items.first(where: { $0.id == id }) { event("setting \(i.code) set to \(i.text)") }
        } catch {
            settings.error = error.localizedDescription
        }
    }

    // MARK: diagnosis

    func diagRead() async {
        let n = (versionNumber.map { $0 >= Version(1, 1, 1) } ?? false) ? TransferDiagnosis.count : TransferDiagnosis.baseCount
        do {
            let v = try await ops("diagnosis") { s -> [Int] in
                var out: [Int] = []
                for i in 0..<n { out.append(try await s.statusValue(i)) }
                return out
            }
            diag = DiagState(values: v, text: TransferDiagnosis.explain(v))
        } catch {
            diag = DiagState(values: [], text: error.localizedDescription)
        }
    }
}
