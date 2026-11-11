// Releases of the project on GitHub (companion releases.py) and what may be installed (install.py).
//
// Firmware releases are tagged vA.B.C with firmware-<tag>.zip (2_fast/EEVBlog.bin) and its .sha256; bootloader
// releases bl-vA.B.C with bootloader-<tag>.zip (install.bin for the first install through the firmware, blimage.bin
// for an update through the bootloader); app releases ios-vA.B.C.  The network fetch is the app's (URLSession);
// parsing, the image checks, the zip reader, SHA-256 and the install plan are here.

import Foundation

public enum Releases {
    public static let repo = "zombu4/121GW-Open-Firmware"
    public static let api = "https://api.github.com/repos/\(repo)/releases?per_page=100"
    public static func asset(_ tag: String, _ name: String) -> URL {
        URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(name)")!
    }
    public static func pageURL(_ tag: String) -> URL { URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")! }

    public static let blBase = 0x0800_0400, blMax = 0x5B00, blStackTop = 0x2000_C000, blVectors = 73
    public static let blFirmwareMax = 0x4C000         // largest firmware the two-part bootloader takes

    public enum Kind: String, CaseIterable, Sendable { case firmware, bootloader, app }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var version: Version
        public var tag: String
        public var text: String
        public var published: String
        public var id: String { tag }
    }

    /// The API's release list sorted into kinds, newest first; drafts, pre-releases and other tags left out.
    public static func parse(_ json: Data) throws -> [Kind: [Entry]] {
        guard let list = try JSONSerialization.jsonObject(with: json) as? [Any] else {
            throw TransferError("the release list is not a list")
        }
        var out: [Kind: [Entry]] = [.firmware: [], .bootloader: [], .app: []]
        for case let r as [String: Any] in list {
            if (r["draft"] as? Bool) == true || (r["prerelease"] as? Bool) == true { continue }
            guard let tag = r["tag_name"] as? String else { continue }
            let published = String((r["published_at"] as? String ?? "").prefix(10))
            if let v = Version(tag: tag, prefix: "bl-v") {
                out[.bootloader]!.append(Entry(version: v, tag: tag, text: v.bootloaderText, published: published))
            } else if let v = Version(tag: tag, prefix: "ios-v") {
                out[.app]!.append(Entry(version: v, tag: tag, text: v.description, published: published))
            } else if tag.hasPrefix("v"), let v = Version(tag: tag, prefix: "v") {
                out[.firmware]!.append(Entry(version: v, tag: tag, text: v.firmwareText, published: published))
            }
        }
        for k in out.keys { out[k]!.sort { $0.version > $1.version } }
        return out
    }

    static func u32(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }

    /// The checks the meter makes before it accepts a firmware file (ble/bft.s bft_finish): nil or the reason.
    public static func checkImage(_ d: [UInt8]) -> String? {
        guard d.count >= 0x124 && d.count <= 0x5A000 else { return "size \(d.count) outside 292 .. 368640 bytes" }
        let sp = u32(d, 0), reset = u32(d, 4)
        if !(0x2000_0001...0x2001_4000).contains(sp) { return String(format: "initial stack pointer 0x%08X is not in the RAM", sp) }
        if reset & 1 == 0 || !(0x0800_6000..<0x0806_0000).contains(reset) {
            return String(format: "reset vector 0x%08X is not a Thumb address in 0x08006000 .. 0x0805FFFF", reset)
        }
        return nil
    }

    /// The checks of a two-part bootloader image (blimage.bin, placed at 0x08000400): its vector table.
    public static func checkBootloaderImage(_ d: [UInt8]) -> String? {
        guard d.count >= 4 * blVectors && d.count <= blMax else {
            return "size \(d.count) outside \(4 * blVectors) .. \(blMax) bytes (the vector table alone is \(4 * blVectors))"
        }
        if u32(d, 0) != blStackTop {
            return String(format: "initial stack pointer 0x%08X is not the two-part bootloader's 0x%08X", u32(d, 0), blStackTop)
        }
        for i in 1..<blVectors {
            let w = u32(d, 4 * i)
            if w & 1 == 0 || !(blBase..<(blBase + d.count)).contains(w) {
                return String(format: "vector %d (0x%08X) is not a Thumb address inside the image placed at 0x%08X", i, w, blBase)
            }
        }
        return nil
    }

