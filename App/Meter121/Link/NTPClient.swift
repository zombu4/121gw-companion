// SNTP query over UDP with the Network framework (companion clock.ntp_time); the packet is built and read by
// Meter121Kit.MeterClock.

import Foundation
import Meter121Kit
import Network

enum NTPClient {
    struct Answer {
        var now: Date            // the server's time now
        var offset: Double       // server - phone clock, s
        var delay: Double        // round trip, s
    }

    enum Failure: LocalizedError {
        case noAnswer(String), bad(String)
        var errorDescription: String? {
            switch self {
            case let .noAnswer(s): "NTP server \(s) does not answer"
            case let .bad(s): "NTP server \(s): not a usable answer"
            }
        }
    }

    static func query(_ server: String, timeout: Double = 3.0) async throws -> Answer {
        let conn = NWConnection(host: NWEndpoint.Host(server), port: 123, using: .udp)
        let queue = DispatchQueue(label: "ntp")
        defer {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        let result: ([UInt8], Double, Double) = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            let fail: @Sendable (Error) -> Void = { e in if once.take() { cont.resume(throwing: e) } }
            queue.asyncAfter(deadline: .now() + timeout) { fail(Failure.noAnswer(server)) }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let t1 = Date().timeIntervalSince1970
                    conn.send(content: Data(MeterClock.ntpRequest(t1: t1)), completion: .contentProcessed { err in
                        if err != nil { fail(Failure.noAnswer(server)) }
                    })
                    conn.receiveMessage { data, _, _, err in
                        let t4 = Date().timeIntervalSince1970
                        guard err == nil, let data else { fail(Failure.noAnswer(server)); return }
                        if once.take() { cont.resume(returning: ([UInt8](data), t1, t4)) }
                    }
                case .failed, .cancelled:
                    fail(Failure.noAnswer(server))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        do {
            let r = try MeterClock.ntpParse(result.0, t1: result.1, t4: result.2)
            return Answer(now: Date().addingTimeInterval(r.offset), offset: r.offset, delay: r.delay)
        } catch {
            throw Failure.bad(server)
        }
    }

    /// A flag that lets exactly one of several racing callbacks resume a continuation.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
