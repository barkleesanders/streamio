import Foundation

/// Debrid provider configuration, stored in the iOS Keychain.
/// When configured, Torrentio is queried through a Debrid-enabled manifest URL,
/// which returns cached direct-https streams (no P2P needed). The built-in
/// torrent client stays as fallback when Debrid is unconfigured or a title
/// isn't cached. Playback priority: Debrid → torrent client → direct https.
enum DebridProvider: String, CaseIterable, Identifiable {
    case torbox = "Torbox"
    case realDebrid = "Real-Debrid"
    case allDebrid = "AllDebrid"
    case premiumize = "Premiumize"
    case debridLink = "Debrid-Link"

    var id: String { rawValue }

    /// URL slug used in Torrentio's configured manifest URL.
    var urlSlug: String {
        switch self {
        case .torbox: return "torbox"
        case .realDebrid: return "realdebrid"
        case .allDebrid: return "alldebrid"
        case .premiumize: return "premiumize"
        case .debridLink: return "debridlink"
        }
    }
}

enum DebridConfig {
    private static let providerKey = "streamio.debrid.provider"
    private static let apiKeyKey = "streamio.debrid.key"
    private static let preferDebridKey = "streamio.debrid.prefer"

    private static let torrentioProviders =
        "yts,eztv,rarbg,1337x,thepiratebay,kickasstorrents,torrentgalaxy," +
        "magnetdl,horriblesubs,nyaasi,tokyotosho,anidex"

    static var provider: DebridProvider? {
        get { Keychain.get(providerKey).flatMap(DebridProvider.init(rawValue:)) }
    }

    static var apiKey: String? {
        get {
            guard let k = Keychain.get(apiKeyKey), !k.isEmpty else { return nil }
            return k
        }
    }

    static var isConfigured: Bool { provider != nil && apiKey != nil }

    /// Barklee's source toggle: when true (default) and a key is configured,
    /// Debrid-cached streams go first. When false, the built-in torrent client
    /// is preferred even with a key saved. Both playback paths stay permanently.
    static var preferDebrid: Bool {
        get { Keychain.get(preferDebridKey) != "0" }
        set { Keychain.set(newValue ? "1" : "0", for: preferDebridKey) }
    }

    /// Debrid is actually used only when the toggle is on AND a key is saved.
    static var debridActive: Bool { isConfigured && preferDebrid }

    static func save(provider: DebridProvider, apiKey: String) {
        Keychain.set(provider.rawValue, for: providerKey)
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyKey)
    }

    static func clear() {
        Keychain.delete(providerKey)
        Keychain.delete(apiKeyKey)
    }

    /// Configured Torrentio manifest URL, or nil when Debrid isn't set up.
    /// Verified URL format against torrentio.strem.fun/configure.
    static func torrentioManifestURL() -> URL? {
        guard let p = provider, let key = apiKey else { return nil }
        let s = "https://torrentio.strem.fun/\(torrentioProviders)" +
            "|debrid=\(p.urlSlug)|\(p.urlSlug)=\(key)/manifest.json"
        return URL(string: s)
    }

    /// AddonDescriptor for the Debrid-enabled Torrentio instance.
    static func debridAddon() -> AddonDescriptor? {
        guard let url = torrentioManifestURL() else { return nil }
        return AddonDescriptor(
            transportUrl: url.absoluteString,
            manifest: AddonManifest(
                id: "com.stremio.torrentio.debrid",
                name: "Torrentio (Debrid)",
                version: nil,
                types: ["movie", "series", "anime"],
                resources: [AddonManifest.ResourceDescriptor(name: "stream")]
            )
        )
    }
}
