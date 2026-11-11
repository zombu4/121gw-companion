// Bluetooth LE link to a 121GW: scan, connect, receive frames, send bytes, reconnect (companion link.py).
//
// The meter's Bluetooth module carries the USART2 byte stream on one characteristic: notifications bring the meter's
// bytes, writes (with response) deliver bytes to it.  Everything here runs on the main queue (the data rate is at most
// a few hundred bytes a second), so the controller reads and calls it without locks.
//
// States: idle, scanning, connecting, connected, lost (the meter went away, e.g. auto power-off; the link searches again
// by itself while `want` is set).  The meter accepts one connection at a time: no other Bluetooth app may hold it.

import CoreBluetooth
import Foundation
import Meter121Kit

enum LinkState: String {
    case idle, scanning, connecting, connected, lost
}

struct FoundMeter: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
}

struct LinkStatistics {
    var notifications = 0
    var sizes = [0, 0, 0, 0]                   // 1..20, 21..64, 65..244, larger
    var gaps: [Double] = []                    // seconds between notifications of one connection (last 4000)
    var writes = 0
    var writeErrors = 0
    var lastWriteError: (Date, String)?
    var writeTimes: [Double] = []
    var rssi: [(Int, Int?)] = []               // (connection number, dBm) at discovery
    var connections = 0
    var mtu: Int?
    var disconnects: [(Date, Bool, String)] = []
    var disconnectCount = 0

    static let keep = 4000

    static func percentile(_ v: [Double], _ q: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))]
    }
}

enum LinkError: LocalizedError {
    case notConnected, writeFailed(String), timeout, cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: "not connected to a meter"
        case let .writeFailed(why): "write failed: \(why)"
        case .timeout: "the write was not confirmed in time"
        case .cancelled: "the write was cancelled (the connection went away)"
        }
    }
}

@MainActor
final class MeterLink: NSObject, ObservableObject {
    static let service = CBUUID(string: "0bd51666-e7cb-469b-8e4d-2742f1ba77cc")
    static let characteristic = CBUUID(string: "e7add780-b042-4876-aae1-112855353cc1")
    static let scanSeconds = 6.0
    static let writeWait = 5.0
    static let retrySeconds = 3.0
    static let quickRetry = 0.5
    static let l2IdleFlush = 0.5
    static let notFound = "no 121GW found: meter on, Bluetooth on (long PEAK), other Bluetooth apps closed?"

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var detail = ""
    @Published private(set) var found: [FoundMeter] = []
    @Published private(set) var deviceName: String?
    @Published private(set) var bluetoothState: CBManagerState = .unknown

    /// Every checked frame, with the time it was received (link 2 readings: the time the meter took them).
    var onFrame: ((Frame, Date) -> Void)?
    var onState: ((LinkState, String) -> Void)?

    private(set) var want = false
    var address: UUID?                                    // the meter chosen; nil = the first one heard
    var quickRetryWanted = false                          // while waiting for the bootloader's update mode
    private(set) var deviceID: UUID?
    private(set) var lastWrite = Date.distantPast
    private(set) var rxBytes = 0
    var stats = LinkStatistics()

    private(set) var reassembler = Reassembler()
    private(set) var link2 = Link2Decoder()
    /// True once the controller asked for link 2: only then do the bytes pass the decoder.
    var link2Expected = false
    private var l2Idle: Task<Void, Never>?
    private var lastNotification: Date?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var scanTimer: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var lostOnce = false
    private var misses = 0

    // one write with response at a time; each bounded by writeWait
    private struct PendingWrite {
        let data: Data
        let started: Date
        let done: CheckedContinuation<Void, Error>
    }
    private var writeQueue: [(Data, CheckedContinuation<Void, Error>)] = []
    private var inFlight: PendingWrite?
    private var writeTimer: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    var mtu: Int? { stats.mtu }

    // MARK: interface

    func connect(_ id: UUID? = nil) {
        address = id
        want = true
        endConnection()
        start()
    }

    func disconnect() {
        let was = state
        want = false
        endConnection()
        if was == .connected { recordDisconnect("disconnected by the user", user: true) }
        set(.idle)
    }

