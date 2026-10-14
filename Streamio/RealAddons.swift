import Foundation

/// Verified real addon descriptors (each manifest returned HTTP 200 on 2026-10-11).
/// MediaFusion / Sportsurge / WatchHub are intentionally absent: their URLs are not verified.
enum RealAddons {
    private static func make(_ id: String, _ name: String, _ url: String, types: [String], resources: [String]) -> AddonDescriptor {
        AddonDescriptor(
            transportUrl: url,
            manifest: AddonManifest(id: id, name: name, version: nil, types: types, resources: resources.map(AddonManifest.ResourceDescriptor.init(name:))))
    }

    /// LAN-only (home network). Probed on-device; skipped silently when unreachable.
    static let autoBest = make("lan.autobest", "Auto Best", "http://10.0.0.213:7048/f447f018edfba8948/manifest.json",
                               types: ["movie", "series"], resources: ["stream"])
    static let torrentio = make("com.stremio.torrentio.addon", "Torrentio", "https://torrentio.strem.fun/manifest.json",
                                types: ["movie", "series", "anime"], resources: ["stream"])
    static let tpbPlus = make("org.thepiratebay.plus", "ThePirateBay+", "https://thepiratebay-plus.strem.fun/manifest.json",
                              types: ["movie", "series"], resources: ["stream"])
    static let youtube = make("youtube.channels", "YouTube", "https://v3-channels.strem.io/manifest.json",
                              types: ["channel"], resources: ["stream"])
    static let publicDomain = make("org.publicdomainmovies", "Public Domain Movies", "https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json",
                                   types: ["movie"], resources: ["stream"])
    static let openSubtitles = make("org.stremio.opensubtitlesv3", "OpenSubtitles v3", "https://opensubtitles-v3.strem.io/manifest.json",
                                    types: ["movie", "series"], resources: ["subtitles"])
    static let cinemeta = make("com.linvo.cinemeta", "Cinemeta", "https://v3-cinemeta.strem.io/manifest.json",
                               types: ["movie", "series"], resources: ["catalog", "meta"])

    /// Playback priority for movies/series: Auto Best (if reachable) -> Torrentio -> TPB+ ; then fallbacks.
    /// Debrid-cached streams first when configured, then the built-in torrent
    /// client path (Torrentio/TPB+ via P2P), then direct https fallbacks.
    static var all: [AddonDescriptor] {
        var list = [autoBest, torrentio, tpbPlus, publicDomain, youtube, openSubtitles, cinemeta]
        if DebridConfig.debridActive, let debrid = DebridConfig.debridAddon() {
            list.insert(debrid, at: 0)
        }
        return list
    }

    static func offersStreams(_ a: AddonDescriptor) -> Bool {
        guard let r = a.manifest.resources else { return true }
        return r.contains { $0.name == "stream" }
    }

    static func isLAN(_ a: AddonDescriptor) -> Bool {
        guard let h = URL(string: a.transportUrl)?.host else { return false }
        return h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("172.16.") || h.hasSuffix(".local")
    }

    /// Quick GET of /manifest.json with a 3 s timeout.
    static func isReachable(_ a: AddonDescriptor) async -> Bool {
        guard let url = URL(string: a.baseURL + "/manifest.json") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Stream-capable addons in priority order; unreachable LAN addons dropped (probes run in parallel).
    static func streamAddons(from addons: [AddonDescriptor]) async -> [AddonDescriptor] {
        let candidates = addons.filter(offersStreams)
        let ok: [Bool] = await withTaskGroup(of: (Int, Bool).self) { g in
            for (i, a) in candidates.enumerated() {
                g.addTask { (i, isLAN(a) ? await isReachable(a) : true) }
            }
            var out = [Bool](repeating: true, count: candidates.count)
            for await (i, v) in g { out[i] = v }
            return out
        }
        return zip(candidates, ok).filter(\.1).map(\.0)
    }
}
