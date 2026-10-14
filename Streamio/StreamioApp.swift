import SwiftUI

@MainActor
@Observable
final class Session {
    var authKey: String? = Keychain.get(Keychain.authKeyKey)
    var addons: [AddonDescriptor] = []
    var isLoggedIn: Bool { authKey != nil }

    init() {
        #if DEBUG
        // Simulator crash-repro bypass: SIMCTL_CHILD_STREAMIO_SKIP_LOGIN=1 xcrun simctl launch ...
        // Stripped from release builds; TestFlight builds are unaffected.
        if authKey == nil, ProcessInfo.processInfo.environment["STREAMIO_SKIP_LOGIN"] != nil {
            authKey = "debug-skip-login"
        }
        #endif
    }

    /// Account collection when logged in and loaded; otherwise the verified real defaults.
    var effectiveAddons: [AddonDescriptor] { addons.isEmpty ? RealAddons.all : addons }

    func signIn(email: String, password: String) async throws {
        let key = try await StremioAPI().login(email: email, password: password)
        Keychain.set(key, for: Keychain.authKeyKey)
        Keychain.set(email, for: Keychain.emailKey)
        authKey = key
        await refreshAddons()
    }

    func refreshAddons() async {
        guard let key = authKey else { return }
        addons = (try? await StremioAPI().getAddonCollection(authKey: key)) ?? []
    }

    func signOut() {
        Keychain.delete(Keychain.authKeyKey)
        Keychain.delete(Keychain.emailKey)
        authKey = nil
        addons = []
    }
}

@main
struct StreamioApp: App {
    @State private var session = Session()
    @State private var watchStore = WatchStore()

    init() {
        #if DEBUG
        // Simulator verification hook: SIMCTL_CHILD_STREAMIO_TORRENT_TEST=<infohash> xcrun simctl launch --console ...
        if let hash = ProcessInfo.processInfo.environment["STREAMIO_TORRENT_TEST"] {
            Task.detached { await TorrentSelfTest.run(infoHash: hash) }
        }
        if let hash = ProcessInfo.processInfo.environment["STREAMIO_TORRENT_CYCLE"] {
            Task.detached { await TorrentSelfTest.runCycle(infoHash: hash) }
        }
        if let hash = ProcessInfo.processInfo.environment["STREAMIO_TORRENT_SCRUB"] {
            Task.detached { await TorrentSelfTest.runScrub(infoHash: hash) }
        }
        if let hash = ProcessInfo.processInfo.environment["STREAMIO_TORRENT_MATRIX"] {
            Task.detached { await TorrentSelfTest.runMatrix(infoHash: hash) }
        }
        if let hash = ProcessInfo.processInfo.environment["STREAMIO_TORRENT_CYCLES19"] {
            Task.detached { await TorrentSelfTest.runCycles19(infoHash: hash) }
        }
        if let hash = ProcessInfo.processInfo.environment["STREAMIO_TORRENT_COLDSCRUB19"] {
            Task.detached { await TorrentSelfTest.runColdScrub19(infoHash: hash) }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // Simulator overlay-toggle verification hook:
                // SIMCTL_CHILD_STREAMIO_PLAYER_TEST=test.mp4 — plays the
                // named file from the app's Documents dir in the bare VLC
                // player so the tap toggle cycle can be driven end-to-end.
                // Stripped from release builds; TestFlight is unaffected.
                if let name = ProcessInfo.processInfo.environment["STREAMIO_PLAYER_TEST"],
                   let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    VLCPlayerView(url: docs.appendingPathComponent(name),
                                  errorMessage: .constant(nil))
                } else if session.isLoggedIn {
                    MainTabsView()
                        .task { await session.refreshAddons() }
                } else {
                    LoginView()
                }
                #else
                if session.isLoggedIn {
                    MainTabsView()
                        .task { await session.refreshAddons() }
                } else {
                    LoginView()
                }
                #endif
            }
            .environment(session)
            .environment(watchStore)
            .preferredColorScheme(.dark)
        }
    }
}
