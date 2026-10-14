import Foundation
import OSLog

struct TorrentProgress: Sendable {
    var stage: String          // human-readable
    var piecesDone = 0
    var piecesTotal = 0
    var peers = 0
}

private let log = Logger(subsystem: "com.barkleesanders.streamio", category: "torrent")

/// Thrown by the piece downloader when a seek has moved the demand window
/// and the in-flight piece is no longer wanted. Caught in the session loop,
/// which releases the piece and immediately claims the urgent one.
private struct SupersededPieceError: Error {}

/// Hands out peers to workers; thread-safe.
private actor PeerQueue {
    private var items: [Peer]
    private var seen: Set<Peer>
    init(_ peers: [Peer]) { items = peers; seen = Set(peers) }
    func next() -> Peer? { items.isEmpty ? nil : items.removeFirst() }
    func add(_ peers: [Peer]) { for p in peers where seen.insert(p).inserted { items.append(p) } }
    var isEmpty: Bool { items.isEmpty }
}

/// Collects open connections so the metadata race can close the losers immediately.
private final class ConnBag: @unchecked Sendable {
    private var conns: [PeerConnection] = []
    private let lock = NSLock()
    func add(_ c: PeerConnection) { lock.lock(); conns.append(c); lock.unlock() }
    func closeAll() { lock.lock(); let c = conns; lock.unlock(); c.forEach { $0.close() } }
}

