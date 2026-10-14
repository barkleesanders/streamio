import Foundation

struct Peer: Hashable, Sendable {
    let host: String
    let port: UInt16
}

/// Tracker announce: HTTP(S) (BEP 3 + compact BEP 23) and UDP (BEP 15,
/// see UDPTracker.swift). The magnet's own trackers are the primary list;
/// the defaults are a fallback floor.
/// Verified live 2026-10-11 (HTTP): opentrackr:1337 and dler:6969 answered
/// with peers; openbittorrent.com 403, bt4g CF error 1200. UDP measured
/// Oct 2026: the Lanterns S1E8 magnet lists 18 UDP-only hosts vs 8 HTTP;
/// explodie.org / nyaa.vc / open.stealth.si answered a BEP 15 probe with
/// real peers — reachable only via UDP.
enum TrackerClient {
    static let trackers = [
        "http://tracker.opentrackr.org:1337/announce",
        "http://tracker.dler.org:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.nyaa.vc:6969/announce",
        "udp://open.stealth.si:80/announce",
    ]

    /// Announces to all trackers in parallel; returns deduplicated peers. Throws `.trackerUnreachable`
    /// only if every tracker failed at transport/parse level; returns [] if trackers answered with no peers.
    /// - Parameter extraTrackers: tracker URLs from the magnet link itself (build 19; UDP since build 23).
    ///   The magnet's own list is how Stremio finds the swarm; the defaults stay as a fallback floor.
    static func announce(infoHash: Data, peerID: Data, port: UInt16 = 6881, timeout: TimeInterval = 8,
                         extraTrackers: [String] = []) async throws -> [Peer] {
        var all = trackers
        for t in extraTrackers {
            let lt = t.lowercased()
            guard lt.hasPrefix("http://") || lt.hasPrefix("https://") || lt.hasPrefix("udp://") else { continue }
            let normalized = t.trimmingCharacters(in: .whitespaces)
            if !all.contains(normalized) { all.append(normalized) }
            if all.count >= 24 { break }
        }
        let encodedHash = infoHash.map { String(format: "%%%02x", $0) }.joined()
        let encodedID = peerID.map { String(format: "%%%02x", $0) }.joined()
        var answered = false
        var peers = Set<Peer>()
        await withTaskGroup(of: [Peer]?.self) { g in
            for t in all {
                if t.lowercased().hasPrefix("udp://") {
                    g.addTask {
                        await UDPTracker.announce(tracker: t, infoHash: infoHash, peerID: peerID, port: port, timeout: timeout)
                    }
                } else {
                    g.addTask {
                        guard let url = URL(string: "\(t)?info_hash=\(encodedHash)&peer_id=\(encodedID)&port=\(port)&uploaded=0&downloaded=0&left=1&compact=1&numwant=60&event=started") else { return nil }
                        var req = URLRequest(url: url)
                        req.timeoutInterval = timeout
                        req.setValue("Streamio/1.0", forHTTPHeaderField: "User-Agent")
                        guard let (data, resp) = try? await URLSession.shared.data(for: req),
                              (resp as? HTTPURLResponse)?.statusCode == 200,
                              let (root, _) = try? Bencode.decode(data), root.dict != nil,
                              root["failure reason"] == nil else { return nil }
                        return parseCompact(root["peers"]?.data)
                    }
                }
            }
            for await r in g {
                if let r { answered = true; peers.formUnion(r) }
            }
        }
        guard answered else { throw TorrentError.trackerUnreachable }
        var out = Array(peers)
        #if DEBUG
        // Simulator test-rig seam: STREAMIO_EXTRA_PEER=host:port injects a
        // deterministic local peer (e.g. a LAN seeder that public trackers
        // cannot route to from inside the LAN). Debug builds only.
        if let spec = ProcessInfo.processInfo.environment["STREAMIO_EXTRA_PEER"],
           let colon = spec.lastIndex(of: ":"),
           let port = UInt16(spec[spec.index(after: colon)...]) {
            let extra = Peer(host: String(spec[..<colon]), port: port)
            out.removeAll { $0 == extra }
            out.insert(extra, at: 0)
        }
        #endif
        return out
    }

    static func parseCompact(_ d: Data?) -> [Peer] {
        guard let d, d.count >= 6 else { return [] }
        let b = [UInt8](d)
        return stride(from: 0, to: b.count - 5, by: 6).map { i in
            Peer(host: "\(b[i]).\(b[i+1]).\(b[i+2]).\(b[i+3])", port: UInt16(b[i+4]) << 8 | UInt16(b[i+5]))
        }.filter { $0.port != 0 }
    }
}
