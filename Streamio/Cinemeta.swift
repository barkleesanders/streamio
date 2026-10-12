import Foundation

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
}
