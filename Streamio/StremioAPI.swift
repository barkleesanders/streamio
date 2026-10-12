import Foundation

enum StremioError: LocalizedError {
    case server(String)
    case badResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .badResponse: return "Unexpected response from server."
        case .transport(let m): return m
        }
    }
}

/// Account API client. Endpoint shapes verified against api.strem.io 2026-10-11:
/// POST /api/login {type:"Login",email,password,facebook:false} -> {result:{authKey,user}} | {error:{message}}
/// POST /api/addonCollectionGet {type:"AddonCollectionGet",authKey,update:true} -> {result:{addons:[...]}}
struct StremioAPI: Sendable {
    static let base = URL(string: "https://api.strem.io/api")!

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: APIError?
    }
    private struct APIError: Decodable { let message: String? }
    private struct LoginResult: Decodable { let authKey: String }
    private struct AddonsResult: Decodable { let addons: [AddonDescriptor] }

    private func call<T: Decodable>(_ method: String, body: [String: Any], as: T.Type) async throws -> T {
        var req = URLRequest(url: Self.base.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw StremioError.transport(error.localizedDescription) }
        guard let env = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { throw StremioError.badResponse }
        if let e = env.error { throw StremioError.server(e.message ?? "Request failed.") }
        guard let r = env.result else { throw StremioError.badResponse }
        return r
    }

    func login(email: String, password: String) async throws -> String {
        let r = try await call("login",
                               body: ["type": "Login", "email": email, "password": password, "facebook": false],
                               as: LoginResult.self)
        return r.authKey
    }

    func getAddonCollection(authKey: String) async throws -> [AddonDescriptor] {
        // TODO(verify): `update:true` asks the server to refresh manifests; confirm against stremio-core if results look stale.
        let r = try await call("addonCollectionGet",
                               body: ["type": "AddonCollectionGet", "authKey": authKey, "update": true],
                               as: AddonsResult.self)
        return r.addons
    }
}
