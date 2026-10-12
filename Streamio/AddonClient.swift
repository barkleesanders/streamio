import Foundation

struct AddonClient: Sendable {
    let addon: AddonDescriptor

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        guard let url = URL(string: addon.baseURL + path) else { throw StremioError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StremioError.server("Addon returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchManifest() async throws -> AddonManifest {
        try await get("/manifest.json", as: AddonManifest.self)
    }

    func getStreams(type: String, id: String) async throws -> [StremioStream] {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await get("/stream/\(type)/\(enc).json", as: StreamsResponse.self).streams
    }
}
