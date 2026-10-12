import SwiftUI

struct AddonSettingsView: View {
    @Environment(Session.self) private var session

    var body: some View {
        NavigationStack {
            List {
                Section("Addons") {
                    ForEach(session.effectiveAddons) { addon in
                        NavigationLink(addon.manifest.name) { AddonConfigEditor(addon: addon) }
                    }
                }
                Section("Account") {
                    if let email = Keychain.get(Keychain.emailKey) { Text(email).foregroundStyle(.secondary) }
                    Button("Sign out", role: .destructive) { session.signOut() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct AddonConfigEditor: View {
    let addon: AddonDescriptor
    @State private var text = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("API key / config JSON") {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button(saved ? "Saved" : "Save") {
                if text.isEmpty { Keychain.delete(Keychain.addonConfigKey(addon.manifest.id)) }
                else { Keychain.set(text, for: Keychain.addonConfigKey(addon.manifest.id)) }
                saved = true
            }
        }
        .navigationTitle(addon.manifest.name)
        .onAppear { text = Keychain.get(Keychain.addonConfigKey(addon.manifest.id)) ?? "" }
        .onChange(of: text) { saved = false }
    }
}