    /// The checks the firmware makes before a first bootloader install (ble/bft.s bft_install).
    public static func checkInstall(_ d: [UInt8]) -> String? {
        guard d.count >= 0x580 && d.count <= 0x6000 && d.count % 128 == 0 else {
            return "install file of \(d.count) bytes: 0x580 .. 0x6000 in whole half-pages expected"
        }
        let sp = u32(d, 0), reset = u32(d, 4)
        if !(0x2000_0001...0x2000_C000).contains(sp) || reset & 1 == 0 || !(0x0800_0000..<0x0800_0400).contains(reset) {
            return "the starter part has no valid vector table"
        }
        if u32(d, 0x400) != 0x3248_4C42 { return "no bootloader header after the starter" }
        return nil
    }
}

// MARK: SHA-256 (FIPS 180-4), so the kit needs no CryptoKit (Linux tests)

public enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = data
        let bitLen = UInt64(data.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xFF)) }
        var w = [UInt32](repeating: 0, count: 64)
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                w[i] = UInt32(msg[chunk + 4 * i]) << 24 | UInt32(msg[chunk + 4 * i + 1]) << 16
                    | UInt32(msg[chunk + 4 * i + 2]) << 8 | UInt32(msg[chunk + 4 * i + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> (24 - 8 * UInt32($0))) & 0xFF) } }
    }

    public static func hex(_ data: [UInt8]) -> String { hash(data).map { String(format: "%02x", $0) }.joined() }
}

// MARK: zip reader (the release archives: stored or deflated members)

public struct ZipReader {
    public struct Member { public let name: String; let method: Int; let compressed: Int; let size: Int; let offset: Int; let crc: UInt32 }
    public let members: [Member]
    let data: [UInt8]
    let inflate: Card.Inflate?

    static func u16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }

    public init(_ data: [UInt8], inflate: Card.Inflate?) throws {
        self.data = data
        self.inflate = inflate
        // end of central directory: the last "PK\5\6" within the final 64 KiB + 22 bytes
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 65_557) {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 5 && data[i + 3] == 6 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw TransferError("not a zip archive") }
        let count = Self.u16(data, eocd + 10)
        var p = Releases.u32(data, eocd + 16)
        var out: [Member] = []
        for _ in 0..<count {
            guard p + 46 <= data.count, Releases.u32(data, p) == 0x0201_4B50 else { throw TransferError("zip directory damaged") }
            let method = Self.u16(data, p + 10), crc = UInt32(Releases.u32(data, p + 16))
            let csize = Releases.u32(data, p + 20), size = Releases.u32(data, p + 24)
            let nlen = Self.u16(data, p + 28), xlen = Self.u16(data, p + 30), clen = Self.u16(data, p + 32)
            let local = Releases.u32(data, p + 42)
            guard p + 46 + nlen <= data.count else { throw TransferError("zip directory damaged") }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            out.append(Member(name: name, method: method, compressed: csize, size: size, offset: local, crc: crc))
            p += 46 + nlen + xlen + clen
        }
        members = out
    }

    public var names: [String] { members.map(\.name) }

    public func read(_ name: String) throws -> [UInt8] {
        guard let m = members.first(where: { $0.name == name }) else { throw TransferError("\(name) is not in the archive") }
        let o = m.offset
        guard o + 30 <= data.count, Releases.u32(data, o) == 0x0403_4B50 else { throw TransferError("zip entry \(name) damaged") }
        let start = o + 30 + Self.u16(data, o + 26) + Self.u16(data, o + 28)
        guard start + m.compressed <= data.count else { throw TransferError("zip entry \(name) cut off") }
        let raw = Array(data[start..<(start + m.compressed)])
        let out: [UInt8]
        switch m.method {
        case 0: out = raw
        case 8:
            guard let inflate, let d = inflate(raw, m.size) else { throw TransferError("zip entry \(name) does not unpack") }
            out = d
        default: throw TransferError("zip entry \(name): method \(m.method) not supported")
        }
        guard out.count == m.size, CRC32.checksum(out) == m.crc else { throw TransferError("zip entry \(name): CRC-32 wrong") }
        return out
    }
}

// MARK: what may be installed (companion install.py)

public struct MeterFacts: Equatable, Sendable {
    public var connected: Bool
    public var firmware: Version?
    public var bootloader: String?          // "EEV", "B-A.BC" or nil
    public var inUpdateMode: Bool
    public init(connected: Bool, firmware: Version?, bootloader: String?, inUpdateMode: Bool) {
        self.connected = connected; self.firmware = firmware; self.bootloader = bootloader; self.inUpdateMode = inUpdateMode
    }
    public var twoPart: Version? { Version(meterText: bootloader, prefix: "B") }
    /// Through the two-part bootloader's update mode, or the SD card (page Ld-bt, then EEVblog's bootloader keys).
    public var bluetoothRoute: Bool { inUpdateMode || twoPart != nil }
}

