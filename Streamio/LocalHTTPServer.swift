import Foundation
import Network

/// 127.0.0.1 HTTP server exposing ONE torrent file with Range support, for AVPlayer.
///
/// Missing-data policy (chosen for AVPlayer): BLOCK, don't fail.
///  - Before headers: wait up to 30 s for the first needed piece; if it never arrives answer 503 + Retry-After.
///  - Mid-body: wait up to 45 s per piece, then drop the connection (AVPlayer retries with a fresh Range).
/// AVPlayer treats 503/short bodies as fatal far more often than it treats a slow response as a stall,
/// and it happily re-requests ranges after a seek, so blocking keeps playback alive.
final class LocalHTTPServer: @unchecked Sendable {
    private let store: PieceStore
    private let contentType: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "streamio.http")
    private(set) var port: UInt16 = 0

    init(store: PieceStore, contentType: String) throws {
        self.store = store
        self.contentType = contentType
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        let p: UInt16 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let box = OnceBox(c)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { box.resume(.success(port)) }
                    else { box.resume(.failure(TorrentError.malformed("no listener port"))) }
                case .failed(let e): box.resume(.failure(e))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                let link = TCPLink(accepted: conn)
                Task { await self.handle(link) }
            }
            listener.start(queue: queue)
        }
        port = p
        return p
    }

    func stop() { listener.cancel() }

    // MARK: request handling

    private func handle(_ link: TCPLink) async {
        defer { link.close() }
        guard let (method, range) = try? await readRequest(link) else { return }
        #if DEBUG
        let srvT0 = Date()
        let rangeDesc: String = range.map { r in "bytes=\(r.start.map(String.init) ?? "*")-\(r.end.map(String.init) ?? "*")" } ?? "none"
        print("[SRVLOG] \(method) range=\(rangeDesc)"); fflush(stdout)
        #endif
        let total = store.file.length
        guard total > 0 else { try? await respond(link, status: "404 Not Found"); return }

        var start = 0, end = total - 1
        var partial = false
        if let r = range {
            partial = true
            if let s = r.start { start = s; end = min(r.end ?? (total - 1), total - 1) }
            else if let suffix = r.end { start = max(0, total - suffix) }   // "bytes=-N"
        }
        guard start <= end, start < total else {
            try? await respond(link, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(total)"])
            return
        }
        let length = end - start + 1

        // Wait (bounded) for the first piece BEFORE committing to headers so we can still 503 cleanly.
        let token = UUID()
        defer { Task { [store] in await store.clearPriority(token: token) } }
        let firstNeeded = (store.file.offset + start) / store.meta.pieceLength
        if method == "GET" {
            await store.setPriority(token: token, piece: firstNeeded)
            // Persistent playhead: keeps buffering ahead of the playback
            // position even when paused (per-request priority is cleared above).
            await store.setPlayhead(firstNeeded)
            guard await waitForPiece(firstNeeded, timeout: 30) else {
                #if DEBUG
                print("[SRVLOG] 503 firstNeeded=\(firstNeeded) never arrived in 30s"); fflush(stdout)
                #endif
                try? await respond(link, status: "503 Service Unavailable", headers: ["Retry-After": "5"])
                return
            }
        }

        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes", "Content-Length": "\(length)", "Connection": "close"]
        if partial { headers["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        try? await respond(link, status: partial ? "206 Partial Content" : "200 OK", headers: headers)
        guard method == "GET" else { return }

        var pos = start
        while pos <= end {
            let absolute = store.file.offset + pos
            let piece = absolute / store.meta.pieceLength
            await store.setPriority(token: token, piece: piece)
            guard await waitForPiece(piece, timeout: 45) else {
                #if DEBUG
                print("[SRVLOG] mid-body timeout piece=\(piece) at pos=\(pos) after \(String(format: "%.1f", Date().timeIntervalSince(srvT0)))s"); fflush(stdout)
                #endif
                return
            }
            let pieceEnd = (piece + 1) * store.meta.pieceLength - store.file.offset   // file-relative, exclusive
            let n = min(end + 1, pieceEnd, pos + 256 * 1024) - pos
            guard let chunk = try? await store.read(filePos: pos, length: n), chunk.count == n else { return }
            do { try await link.send(chunk, timeout: 60) } catch {
                #if DEBUG
                print("[SRVLOG] send error at pos=\(pos) after \(String(format: "%.1f", Date().timeIntervalSince(srvT0)))s"); fflush(stdout)
                #endif
                return
            }
            pos += n
        }
        #if DEBUG
        print("[SRVLOG] completed \(start)-\(end) in \(String(format: "%.1f", Date().timeIntervalSince(srvT0)))s"); fflush(stdout)
        #endif
    }

    private func waitForPiece(_ p: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await store.hasPiece(p) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return await store.hasPiece(p)
    }

    private struct ByteRange { let start: Int?; let end: Int? }

    private func readRequest(_ link: TCPLink) async throws -> (String, ByteRange?) {
        var buf = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buf.range(of: terminator) == nil {
            guard buf.count < 16 * 1024 else { throw TorrentError.malformed("request too large") }
            buf += try await link.receiveSome(max: 4096, timeout: 10)
        }
        let text = String(decoding: buf, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        guard method == "GET" || method == "HEAD" else { throw TorrentError.malformed("method") }
        var range: ByteRange?
        for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
            // Only a single "bytes=a-b" range is supported (that's all AVPlayer sends).
            let v = l.dropFirst(6).trimmingCharacters(in: .whitespaces).lowercased()
            guard v.hasPrefix("bytes=") else { continue }
            let spec = v.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 { range = ByteRange(start: Int(parts[0]), end: Int(parts[1])) }
        }
        return (method, range)
    }

    private func respond(_ link: TCPLink, status: String, headers: [String: String] = [:]) async throws {
        var s = "HTTP/1.1 \(status)\r\n"
        var h = headers
        if h["Content-Length"] == nil { h["Content-Length"] = "0" }
        if h["Connection"] == nil { h["Connection"] = "close" }
        for (k, v) in h { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        try await link.send(Data(s.utf8))
    }
}