    /// Write bytes to the meter (with response); throws when not connected, when the write fails or is not confirmed.
    func send(_ bytes: [UInt8]) async throws {
        guard state == .connected, peripheral != nil, dataChar != nil else { throw LinkError.notConnected }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeQueue.append((Data(bytes), c))
            pumpWrites()
        }
    }

    func damaged() -> [(Int, [UInt8])] { reassembler.damaged() }

    // MARK: connection

    private func set(_ s: LinkState, _ d: String = "") {
        state = s
        detail = d
        onState?(s, d)
    }

    private func start() {
        guard want else { return }
        guard central.state == .poweredOn else {
            set(lostOnce ? .lost : .scanning, bluetoothText(central.state))
            return                                         // centralManagerDidUpdateState starts again
        }
        set(.scanning, "looking for the meter" + (lostOnce ? " again" : ""))
        found = []
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = after(Self.scanSeconds) { [weak self] in self?.scanTimedOut() }
    }

    private func scanTimedOut() {
        guard want, state == .scanning || state == .lost, peripheral == nil else { return }
        central.stopScan()
        misses += 1
        let text = quickRetryWanted ? "the meter is restarting into its update mode; looking for it" : Self.notFound
        set(lostOnce ? .lost : .scanning, text)
        schedule(start)
    }

    private func schedule(_ f: @escaping @MainActor @Sendable () -> Void) {
        retry?.cancel()
        retry = after(quickRetryWanted ? Self.quickRetry : Self.retrySeconds, f)
    }

    /// Run `f` on the main actor after `seconds`, unless the returned task is cancelled first.
    private func after(_ seconds: Double, _ f: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { f() }
        }
    }

    /// Unsubscribe, then cancel the connection, so no half-open connection keeps the meter from advertising.
    private func endConnection() {
        scanTimer?.cancel()
        retry?.cancel()
        if central.isScanning { central.stopScan() }
        if let p = peripheral {
            if let c = dataChar, p.state == .connected { p.setNotifyValue(false, for: c) }
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        dataChar = nil
        failWrites(LinkError.cancelled)
    }

    private func recordDisconnect(_ why: String, user: Bool) {
        stats.disconnectCount += 1
        stats.disconnects.append((Date(), user, why))
        if stats.disconnects.count > 50 { stats.disconnects.removeFirst() }
        lastNotification = nil
    }

    private func bluetoothText(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOff: "Bluetooth of the phone is off (searching again when it is on)"
        case .unauthorized: "this app may not use Bluetooth: allow it in Settings > Privacy > Bluetooth"
        case .unsupported: "this device has no Bluetooth LE"
        default: "waiting for Bluetooth"
        }
    }

    // MARK: receive

    private func received(_ chunk: [UInt8], at t: Date) {
        stats.notifications += 1
        let n = chunk.count
        stats.sizes[n <= 20 ? 0 : n <= 64 ? 1 : n <= 244 ? 2 : 3] += 1
        if let last = lastNotification {
            stats.gaps.append(t.timeIntervalSince(last))
            if stats.gaps.count > LinkStatistics.keep { stats.gaps.removeFirst(stats.gaps.count - LinkStatistics.keep) }
        }
        lastNotification = t
        rxBytes += n
        l2Idle?.cancel()
        l2Idle = nil
        guard link2Expected else {
            deliver(chunk, t)
            return
        }
        let (plain, readings) = link2.feed(chunk)
        for (frame, age) in readings { onFrame?(Frame(.status, frame), t.addingTimeInterval(-age)) }
        deliver(plain, t)
        if !link2.locked && !link2.buffer.isEmpty {
            let id = ObjectIdentifier(link2)
            l2Idle = after(Self.l2IdleFlush) { [weak self] in
                guard let self, ObjectIdentifier(self.link2) == id else { return }
                self.deliver(self.link2.flush(), Date())
            }
        }
    }

    private func deliver(_ plain: [UInt8], _ t: Date) {
        guard !plain.isEmpty else { return }
        for f in reassembler.feed(plain) { onFrame?(f, t) }
    }

    // MARK: writes

    private func pumpWrites() {
        guard inFlight == nil, !writeQueue.isEmpty else { return }
        guard let p = peripheral, let c = dataChar, state == .connected else {
            failWrites(LinkError.notConnected)
            return
        }
        let (data, cont) = writeQueue.removeFirst()
        inFlight = PendingWrite(data: data, started: Date(), done: cont)
        lastWrite = Date()
        p.writeValue(data, for: c, type: .withResponse)
        writeTimer = after(Self.writeWait) { [weak self] in self?.finishWrite(LinkError.timeout) }
    }

    private func finishWrite(_ error: Error?) {
        writeTimer?.cancel()
        writeTimer = nil
        guard let w = inFlight else { return }
        inFlight = nil
        if let error {
            stats.writeErrors += 1
            stats.lastWriteError = (Date(), error.localizedDescription)
            w.done.resume(throwing: error)
        } else {
            stats.writes += 1
            stats.writeTimes.append(Date().timeIntervalSince(w.started))
            if stats.writeTimes.count > LinkStatistics.keep { stats.writeTimes.removeFirst() }
            w.done.resume()
        }
        pumpWrites()
    }

    private func failWrites(_ e: Error) {
        writeTimer?.cancel()
        writeTimer = nil
        if let w = inFlight {
            inFlight = nil
            w.done.resume(throwing: e)
        }
        let q = writeQueue
        writeQueue = []
        for (_, c) in q { c.resume(throwing: e) }
    }
}

