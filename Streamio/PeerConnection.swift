import Foundation
import Network

/// Thin async wrapper over NWConnection. Every operation takes a timeout; a timeout cancels the whole
/// connection (an unresponsive peer is dead to us), which also unblocks the pending receive.
final class TCPLink: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "streamio.tcp")

    init(host: String, port: UInt16) {
        let params = NWParameters.tcp
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    /// Wraps an already-accepted inbound connection (used by the local HTTP server).
    init(accepted: NWConnection) {
        conn = accepted
        conn.start(queue: queue)
    }

    func close() { conn.cancel() }

    private func armTimer(_ seconds: TimeInterval) -> DispatchWorkItem {
        let item = DispatchWorkItem { [conn] in conn.cancel() }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    func connect(timeout: TimeInterval) async throws {
        let timer = armTimer(timeout)
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = OnceBox(c)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let e): box.resume(.failure(e))
                case .cancelled: box.resume(.failure(TorrentError.timeout("connect")))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ data: Data, timeout: TimeInterval = 15) async throws {
        let timer = armTimer(timeout)
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    func receive(exactly n: Int, timeout: TimeInterval) async throws -> Data {
        if n == 0 { return Data() }
        let timer = armTimer(timeout)
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
                if let data, data.count == n { c.resume(returning: data) }
                else if let err { c.resume(throwing: err) }
                else { c.resume(throwing: TorrentError.malformed("connection closed")) }
            }
        }
    }

    /// Reads whatever is available (1...max bytes). Used by the HTTP server for request parsing.
    func receiveSome(max: Int, timeout: TimeInterval) async throws -> Data {
        let timer = armTimer(timeout)
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, err in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if let err { c.resume(throwing: err) }
                else { c.resume(throwing: TorrentError.malformed("connection closed")) }
            }
        }
    }
}

/// Resumes a continuation at most once (NWConnection state handlers can fire repeatedly).
final class OnceBox<T: Sendable>: @unchecked Sendable {
    private var c: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func resume(_ r: Result<T, Error>) {
        lock.lock(); let cc = c; c = nil; lock.unlock()
        cc?.resume(with: r)
    }
}

enum PeerMessage: Sendable {
    case keepAlive
    case choke, unchoke, interested, notInterested
    case have(Int)
    case bitfield(Data)
    case request(Int, Int, Int)
    case piece(index: Int, begin: Int, block: Data)
    case cancel
    case extended(id: Int, payload: Data)
    case other(UInt8)
}

/// BitTorrent peer-wire connection (BEP 3) with the extension protocol (BEP 10) for ut_metadata (BEP 9).
final class PeerConnection: @unchecked Sendable {
    let peer: Peer
    private let link: TCPLink
    private let infoHash: Data
    private let peerID: Data
    private(set) var remoteSupportsExtensions = false
    static let maxMessage = 1 << 20   // reject absurd frames from malformed peers

    init(peer: Peer, infoHash: Data, peerID: Data) {
        self.peer = peer; self.infoHash = infoHash; self.peerID = peerID
        self.link = TCPLink(host: peer.host, port: peer.port)
    }

    func close() { link.close() }