public struct InstallPlan: Equatable, Sendable {
    public enum Relation: String, Sendable { case newer, same, older, unknown, custom }
    public var kind: Releases.Kind
    public var label: String
    public var tag: String?
    public var custom: Bool
    public var relation: Relation
    public var refusal: String?
    public var needsMeter = false
    public var needsConfirm = false
    public var warnings: [String] = []
    public static let word = "INSTALL"

    static let firstInstallMin = Version(1, 0, 3)
    static let fwFeatures: [(Version, String)] = [
        (Version(1, 0, 3), "F-1.03: the meter answers the bootloader question and the Bluetooth request to restart into the bootloader's update mode. Older firmware does not: the app cannot tell which bootloader the meter has, and the next update goes through the SD card (page Ld-bt, then MEM + HOLD at power-on and SETUP)."),
        (Version(1, 0, 4), "F-1.04: exFAT cards, long file names and the card format page Fr. Older firmware does not list them: a card formatted as exFAT may not be readable."),
        (Version(1, 1, 2), "F-1.12: card sessions run on the PLL clock. Before, block writes to some cards stopped with a transmit underrun (GitHub issue 5)."),
        (Version(1, 1, 5), "F-1.15: the extended diagnosis (the meter counts the errors of its Bluetooth line); the report loses that section."),
        (Version(1, 1, 6), "F-1.16: the setting HUnt (capacitance anti-hunting). An older firmware ignores the stored value and the settings page does not show the row."),
        (Version(1, 1, 7), "F-1.17: the meter-clock measurement in the report and the button Leave page Ld (without it a key press on the meter is needed to leave the page Ld-bt)."),
        (Version(1, 1, 8), "F-1.18: the setting auto power-off time and waking from power-off with a key with Bluetooth kept. An older firmware ignores the stored time."),
        (Version(1, 1, 9), "F-1.19: careful mode for meters with the old BLE112 Bluetooth module. Without it such a meter shows damaged readings and card lists or downloads can fail (GitHub issues 9 and 14)."),
        (Version(1, 2, 0), "F-1.20: bar-graph fixes (GitHub issues 19 and 17). An older firmware has those faults again."),
        (Version(1, 2, 1), "F-1.21: the setting CHIrP (diode contact chirp). An older firmware ignores the stored value and the settings page does not show the row."),
        (Version(1, 2, 2), "F-1.22: the two SETUP walks, and Bluetooth on after an update over Bluetooth with bootloader 1.1.4 (GitHub issues 24 and 23). Older firmware starts with Bluetooth off after an update: hold PEAK so the app can reconnect."),
        (Version(1, 3, 3), "F-1.33: the continuity codes DNUSr and UPUSr with a threshold of your own (page th) and its hysteresis (page HY). An older firmware reads the codes 16 and 17 as DN 30 and ignores the stored threshold and hysteresis."),
    ]
    static let blFeatures: [(Version, String)] = [
        (Version(1, 1, 0), "B-1.10: reads exFAT cards for the card update. An older bootloader reads FAT12/16/32 only."),
        (Version(1, 1, 1), "B-1.11: SD driver with the card start-up fixes (IMP-34)."),
        (Version(1, 1, 2), "B-1.12: SD driver with the fix OF-66 (sector reads into buffers that are not a multiple of 4 landed 1 to 3 bytes off)."),
        (Version(1, 1, 3), "B-1.13: the card update reads the card at the card-session clock (PLL 32 MHz, IMP-41)."),
    ]
    static let eepromNote = "The transfer and the bootloader do not write the meter's data EEPROM (calibration, serial number, options)."

    static func between(_ t: [(Version, String)], _ low: Version?, _ high: Version?) -> [String] {
        t.filter { (low == nil || $0.0 > low!) && (high == nil || $0.0 <= high!) }.map(\.1)
    }

