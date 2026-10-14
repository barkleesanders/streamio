import Foundation

/// A named catalog row on the Home screen (mirrors Stremio Web's Discover rows).
struct CatalogSection: Identifiable, Sendable {
    let title: String
    let items: [StremioMeta]
    var id: String { title }
}

enum Cinemeta {
    static let base = "https://v3-cinemeta.strem.io"

    private static func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        guard let url = URL(string: base + path) else { throw StremioError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func search(query: String) async throws -> [StremioMeta] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        async let movies = get("/catalog/movie/top/search=\(q).json", as: CatalogResponse.self)
        async let series = get("/catalog/series/top/search=\(q).json", as: CatalogResponse.self)
        let m = (try? await movies.metas) ?? []
        let s = (try? await series.metas) ?? []
        return m + s
    }

    static func getMeta(type: String, id: String) async throws -> StremioMeta {
        try await get("/meta/\(type)/\(id).json", as: MetaResponse.self).meta
    }

    /// Raw catalog fetch: /catalog/{type}/{id}.json (ids from the Cinemeta manifest).
    static func catalog(type: String, id: String) async throws -> [StremioMeta] {
        try await get("/catalog/\(type)/\(id).json", as: CatalogResponse.self).metas
    }

    /// Home-page rows, fetched in parallel. Never throws — a failed catalog
    /// yields an empty row that the UI drops.
    static func homeSections() async -> [CatalogSection] {
        let defs: [(title: String, type: String, id: String)] = [
            ("Popular Movies", "movie", "top"),
            ("Popular Series", "series", "top"),
            ("New Movies", "movie", "year"),
            ("New Series", "series", "year"),
            ("Featured Movies", "movie", "imdbRating"),
            ("Featured Series", "series", "imdbRating"),
        ]
        let indexed = await withTaskGroup(of: (Int, CatalogSection).self) { group in
            for (i, def) in defs.enumerated() {
                group.addTask {
                    let items = (try? await catalog(type: def.type, id: def.id)) ?? []
                    return (i, CatalogSection(title: def.title, items: items))
                }
            }
            var out: [(Int, CatalogSection)] = []
            for await r in group { out.append(r) }
            return out
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.items.isEmpty }
    }
}