/// Minimal sequential torrent streamer: HTTP tracker -> peer wire -> ut_metadata -> in-order piece download
/// -> local HTTP server with Range support.
actor TorrentStreamer {
    private let infoHash: Data
    private let infoHashHex: String
    private let fileIdx: Int?
    private let extraTrackers: [String]
    private let peerID: Data
    private var store: PieceStore?
    private var server: LocalHTTPServer?
    private var workers: [Task<Void, Never>] = []
    private var stopped = false
    private var activePeers = 0
    /// Peers that delivered at least one SHA1-verified piece this session.
    /// Persisted on stop (and as they prove themselves) so the next entry
    /// reconnects to known-good peers first — the warm start libtorrent's
    /// resume data gives Stremio, which builds ≤18 threw away: every
    /// re-entry re-announced cold and re-fetched metadata from scratch.
    private var goodPeersThisSession = Set<Peer>()

    init(infoHashHex: String, fileIdx: Int?, extraTrackers: [String] = []) throws {
        let hex = infoHashHex.lowercased()
        guard hex.count == 40, let d = Hex.decode(hex) else { throw TorrentError.invalidInfoHash }
        infoHash = d
        self.infoHashHex = hex
        self.fileIdx = fileIdx
        self.extraTrackers = extraTrackers
        peerID = Data("-ST0001-".utf8) + Data((0..<12).map { _ in UInt8.random(in: 48...57) })
    }

    // MARK: public

    /// Runs discovery + metadata + initial buffering and returns the local URL to hand to AVPlayer.
    /// - Parameter resumeFraction: 0..<1 position to resume from (Continue Watching).
    ///   The initial buffer is built at the resume point instead of the file start.
    func start(onProgress: @escaping @Sendable (TorrentProgress) -> Void,
              resumeFraction: Double? = nil) async throws -> URL {
        var prog = TorrentProgress(stage: "Finding peers…")
        onProgress(prog)

        // 0. Warm start (build 19): a previous session persists the raw
        // info dict and the peers that actually served verified pieces.
        // With both on disk, re-entry skips the two slowest cold steps —
        // tracker wait and the ut_metadata race — and goes straight to
        // serving the cached pieces while workers reconnect.
        let cachedInfo = Self.loadCachedInfo(infoHashHex: infoHashHex, infoHash: infoHash)
        let storedPeers = Self.loadStoredPeers(infoHashHex: infoHashHex)
        if cachedInfo != nil { log.info("warm start: metadata from cache, \(storedPeers.count) stored peers") }

        // 1. peers: stored (known-good) first, then the tracker announce —
        // to the magnet's own trackers plus the built-in defaults.
        var peers: [Peer] = storedPeers
        var trackerFailed = false
        for attempt in 0..<2 where peers.count < 10 {
            do {
                let found = try await TrackerClient.announce(infoHash: infoHash, peerID: peerID, extraTrackers: extraTrackers)
                trackerFailed = false
                for p in found where !peers.contains(p) { peers.append(p) }
            } catch { trackerFailed = true; log.error("announce attempt \(attempt) failed: \(error.localizedDescription)") }
        }
        if peers.isEmpty, cachedInfo == nil { throw trackerFailed ? TorrentError.trackerUnreachable : TorrentError.noPeers }
        log.info("peers: \(peers.count) (\(storedPeers.count) stored)")
        prog.peers = peers.count; prog.stage = "Fetching torrent info…"
        onProgress(prog)

        // 2. metadata: from the persisted info dict when present (verified
        // against the info hash at load); otherwise race peers for it and
        // persist the winner for the next entry.
        let info: Data
        if let cachedInfo {
            info = cachedInfo
        } else {
            guard !peers.isEmpty else { throw TorrentError.noPeers }
            // Build 23: the metadata race walks a wide candidate pool and,
            // if the whole pool refuses, RE-ANNOUNCES for a fresh tracker
            // sample and races again (bounded: 2 extra rounds). Measured
            // Oct 2026 on the Lanterns S1E8 swarm: most announced peers
            // refuse TCP or never complete ut_metadata (leecher/NAT-heavy
            // swarm), so a single 30-peer race failed outright while a
            // metadata-serving peer existed further down the list —
            // libtorrent/Stremio keep connecting until metadata lands.
            var pool = peers
            var fetched: Data?
            for round in 0..<3 {
                if let d = try? await fetchMetadata(from: pool) { fetched = d; break }
                guard round < 2, !stopped else { break }
                log.info("metadata round \(round) exhausted \(pool.count) peers; re-announcing")
                if let fresh = try? await TrackerClient.announce(infoHash: infoHash, peerID: peerID, extraTrackers: extraTrackers) {
                    var added = 0
                    for p in fresh where !pool.contains(p) { pool.append(p); added += 1 }
                    log.info("re-announce added \(added) new peers (pool \(pool.count))")
                    if added == 0 { break }
                } else { break }
            }
            guard let fetched else { throw TorrentError.metadataFailed("no peer served metadata") }
            info = fetched
            Self.saveCachedInfo(info, infoHashHex: infoHashHex)
        }
        let (root, _) = try Bencode.decode(info)
        let meta = try TorrentMetadata(infoDict: root)
        var file = meta.selectFile(fileIdx)
        if fileIdx == nil, !Self.avPlayerFriendly(file.path),
           let alt = meta.files.filter({ Self.avPlayerFriendly($0.path) }).max(by: { $0.length < $1.length }) { file = alt }
        log.info("metadata ok: \(meta.name) files=\(meta.files.count) pieces=\(meta.pieceHashes.count) pieceLen=\(meta.pieceLength) selected=\(file.path) len=\(file.length)")

        // 3. storage + server
        PieceStore.evictCacheIfNeeded(except: infoHashHex)
        let store = try PieceStore(meta: meta, file: file, infoHashHex: infoHashHex)
        self.store = store
        let srv = try LocalHTTPServer(store: store, contentType: Self.mime(file.path))
        let port = try await srv.start()
        server = srv
        log.info("local server on 127.0.0.1:\(port)")

        // 4. workers: always the full pool — on a warm start the peer list
        // may be small (or even empty until the reannounce lands) and the
        // loops below now wait for peers instead of exiting.
        let queue = PeerQueue(peers)
        for _ in 0..<12 {
            workers.append(Task { [weak self] in await self?.workerLoop(queue: queue, store: store, meta: meta) })
        }
        workers.append(Task { [weak self] in await self?.reannounceLoop(queue: queue, store: store) })

        // 5. initial buffer: first few pieces at the playback point
        // (resume point when continuing, else the file start).
        let totalPieces = await store.totalPieces
        let startPiece = await store.firstPiece
        let bufferStart: Int
        if let f = resumeFraction, f > 0, f < 0.98 {
            bufferStart = min(startPiece + Int(Double(totalPieces) * f), await store.lastPiece)
            await store.setPlayhead(bufferStart)
            log.info("resuming at fraction \(f) -> initial piece \(bufferStart)")
        } else {
            bufferStart = startPiece
        }
        let want = min(4, totalPieces)
        let deadline = Date().addingTimeInterval(75)
        while true {
            let done = await store.donePieces
            prog = TorrentProgress(stage: "Buffering torrent…", piecesDone: done, piecesTotal: totalPieces, peers: activePeers)
            onProgress(prog)
            if await store.isBuffered(from: bufferStart, count: want) { break }
            if stopped { throw TorrentError.cancelled }
            if Date() > deadline { await stop(); throw activePeers == 0 ? TorrentError.noPeers : TorrentError.timeout("buffering") }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(infoHashHex)/\(Self.safeName(file.path))") else { throw TorrentError.malformed("url") }
        return url
    }

    /// Live progress for the UI after `start` returns.
    func progress() async -> TorrentProgress {
        guard let store else { return TorrentProgress(stage: "Idle") }
        return TorrentProgress(stage: "Streaming", piecesDone: await store.donePieces, piecesTotal: await store.totalPieces, peers: activePeers)
    }

    func stop() async {
        stopped = true
        workers.forEach { $0.cancel() }
        workers.removeAll()
        server?.stop()
        // Persist this session's proven peers for the next warm start.
        if !goodPeersThisSession.isEmpty {
            Self.mergeStoredPeers(Array(goodPeersThisSession), infoHashHex: infoHashHex)
        }
        // Preserve the piece cache (data + index): re-entry must resume
        // from what was already downloaded, not from byte zero. The old
        // code deleted the .part file here (via a detached task, so the
        // delete could also land after a NEW session had reopened the
        // same path). Size is bounded by PieceStore.evictCacheIfNeeded.
        await store?.close(deleteFile: false)
    }

    // MARK: metadata

    private func fetchMetadata(from peers: [Peer]) async throws -> Data {
        let bag = ConnBag()
        let hash = infoHash, pid = peerID
        let candidates = Array(peers.prefix(120))
        let result: Data? = await withTaskGroup(of: Data?.self) { g in
            var iterator = candidates.makeIterator()
            var running = 0
            func addNext(_ g: inout TaskGroup<Data?>) -> Bool {
                guard let p = iterator.next() else { return false }
                g.addTask {
                    let c = PeerConnection(peer: p, infoHash: hash, peerID: pid)
                    bag.add(c)
                    defer { c.close() }
                    do { try await c.open(); return try await c.fetchMetadata() }
                    catch { log.debug("metadata via \(p.host):\(p.port) failed: \(error.localizedDescription)"); return nil }
                }
                return true
            }
            while running < 8, addNext(&g) { running += 1 }
            while let r = await g.next() {
                if let r { bag.closeAll(); g.cancelAll(); return r }
                if addNext(&g) {} else { running -= 1 }
            }
            return nil
        }
        guard let result else { throw candidates.isEmpty ? TorrentError.noPeers : TorrentError.metadataFailed("no peer served metadata") }
        return result
    }

    // MARK: download workers

    private func workerLoop(queue: PeerQueue, store: PieceStore, meta: TorrentMetadata) async {
        // Build 19: workers no longer exit after ~40 idle seconds. The old
        // exit combined with the reannounce loop into a permanent stall:
        // on a thin, churning swarm every worker could time out and die,
        // after which reannounce kept adding peers to a queue nobody
        // drained — "Streaming" forever, zero progress. A sleeping worker
        // costs nothing; a dead one costs the whole session.
        while !stopped, !Task.isCancelled {
            if await store.complete { return }
            guard let peer = await queue.next() else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            activePeers += 1
            do { try await runSession(peer: peer, store: store, meta: meta) }
            catch { log.debug("peer \(peer.host):\(peer.port) session ended: \(error.localizedDescription)") }
            activePeers -= 1
        }
    }

    private func reannounceLoop(queue: PeerQueue, store: PieceStore) async {
        while !stopped, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if await store.complete { return }
            // Reannounce when the queue is dry OR when every session has
            // died (queue may still hold peers that all failed to connect).
            if await queue.isEmpty || activePeers == 0,
               let more = try? await TrackerClient.announce(infoHash: infoHash, peerID: peerID, extraTrackers: extraTrackers) {
                await queue.add(more)
            }
        }
    }

    private func runSession(peer: Peer, store: PieceStore, meta: TorrentMetadata) async throws {
        let conn = PeerConnection(peer: peer, infoHash: infoHash, peerID: peerID)
        defer { conn.close() }
        try await conn.open()
        try await conn.sendInterested()
        var bf = Bitfield(pieceCount: meta.pieceHashes.count)
        var choked = true

        func handle(_ m: PeerMessage) {
            switch m {
            case .choke: choked = true
            case .unchoke: choked = false
            case .bitfield(let d): bf = Bitfield(pieceCount: meta.pieceHashes.count, raw: d)
            case .have(let i): bf.set(i)
            default: break
            }
        }

        // wait for unchoke
        let unchokeDeadline = Date().addingTimeInterval(20)
        while choked {
            guard Date() < unchokeDeadline else { throw TorrentError.timeout("unchoke") }
            handle(try await conn.next(timeout: 10))
        }

        var idleTicks = 0
        while !stopped, !Task.isCancelled {
            if await store.complete { return }
            guard let piece = await store.claim(bf) else {
                idleTicks += 1
                if idleTicks > 30 { return }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            idleTicks = 0
            do {
                let data = try await downloadPiece(piece, conn: conn, meta: meta, store: store, handle: handle, isChoked: { choked })
                try await store.complete(piece, data: data)
                // This peer delivered a verified piece: remember it so the
                // next session reconnects to it first (warm start).
                if goodPeersThisSession.insert(peer).inserted {
                    Self.mergeStoredPeers([peer], infoHashHex: infoHashHex)
                }
            } catch is SupersededPieceError {
                // A seek moved the window; the piece is no longer wanted.
                // Release it and immediately take the urgent one — the
                // session (and this good peer) stays alive.
                await store.release(piece)
            } catch {
                await store.release(piece)
                throw error
            }
        }
    }

    private func downloadPiece(_ index: Int, conn: PeerConnection, meta: TorrentMetadata, store: PieceStore,
                               handle: (PeerMessage) -> Void, isChoked: () -> Bool) async throws -> Data {
        let plen = meta.pieceLength(at: index)
        let blockSize = 16384
        var buffer = Data(count: plen)
        var requested = 0, received = 0, outstanding = 0
        var blocksIn = 0
        let maxOutstanding = 8
        let deadline = Date().addingTimeInterval(60)
        while received < plen {
            guard Date() < deadline else { throw TorrentError.timeout("piece \(index)") }
            while outstanding < maxOutstanding, requested < plen {
                let len = min(blockSize, plen - requested)
                try await conn.sendRequest(index: index, begin: requested, length: len)
                requested += len; outstanding += 1
            }
            let m = try await conn.next(timeout: 15)
            handle(m)
            if isChoked() { throw TorrentError.malformed("choked mid-piece") }
            if case .piece(let i, let begin, let block) = m, i == index {
                guard begin >= 0, begin + block.count <= plen else { throw TorrentError.malformed("block out of range") }
                buffer.replaceSubrange(begin..<(begin + block.count), with: block)
                received += block.count; outstanding -= 1
                blocksIn += 1
                // Seek preemption (build 19): if the demand window moved
                // (a seek re-targeted the playhead), abandon this piece once
                // we're meaningfully into it but far from done, so the
                // worker takes the seek target NOW instead of whenever this
                // piece happens to finish — libtorrent's streaming mode
                // clears piece deadlines on seek for the same reason.
                // Builds ≤18 waited for every in-flight piece, which on a
                // slow real-world peer adds seconds-to-a-minute per scrub.
                if blocksIn % 4 == 0, received >= plen / 4, received < plen * 9 / 10,
                   !(await store.isUrgent(index)) {
                    throw SupersededPieceError()
                }
            }
        }
        guard TorrentMetadata.sha1(buffer) == meta.pieceHashes[index] else { throw TorrentError.malformed("piece \(index) failed SHA1") }
        return buffer
    }

    // MARK: warm-start persistence (build 19)

    /// Loads the persisted raw info dict for a torrent, verified against
    /// the info hash — a corrupt or foreign file is ignored, never trusted.
    private static func loadCachedInfo(infoHashHex: String, infoHash: Data) -> Data? {
        let url = PieceStore.infoCacheURL(for: infoHashHex)
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              TorrentMetadata.sha1(data) == infoHash else { return nil }
        return data
    }

    private static func saveCachedInfo(_ info: Data, infoHashHex: String) {
        try? info.write(to: PieceStore.infoCacheURL(for: infoHashHex), options: .atomic)
    }

    /// Stored peers are "host:port" strings, most recently proven first.
    private static func loadStoredPeers(infoHashHex: String) -> [Peer] {
        let url = PieceStore.peersCacheURL(for: infoHashHex)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list.compactMap { spec in
            guard let colon = spec.lastIndex(of: ":"),
                  let port = UInt16(spec[spec.index(after: colon)...]) else { return nil }
            return Peer(host: String(spec[..<colon]), port: port)
        }
    }

    /// Prepends newly proven peers to the stored list (deduplicated, cap 50).
    private static func mergeStoredPeers(_ newPeers: [Peer], infoHashHex: String) {
        var merged: [Peer] = []
        for p in newPeers + loadStoredPeers(infoHashHex: infoHashHex) where !merged.contains(p) {
            merged.append(p)
            if merged.count >= 50 { break }
        }
        let specs = merged.map { "\($0.host):\($0.port)" }
        if let data = try? JSONEncoder().encode(specs) {
            try? data.write(to: PieceStore.peersCacheURL(for: infoHashHex), options: .atomic)
        }
    }

    // MARK: helpers

    nonisolated static func avPlayerFriendly(_ path: String) -> Bool {
        ["mp4", "m4v", "mov"].contains((path as NSString).pathExtension.lowercased())
    }

    nonisolated static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }

    nonisolated static func safeName(_ path: String) -> String {
        let n = (path as NSString).lastPathComponent
        return n.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
    }
}
