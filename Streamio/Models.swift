import Foundation

struct MetaVideo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let name: String?
    let season: Int?
    let episode: Int?
    let released: String?

    var displayTitle: String { title ?? name ?? id }
}

struct StremioMeta: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let description: String?
    let videos: [MetaVideo]?

    var posterURL: URL? { poster.flatMap(URL.init(string:)) }
    var backgroundURL: URL? { background.flatMap(URL.init(string:)) }
}

struct BehaviorHints: Codable, Hashable, Sendable {
    let notWebReady: Bool?
    let filename: String?
}

struct StremioStream: Codable, Identifiable, Hashable, Sendable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?
    let ytId: String?
    let infoHash: String?
    let fileIdx: Int?
    let behaviorHints: BehaviorHints?

    var id: String { url ?? infoHash ?? ytId ?? "\(name ?? "")|\(title ?? description ?? "")" }
    var displayTitle: String { title ?? description ?? name ?? "Stream" }
    /// Direct https URLs play straight in AVPlayer.
    var playableURL: URL? {
        guard let url, let u = URL(string: url), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }
}

extension StremioStream {
    var isTorrent: Bool { infoHash.map { !$0.isEmpty } ?? false }
    /// Opens in the YouTube app via URL scheme (web URL fallback handled by the caller).
    var youTubeAppURL: URL? { ytId.flatMap { URL(string: "youtube://www.youtube.com/watch?v=\($0)") } }
    var youTubeWebURL: URL? { ytId.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") } }

    /// Tracker URLs carried by a magnet link in `url` (its `tr=` params,
    /// percent-decoded). Builds ≤18 dropped these on the floor: the stream
    /// model kept only the infoHash, so the engine announced to two
    /// hardcoded HTTP trackers and nothing else — the magnet's own tracker
    /// list, which is how Stremio itself finds the swarm, never reached it.
    var magnetTrackers: [String] {
        guard let url, url.hasPrefix("magnet:") else { return [] }
        guard let q = url.split(separator: "?", maxSplits: 1).last else { return [] }
        var out: [String] = []
        for pair in q.split(separator: "&") {
            guard pair.hasPrefix("tr=") else { continue }
            let raw = String(pair.dropFirst(3))
            if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                out.append(decoded)
            }
        }
        return out
    }
}

struct StreamsResponse: Codable, Sendable {
    let streams: [StremioStream]
}

struct CatalogResponse: Codable, Sendable {
    let metas: [StremioMeta]
}

struct MetaResponse: Codable, Sendable {
    let meta: StremioMeta
}

struct AddonManifest: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String?
    let types: [String]?
    /// Resources may be strings ("stream") or objects ({name:"stream",...}); decoded leniently.
    let resources: [ResourceDescriptor]?

    struct ResourceDescriptor: Codable, Hashable, Sendable {
        let name: String
        init(name: String) { self.name = name }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { name = s; return }
            struct Obj: Decodable { let name: String }
            name = try c.decode(Obj.self).name
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(name)
        }
    }
}

struct AddonDescriptor: Codable, Identifiable, Hashable, Sendable {
    let transportUrl: String
    let manifest: AddonManifest
    var id: String { transportUrl }

    /// Base URL with the trailing `/manifest.json` removed.
    var baseURL: String {
        var s = transportUrl
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        return s
    }
}
