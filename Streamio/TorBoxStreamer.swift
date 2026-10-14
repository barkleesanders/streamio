import Foundation
import OSLog

private let log = Logger(subsystem: "com.barkleesanders.streamio", category: "torbox")

enum TorBoxError: LocalizedError {
    case notConfigured
    case api(String)
    case timeout(String)
    case stalled(String)
    case noVideoFile

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "TorBox API key not configured (Debrid settings)."
        case .api(let m): return "TorBox: \(m)"
        case .timeout(let m): return "TorBox timed out: \(m)"
        case .stalled(let m): return "TorBox download stalled: \(m)"
        case .noVideoFile: return "TorBox: no video file in torrent."
        }
    }
}

/// Streams torrents through the TorBox API instead of P2P.
/// Flow: create torrent from magnet (idempotent) → wait until the files are
/// streamable on TorBox → request a direct download link → hand to the player.
///
/// TorBox state semantics (verified live 2026-10-12 against a real account):
/// an already-owned torrent reports download_state "cached" with
/// download_progress == null — its files sit on TorBox servers and are
/// streamable IMMEDIATELY. "completed" is the other ready state. Treating
/// only "completed" as ready (the pre-fix behavior) made every replay of a
/// cached torrent poll forever at "downloading 0%".
enum TorBoxStreamer {
    private static let base = "https://api.torbox.app/v1/api"

    struct MintedStream {
        let url: URL
        /// Real file name on TorBox (e.g. "Movie.2160p.WEB-DL.mkv"). TorBox
        /// download links carry no file extension, so the player router
        /// needs this to pick VLC vs AVPlayer by the true container.
        let fileName: String
    }

