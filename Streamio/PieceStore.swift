import Foundation

struct Bitfield: Sendable {
    private(set) var bytes: [UInt8]
    let pieceCount: Int

    init(pieceCount: Int, raw: Data? = nil) {
        self.pieceCount = pieceCount
        let n = (pieceCount + 7) / 8
        var b = [UInt8](repeating: 0, count: n)
        if let raw { for (i, v) in raw.prefix(n).enumerated() { b[i] = v } }
        bytes = b
    }

    func has(_ p: Int) -> Bool {
        guard p >= 0, p < pieceCount else { return false }
        return bytes[p >> 3] & (0x80 >> UInt8(p & 7)) != 0
    }

    mutating func set(_ p: Int) {
        guard p >= 0, p < pieceCount else { return }
        bytes[p >> 3] |= 0x80 >> UInt8(p & 7)
    }
}

/// Disk-backed piece storage plus scheduling. Pieces are claimed sequentially from the playhead(s):
/// the newest active HTTP request gets priority (so an AVPlayer seek, or a trailing moov-atom fetch, jumps the queue),
/// then lowest-missing-first from the start of the selected file. Never rarest-first.
actor PieceStore {
    let meta: TorrentMetadata
    let file: TorrentFile
    let firstPiece: Int
    let lastPiece: Int
    private var have = Set<Int>()
    private var inflight = Set<Int>()
    private var priorities: [(UUID, Int)] = []   // oldest first; newest wins
    /// Persistent playback position. Unlike per-request priorities, this is
    /// never cleared — so pausing keeps buffering ahead of the playhead
    /// instead of falling back to downloading from the start of the file.
    private var playhead: Int?
    /// Pieces to buffer ahead of the playhead.
    private static let bufferAhead = 64
    private let handle: FileHandle
    let path: URL
    private let indexPath: URL

    /// On-disk index of downloaded pieces, persisted next to the .part file
    /// so exit/re-entry keeps the cache instead of re-downloading from zero
    /// (build 18 fix: previously close(deleteFile: true) threw every piece
    /// away on exit, making every resume a cold start).
    private struct CacheIndex: Codable {
        var pieceLength: Int
        var fileOffset: Int
        var fileLength: Int
        var firstPiece: Int
        var lastPiece: Int
        var have: [Int]
    }

    /// The cache lives in Library/Caches, not tmp: tmp can be purged by the
    /// system at any time, which would silently destroy resume state.
    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("streamio-torrents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Warm-start sidecar files (build 19): the raw info dict and the list
    /// of peers that served verified pieces, kept next to the piece cache.
    static func infoCacheURL(for infoHashHex: String) -> URL {
        cacheDir.appendingPathComponent("streamio-\(infoHashHex).info")
    }

    static func peersCacheURL(for infoHashHex: String) -> URL {
        cacheDir.appendingPathComponent("streamio-\(infoHashHex).peers.json")
    }

    init(meta: TorrentMetadata, file: TorrentFile, infoHashHex: String) throws {
        self.meta = meta
        self.file = file
        firstPiece = file.offset / meta.pieceLength
        lastPiece = max(firstPiece, (file.offset + max(file.length, 1) - 1) / meta.pieceLength)
        path = Self.cacheDir.appendingPathComponent("streamio-\(infoHashHex).part")
        indexPath = Self.cacheDir.appendingPathComponent("streamio-\(infoHashHex).json")
        // Restore the piece map when a previous session left a matching
        // cache: identical torrent layout and the data file still on disk.
        let fp = firstPiece, lp = lastPiece
        var restored = Set<Int>()
        if FileManager.default.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: indexPath),
           let idx = try? JSONDecoder().decode(CacheIndex.self, from: data),
           idx.pieceLength == meta.pieceLength, idx.fileOffset == file.offset,
           idx.fileLength == file.length, idx.firstPiece == fp, idx.lastPiece == lp {
            restored = Set(idx.have.filter { $0 >= fp && $0 <= lp })
        }
        // Sanity: the data file must actually extend past every restored
        // piece — protects against a truncated/purged .part resurrecting
        // phantom pieces from the index.
        if let maxP = restored.max(),
           let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int,
           size < (maxP + 1) * meta.pieceLength {
            restored = restored.filter { ($0 + 1) * meta.pieceLength <= size }
        }
        have = restored
        // NOTE: FileManager.createFile OVERWRITES an existing file's
        // contents — calling it unconditionally here truncated the cache
        // on every re-entry (the first build-18 cycle test caught this:
        // index restored 106 pieces, data file was zeros). Create only
        // when missing.
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: path)
    }

    private func persistIndex() {
        let idx = CacheIndex(pieceLength: meta.pieceLength, fileOffset: file.offset,
                             fileLength: file.length, firstPiece: firstPiece,
                             lastPiece: lastPiece, have: have.sorted())
        if let data = try? JSONEncoder().encode(idx) {
            try? data.write(to: indexPath, options: .atomic)
        }
    }

    /// Caps the on-disk torrent cache (oldest first; the torrent being
    /// started is never evicted). Called when a new stream starts.
    static func evictCacheIfNeeded(except infoHashHex: String, capBytes: Int = 4_000_000_000) {
        let dir = cacheDir
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let parts = items.filter { $0.pathExtension == "part" }.sorted { mtime($0) < mtime($1) }
        var total = parts.reduce(0) { $0 + size($1) }
        for u in parts where total > capBytes {
            if u.deletingPathExtension().lastPathComponent == "streamio-\(infoHashHex)" { continue }
            let s = size(u)
            let base = u.deletingPathExtension()
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("info"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("peers.json"))
            total -= s
        }
    }

    var totalPieces: Int { lastPiece - firstPiece + 1 }
    var donePieces: Int { have.count }
    var complete: Bool { have.count >= totalPieces }

    func hasPiece(_ p: Int) -> Bool { have.contains(p) }

    func setPriority(token: UUID, piece: Int) {
        if let i = priorities.firstIndex(where: { $0.0 == token }) { priorities[i].1 = piece }
        else { priorities.append((token, piece)) }
    }

    func clearPriority(token: UUID) { priorities.removeAll { $0.0 == token } }

    /// Sets the persistent playback position (updated on every range request
    /// the player makes). Pass nil to clear.
    func setPlayhead(_ piece: Int?) { playhead = piece }

    func claim(_ bf: Bitfield) -> Int? {
        func pick(_ range: Range<Int>) -> Int? {
            for p in range where !have.contains(p) && !inflight.contains(p) && bf.has(p) { return p }
            return nil
        }
        // 1. Buffer ahead of the playhead (survives pause — never cleared).
        if let ph = playhead {
            let start = max(ph, firstPiece)
            let end = min(lastPiece + 1, start + Self.bufferAhead)
            if start < end, let p = pick(start..<end) { inflight.insert(p); return p }
        }
        // 2. Per-request priorities (newest wins).
        for (_, start) in priorities.reversed() {
            if let p = pick(max(start, firstPiece)..<min(lastPiece + 1, max(start, firstPiece) + 48)) { inflight.insert(p); return p }
        }
        // 3. Sequential fallback from the start.
        if let p = pick(firstPiece..<(lastPiece + 1)) { inflight.insert(p); return p }
        return nil
    }

    /// True when `piece` is still wanted. A piece is stale ONLY when it is
    /// far from every live demand signal AND far past the sequential
    /// frontier — the exact case of a pre-seek leftover. Everything else
    /// must finish: vetoing frontier work deadlocks the engine (claim
    /// hands it out, the downloader aborts it at 25%, claim hands it out
    /// again…), which is precisely what the first build-19 rig run did —
    /// downloads froze at the cache frontier because VLC's tail/moov
    /// probe had parked the playhead at the last piece, making every
    /// sequential piece look "stale" to a playhead-only check.
    func isUrgent(_ p: Int) -> Bool {
        if let ph = playhead, p >= ph - 8, p < ph + Self.bufferAhead { return true }
        for (_, start) in priorities where p >= start && p < start + 48 { return true }
        if playhead == nil && priorities.isEmpty { return true }
        // Sequential frontier: count unclaimed missing pieces below p.
        // Near the frontier this is work claim()'s fallback would hand
        // out next anyway — never veto it.
        var gap = 0
        var q = firstPiece
        while q < p {
            if !have.contains(q) && !inflight.contains(q) {
                gap += 1
                if gap > Self.bufferAhead { return false }
            }
            q += 1
        }
        return true
    }

    /// True when `count` pieces starting at `piece` are all downloaded.
    func isBuffered(from piece: Int, count: Int) -> Bool {
        let end = min(piece + count, lastPiece + 1)
        for p in piece..<end where !have.contains(p) { return false }
        return true
    }

    func release(_ p: Int) { inflight.remove(p) }

    func complete(_ p: Int, data: Data) throws {
        inflight.remove(p)
        guard !have.contains(p) else { return }
        try handle.seek(toOffset: UInt64(p * meta.pieceLength))
        try handle.write(contentsOf: data)
        have.insert(p)
        if have.count % 8 == 0 { persistIndex() }
    }

    /// Reads `length` bytes at file-relative `pos`; the range must lie within one downloaded piece.
    func read(filePos pos: Int, length: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(file.offset + pos))
        return try handle.read(upToCount: length) ?? Data()
    }

    func close(deleteFile: Bool) {
        if !deleteFile { persistIndex() }
        try? handle.close()
        if deleteFile {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: indexPath)
        }
    }
}