    /// The plan to install `release` or a file of the user's own (`customName`, `customSize`) as `kind`.
    public static func make(kind: Releases.Kind, meter: MeterFacts, release: Releases.Entry? = nil,
                            customName: String? = nil, customSize: Int = 0, newest: Version? = nil) -> InstallPlan {
        let custom = customName != nil
        let current = kind == .firmware ? meter.firmware : meter.twoPart
        var p = InstallPlan(kind: kind, label: customName ?? release?.text ?? "?", tag: release?.tag, custom: custom,
                            relation: .custom)
        if let r = release {
            p.relation = current.map { r.version > $0 ? .newer : r.version == $0 ? .same : .older } ?? .unknown
        }
        if !meter.connected {
            p.needsMeter = true
            p.refusal = "no meter connected: connect the meter (its firmware and bootloader decide what can be installed)"
            return p
        }
        if kind == .firmware {
            if custom && meter.bluetoothRoute && customSize > Releases.blFirmwareMax {
                p.refusal = "the file has \(customSize) bytes; the two-part bootloader takes firmware images of at most \(Releases.blFirmwareMax) bytes"
            }
        } else if meter.bootloader == "EEV" {
            if custom {
                p.refusal = "a bootloader file of your own is not sent to a meter that still has EEVblog's bootloader: the first install writes the starter at the start of flash once and never again, and a starter cannot be checked here and cannot be put back without a programming probe. Install a release of the project first."
            } else if meter.firmware == nil || meter.firmware! < firstInstallMin {
                p.refusal = "the first bootloader install needs firmware \(firstInstallMin.firmwareText) or newer on the meter: update the firmware first"
            }
        } else if meter.twoPart == nil {
            p.refusal = "the meter does not say which bootloader it has (firmware older than \(firstInstallMin.firmwareText) does not answer the question): a bootloader is not sent"
        }
        if p.refusal != nil { return p }
        if custom {
            p.needsConfirm = true
            if kind == .firmware {
                p.warnings = [
                    "This is a file of your own, not a release of the project. The app checked what the meter checks as well (size, initial stack pointer, reset vector); it cannot tell which firmware this is, which version, or that it works on this meter.",
                    "Firmware without the project's Bluetooth functions (page Ld-bt, the restart into update mode; for example EEVblog's own v2.05) cannot be updated again over Bluetooth. The SD card route stays: EEVBlog.bin in the card's root, MEM + HOLD at power-on, then SETUP.",
                    "Firmware of another origin need not follow the project's rules for the data EEPROM: it can change the calibration, the serial number and the options. Keep the backup of the calibration (cal.bin on the card) first.",
                ]
            } else {
                p.warnings = [
                    "This is a file of your own, not a release of the project. The app checked that it has the vector table of the two-part bootloader and a size it accepts; the bootloader itself checks only length and CRC-32 of this kind of file, and the starter installs and starts what it finds.",
                    "If the new bootloader never confirms its start, the starter puts the previous one back at the next start (take the batteries out and put them back). A bootloader that starts but cannot receive over Bluetooth stays: then only the card update (MEM + HOLD at power-on, then SETUP) works.",
                ]
            }
            p.warnings.append(eepromNote)
            return p
        }
        guard let target = release?.version else { return p }
        let older = p.relation == .older
        let unsure = p.relation == .unknown && newest != nil && target != newest
        if !(older || unsure) { return p }
        p.needsConfirm = true
        if kind == .firmware {
            p.warnings.append(older
                ? "\(p.label) is older than the \(current!.firmwareText) on the meter. Going back to an older firmware can break things the newer one set up or relies on:"
                : "The app does not know which firmware the meter has, so it cannot tell whether \(p.label) is older. An older firmware can break things a newer one set up or relies on:")
            let f = between(fwFeatures, target, current)
            p.warnings += f.isEmpty ? ["  (no feature of the list lies between the two versions)"] : f.map { "  " + $0 }
            p.warnings.append("Settings that a newer firmware keeps in bytes an older one does not use are ignored by the older firmware.")
        } else {
            p.warnings.append(older
                ? "\(p.label) is older than the \(current!.bootloaderText) on the meter. An older bootloader lacks what the newer ones added to the card update (MEM + HOLD at power-on, then SETUP):"
                : "The meter still has EEVblog's bootloader, so this installs the two-part bootloader for the first time, and \(p.label) is not the newest release (\(newest!.bootloaderText)). An older bootloader lacks what the newer ones added to the card update:")
            p.warnings += between(blFeatures, target, current).map { "  " + $0 }
            if meter.bootloader == "EEV" { p.warnings.append("The first install writes the starter at the start of flash, once and never again.") }
            p.warnings.append("The older bootloader is installed like a new one: the starter copies it at the next start (the display stays blank for about a second). If it does not start, the starter puts the previous bootloader back at the next start (take the batteries out and put them back).")
        }
        p.warnings.append(eepromNote)
        return p
    }
}
