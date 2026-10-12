import SwiftUI

@MainActor
@Observable
final class Session {
    var authKey: String? = Keychain.get(Keychain.authKeyKey)
    var addons: [AddonDescriptor] = []
    var isLoggedIn: Bool { authKey != nil }

    /// Real collection when logged in and loaded; otherwise the mock list.
    var effectiveAddons: [AddonDescriptor] { addons.isEmpty ? MOCK_ADDONS : addons }

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

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isLoggedIn {
                    MainTabsView()
                        .task { await session.refreshAddons() }
                } else {
                    LoginView()
                }
            }
            .environment(session)
            .preferredColorScheme(.dark)
        }
    }
}
