import Foundation
import Network

/// BEP 15 UDP tracker announce (build 23). Measured Oct 2026 on the
/// Lanterns S1E8 magnet: 18 of 26 tracker hosts are UDP-only, and UDP
/// trackers with no HTTP presence returned 30+ real peers for the hash
/// (explodie.org 33, tracker.nyaa.vc 30) — swarms the HTTP-only client
/// could never reach.
enum UDPTracker {
    /// Announces to one udp:// tracker URL ("udp://host:port/announce" — path ignored).
    /// Returns parsed peers, or nil if the tracker did not answer / answered garbage within `timeout` seconds total.
    static func announce(tracker: String, infoHash: Data, peerID: Data, port: UInt16 = 6881, timeout: TimeInterval = 8) async -> [Peer]? {
        guard infoHash.count == 20, peerID.count == 20,
              let url = URL(string: tracker), url.scheme?.lowercased() == "udp",
              let host = url.host, !host.isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 6969)) else { return nil }

        // Race the whole exchange against a single overall deadline.
        return await withTaskGroup(of: [Peer]?.self) { group in
            group.addTask {
                await exchange(host: host, port: nwPort, infoHash: infoHash, peerID: peerID, listenPort: port)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll() // cancels the loser (and its NWConnection via the cancellation handler)
            return result
        }
    }

    // MARK: - Exchange (connect + announce)

    private static func exchange(host: String, port: NWEndpoint.Port, infoHash: Data, peerID: Data, listenPort: UInt16) async -> [Peer]? {
        let link = Link(host: host, port: port)
        defer { link.cancel() }
        return await withTaskCancellationHandler {
            guard await link.waitReady() else { return nil }

            // 1. Connect request: magic | action 0 | transaction id
            let tid = UInt32.random(in: .min ... .max)
            var req = Data(capacity: 16)
            req.appendBE(UInt64(0x0000_0417_2710_1980))
            req.appendBE(UInt32(0))
            req.appendBE(tid)
            guard await link.send(req), let resp = await link.receive(), resp.count >= 16,
                  resp.be(0) == UInt32(0), resp.be(4) == tid,
                  let connID: UInt64 = resp.be(8) else { return nil }

            // 2. Announce request (98 bytes)
            let atid = UInt32.random(in: .min ... .max)
            var ann = Data(capacity: 98)
            ann.appendBE(connID)
            ann.appendBE(UInt32(1))            // action: announce
            ann.appendBE(atid)
            ann.append(infoHash)
            ann.append(peerID)
            ann.appendBE(UInt64(0))            // downloaded
            ann.appendBE(UInt64(1))            // left
            ann.appendBE(UInt64(0))            // uploaded
            ann.appendBE(UInt32(2))            // event: started
            ann.appendBE(UInt32(0))            // IP: default
            ann.appendBE(UInt32.random(in: .min ... .max)) // key
            ann.appendBE(Int32(60))            // num_want
            ann.appendBE(listenPort)
            guard ann.count == 98, await link.send(ann), let aresp = await link.receive(), aresp.count >= 20,
                  aresp.be(0) == UInt32(1), aresp.be(4) == atid else { return nil }
            // interval/leechers/seeders live at 8/12/16; peers follow.
            return parsePeers(aresp, from: 20)
        } onCancel: {
            link.cancel()
        }
    }

    /// Compact peer list: 6-byte (IPv4) or 18-byte (IPv6) entries — a
    /// response carries exactly one family, told apart by divisibility.
    /// Port 0 entries filtered.
    private static func parsePeers(_ data: Data, from start: Int) -> [Peer] {
        let body = data.count - start
        guard body > 0 else { return [] }
        let size = body % 6 == 0 ? 6 : (body % 18 == 0 ? 18 : 6)
        var peers: [Peer] = []
        var off = start
        while off + size <= data.count {
            let base = data.startIndex + off
            let ip = data.subdata(in: base ..< base + size - 2)
            guard let port: UInt16 = data.be(off + size - 2) else { break }
            off += size
            guard port != 0 else { continue }
            let host: String
            if size == 18 {
                var groups: [String] = []
                for i in stride(from: 0, to: 16, by: 2) {
                    groups.append(String(format: "%x", UInt16(ip[ip.startIndex + i]) << 8 | UInt16(ip[ip.startIndex + i + 1])))
                }
                host = groups.joined(separator: ":")
            } else {
                host = ip.map { String($0) }.joined(separator: ".")
            }
            peers.append(Peer(host: host, port: port))
        }
        return peers
    }
}

// MARK: - NWConnection wrapper with async one-shot operations

private final class Link: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "UDPTracker.link")

    init(host: String, port: NWEndpoint.Port) {
        let params = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        conn = NWConnection(to: .hostPort(host: .name(host, nil), port: port), using: params)
    }

    func cancel() { conn.cancel() }

    /// Resolves true on `.ready`, false on failure/cancellation.
    func waitReady() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let once = Once(c)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                case .failed, .cancelled: once.resume(false)
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let once = Once(c)
            conn.send(content: data, completion: .contentProcessed { once.resume($0 == nil) })
        }
    }

    func receive() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            let once = Once(c)
            conn.receiveMessage { data, _, _, error in once.resume(error == nil ? data : nil) }
        }
    }
}

/// Guarantees a continuation is resumed at most once, from any thread.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - Big-endian Data helpers (bounds-checked, startIndex-relative)

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func be<T: FixedWidthInteger & UnsignedInteger>(_ offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var v: T = 0
        for i in 0 ..< size { v = (v << 8) | T(self[startIndex + offset + i]) }
        return v
    }
}