    func open(timeout: TimeInterval = 6) async throws {
        try await link.connect(timeout: timeout)
        var hs = Data([19]) + Data("BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10   // BEP 10 extension protocol
        hs += Data(reserved) + infoHash + peerID
        try await link.send(hs)
        let resp = try await link.receive(exactly: 68, timeout: 8)
        let r = [UInt8](resp)
        guard r[0] == 19, Data(r[1..<20]) == Data("BitTorrent protocol".utf8) else { throw TorrentError.malformed("handshake") }
        guard Data(r[28..<48]) == infoHash else { throw TorrentError.malformed("infohash mismatch") }
        remoteSupportsExtensions = (r[25] & 0x10) != 0
    }

    func send(id: UInt8, payload: Data = Data()) async throws {
        var len = UInt32(payload.count + 1).bigEndian
        let frame = Data(bytes: &len, count: 4) + Data([id]) + payload
        try await link.send(frame)
    }

    func sendExtended(id: UInt8, payload: Data) async throws {
        try await send(id: 20, payload: Data([id]) + payload)
    }

    func sendInterested() async throws { try await send(id: 2) }

    func sendRequest(index: Int, begin: Int, length: Int) async throws {
        var p = Data()
        for v in [index, begin, length] { var be = UInt32(v).bigEndian; p.append(Data(bytes: &be, count: 4)) }
        try await send(id: 6, payload: p)
    }

    func next(timeout: TimeInterval) async throws -> PeerMessage {
        let lenData = try await link.receive(exactly: 4, timeout: timeout)
        let len = Int(lenData.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        if len == 0 { return .keepAlive }
        guard len <= Self.maxMessage else { throw TorrentError.malformed("frame too large") }
        let body = [UInt8](try await link.receive(exactly: len, timeout: timeout))
        func u32(_ o: Int) -> Int? {
            guard body.count >= o + 4 else { return nil }
            return Int(body[o]) << 24 | Int(body[o+1]) << 16 | Int(body[o+2]) << 8 | Int(body[o+3])
        }
        switch body[0] {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4: guard let i = u32(1) else { throw TorrentError.malformed("have") }; return .have(i)
        case 5: return .bitfield(Data(body[1...]))
        case 6: return .request(0, 0, 0)
        case 7:
            guard let i = u32(1), let b = u32(5) else { throw TorrentError.malformed("piece") }
            return .piece(index: i, begin: b, block: Data(body[9...]))
        case 8: return .cancel
        case 20:
            guard body.count >= 2 else { throw TorrentError.malformed("ext") }
            return .extended(id: Int(body[1]), payload: Data(body[2...]))
        default: return .other(body[0])
        }
    }

    // MARK: ut_metadata (BEP 9)

    /// Fetches and verifies the info dictionary from this peer. Returns the raw info bytes.
    func fetchMetadata() async throws -> Data {
        guard remoteSupportsExtensions else { throw TorrentError.metadataFailed("peer lacks extension support") }
        let hs = Bencode.dict(["m": .dict(["ut_metadata": .int(1)])]).encode()
        try await sendExtended(id: 0, payload: hs)

        var theirID: Int?
        var size: Int?
        let deadline = Date().addingTimeInterval(20)
        while theirID == nil, Date() < deadline {
            if case .extended(let id, let payload) = try await next(timeout: 10), id == 0,
               let (d, _) = try? Bencode.decode(payload) {
                theirID = d["m"]?["ut_metadata"]?.intValue
                size = d["metadata_size"]?.intValue
            }
        }
        guard let remoteID = theirID, remoteID > 0, let total = size, total > 0, total <= 16 << 20 else {
            throw TorrentError.metadataFailed("peer doesn't serve ut_metadata")
        }
        let pieceSize = 16384
        let count = (total + pieceSize - 1) / pieceSize
        var pieces = [Data?](repeating: nil, count: count)
        for i in 0..<count {
            try await sendExtended(id: UInt8(remoteID), payload: Bencode.dict(["msg_type": .int(0), "piece": .int(i)]).encode())
        }
        let end = Date().addingTimeInterval(25)
        while pieces.contains(where: { $0 == nil }), Date() < end {
            guard case .extended(let id, let payload) = try await next(timeout: 10), id == 1 else { continue }
            guard let (d, used) = try? Bencode.decode(payload), let type = d["msg_type"]?.intValue, let idx = d["piece"]?.intValue,
                  idx >= 0, idx < count else { continue }
            if type == 2 { throw TorrentError.metadataFailed("peer rejected request") }
            if type == 1 { pieces[idx] = payload.suffix(from: payload.startIndex + used) }
        }
        guard pieces.allSatisfy({ $0 != nil }) else { throw TorrentError.timeout("metadata download") }
        let info = pieces.compactMap { $0 }.reduce(Data(), +)
        guard info.count == total, TorrentMetadata.sha1(info) == infoHash else {
            throw TorrentError.metadataFailed("hash mismatch")
        }
        return info
    }
}