    /// Returns a direct https URL for the torrent's video file, or throws.
    /// - Parameters:
    ///   - infoHashHex: 40-char torrent info hash.
    ///   - fileIdx: preferred file index within the torrent (nil = largest video).
    ///   - onProgress: human-readable stage updates for the UI.
    static func streamURL(infoHashHex: String, fileIdx: Int?,
                          onProgress: @escaping @Sendable (String) -> Void) async throws -> MintedStream {
        guard let key = DebridConfig.apiKey, !key.isEmpty else { throw TorBoxError.notConfigured }

        let magnet = "magnet:?xt=urn:btih:\(infoHashHex.lowercased())"
        onProgress("TorBox: adding torrent…")
        log.info("creating torbox torrent for \(infoHashHex.prefix(8))…")

        // 1. Create (idempotent — returns the existing torrent if already added).
        let torrentId: Int = try await api("POST", "/torrents/createtorrent",
                                           key: key, form: ["magnet": magnet, "seed": "2", "allow_zip": "false"])
        { json in
            guard let id = (json["data"] as? [String: Any])?["torrent_id"] as? Int else {
                throw TorBoxError.api("create returned no torrent_id")
            }
            return id
        }
        log.info("torbox torrent_id=\(torrentId)")

        // 2. Wait until the files are streamable. Ready = state "cached" or
        // "completed", progress >= 1, or download_finished. Anything else is
        // a genuinely in-flight server-side download: poll with a stall
        // watchdog so a dead torrent fails in ~90 s instead of hanging.
        onProgress("TorBox: downloading…")
        let deadline = Date().addingTimeInterval(600)
        var files: [[String: Any]] = []
        var lastProgress = -1.0
        var lastProgressChange = Date()
        var misses = 0
        var requeueTried = false
        while true {
            if Date() > deadline { throw TorBoxError.timeout("download") }
            let entry: [String: Any]? = try await api("GET", "/torrents/mylist?bypass_cache=true", key: key) { json in
                let list = json["data"] as? [[String: Any]] ?? []
                return list.first { ($0["id"] as? Int) == torrentId }
            }
            guard let e = entry else {
                // mylist can lag a beat behind create on large accounts.
                misses += 1
                if misses >= 3 { throw TorBoxError.api("torrent vanished") }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            misses = 0
            let state = e["download_state"] as? String ?? ""
            let progress = (e["download_progress"] as? NSNumber)?.doubleValue ?? 0
            let finished = e["download_finished"] as? Bool ?? false
            log.info("torbox state=\(state) progress=\(progress)")
            if state == "completed" || state == "cached" || progress >= 1 || finished {
                files = e["files"] as? [[String: Any]] ?? []
                break
            }
            if state.contains("error") {
                throw TorBoxError.api("download \(state)")
            }
            if (state == "dead" || state.hasPrefix("stalled")) && !requeueTried {
                // TorBox's documented remedy for stuck torrents: requeue once.
                requeueTried = true
                log.info("torbox requeue torrent_id=\(torrentId)")
                _ = try? await api("POST", "/torrents/controltorrent", key: key,
                                   form: ["torrent_id": "\(torrentId)", "operation": "requeue"]) { $0 }
            }
            if progress != lastProgress {
                lastProgress = progress
                lastProgressChange = Date()
            } else if Date().timeIntervalSince(lastProgressChange) > 90 {
                throw TorBoxError.stalled("\(state) at \(Int(progress * 100))%")
            }
            onProgress("TorBox: downloading \(Int(progress * 100))%…")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        // 3. Pick the video file. A fileIdx is honored only when it actually
        // points at a video file — Torrentio indexes and TorBox file order
        // disagree on some torrents (a bare index landed on an .nfo before),
        // so otherwise fall back to the largest video file.
        let videoExts = ["mkv", "mp4", "avi", "m4v", "mov", "webm", "ts"]
        func isVideo(_ f: [String: Any]) -> Bool {
            let name = (f["short_name"] as? String ?? f["name"] as? String ?? "").lowercased()
            return videoExts.contains { name.hasSuffix(".\($0)") }
        }
        let videos = files.filter(isVideo)
        let chosen: [String: Any]?
        if let idx = fileIdx, idx < files.count, isVideo(files[idx]) {
            chosen = files[idx]
        } else {
            chosen = videos.max { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }
        }
        guard let file = chosen, let fileId = file["id"] as? Int else { throw TorBoxError.noVideoFile }
        let fileName = file["short_name"] as? String ?? file["name"] as? String ?? ""
        log.info("torbox file: \(fileName) id=\(fileId)")

        // 4. Direct download link. TorBox documents the API key as the
        // `token` query parameter for this endpoint; header-only auth proved
        // flaky live (intermittent 422s), so send BOTH. One retry covers a
        // transient mint failure — every call mints a fresh link anyway.
        onProgress("TorBox: preparing stream…")
        let tokenParam = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        var link: String?
        var lastMintError: Error?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            do {
                link = try await api("GET",
                    "/torrents/requestdl?torrent_id=\(torrentId)&file_id=\(fileId)&redirect=false&token=\(tokenParam)",
                    key: key) { json in
                    guard let url = json["data"] as? String, !url.isEmpty else {
                        throw TorBoxError.api("requestdl returned no link")
                    }
                    return url
                }
                break
            } catch {
                lastMintError = error
                log.error("torbox requestdl attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        guard let link else { throw lastMintError ?? TorBoxError.api("requestdl failed") }
        guard let url = URL(string: link) else { throw TorBoxError.api("bad download link") }
        log.info("torbox stream ready")
        return MintedStream(url: url, fileName: fileName)
    }

    // MARK: - HTTP helper

    private static func api<T>(_ method: String, _ path: String, key: String,
                               form: [String: String]? = nil,
                               decode: ([String: Any]) throws -> T) async throws -> T {
        guard let url = URL(string: base + path) else { throw TorBoxError.api("bad path") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let form {
            let boundary = "Boundary-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for (k, v) in form {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(v)\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TorBoxError.api("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxError.api("bad JSON")
        }
        if json["success"] as? Bool == false {
            let detail = json["detail"] as? String ?? json["error"] as? String ?? "unknown"
            throw TorBoxError.api(detail)
        }
        return try decode(json)
    }
}
