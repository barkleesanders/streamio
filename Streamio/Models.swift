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
    /// v1 only plays direct https URLs.
    var playableURL: URL? {
        guard let url, let u = URL(string: url), u.scheme?.lowercased() == "https" else { return nil }
        return u
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