extension MeterLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothState = central.state
            if central.state == .poweredOn {
                if want && peripheral == nil { start() }
            } else if want {
                peripheral = nil
                dataChar = nil
                failWrites(LinkError.notConnected)
                set(lostOnce ? .lost : .scanning, bluetoothText(central.state))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "121GW"
            if let i = found.firstIndex(where: { $0.id == p.identifier }) {
                found[i].rssi = RSSI.intValue
            } else {
                found.append(FoundMeter(id: p.identifier, name: name, rssi: RSSI.intValue))
            }
            guard want, peripheral == nil, address == nil || address == p.identifier else { return }
            scanTimer?.cancel()
            central.stopScan()
            misses = 0
            stats.rssi.append((stats.connections + 1, RSSI.intValue))
            peripheral = p
            p.delegate = self
            deviceName = name
            set(.connecting, name)
            central.connect(p, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            guard p == peripheral else { return }
            p.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral else { return }
            peripheral = nil
            set(lostOnce ? .lost : .scanning, "connecting failed: \(error?.localizedDescription ?? "no reason given")")
            schedule(start)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral else { return }
            let wasConnected = state == .connected
            peripheral = nil
            dataChar = nil
            failWrites(LinkError.cancelled)
            if wasConnected {
                var why = "the Bluetooth stack reported the connection as gone"
                if let e = error { why += " (\(e.localizedDescription))" }
                if let w = stats.lastWriteError, Date().timeIntervalSince(w.0) <= 5 { why += "; last write error: \(w.1)" }
                recordDisconnect(why, user: false)
                lostOnce = true
            }
            if want {
                set(.lost, "the meter went away (auto power-off or out of range); looking for it again")
                schedule(start)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral, let s = p.services?.first(where: { $0.uuid == Self.service }) else {
                if p == peripheral { central.cancelPeripheralConnection(p) }
                return
            }
            p.discoverCharacteristics([Self.characteristic], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral, let c = s.characteristics?.first(where: { $0.uuid == Self.characteristic }) else {
                if p == peripheral { central.cancelPeripheralConnection(p) }
                return
            }
            dataChar = c
            p.setNotifyValue(true, for: c)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral, c.uuid == Self.characteristic, state == .connecting else { return }
            if let error {
                set(.scanning, "subscribing failed: \(error.localizedDescription)")
                central.cancelPeripheralConnection(p)
                return
            }
            reassembler = Reassembler()
            link2 = Link2Decoder()
            link2Expected = false
            rxBytes = 0
            lastNotification = nil
            deviceID = p.identifier
            // ATT MTU = the largest write without response + 3 (the old BLE112 gives 23, the BGM220S 247)
            stats.mtu = p.maximumWriteValueLength(for: .withoutResponse) + 3
            stats.connections += 1
            set(.connected, deviceName ?? "121GW")
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let bytes = c.value.map { [UInt8]($0) } ?? []
        let t = Date()
        MainActor.assumeIsolated {
            guard p == peripheral, error == nil, !bytes.isEmpty else { return }
            received(bytes, at: t)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral else { return }
            finishWrite(error.map { LinkError.writeFailed($0.localizedDescription) })
        }
    }
}
