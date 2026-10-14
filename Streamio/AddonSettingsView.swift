import SwiftUI

struct AddonSettingsView: View {
    @Environment(Session.self) private var session
    @State private var preferDebrid = DebridConfig.preferDebrid
    @State private var audioLang = PlaybackPrefs.audioLanguage
    @State private var subLang = PlaybackPrefs.subtitleLanguage

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    Picker("Audio Language", selection: $audioLang) {
                        ForEach(PlaybackPrefs.languages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .onChange(of: audioLang) { _, v in PlaybackPrefs.audioLanguage = v }
                    Picker("Subtitle Language", selection: $subLang) {
                        Text("Off").tag("off")
                        ForEach(PlaybackPrefs.languages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .onChange(of: subLang) { _, v in PlaybackPrefs.subtitleLanguage = v }
                }
                Section("Debrid") {
                    Toggle("Prefer Debrid", isOn: $preferDebrid)
                        .onChange(of: preferDebrid) { _, v in DebridConfig.preferDebrid = v }
                    NavigationLink {
                        DebridSettingsView()
                    } label: {
                        Label {
                            if DebridConfig.isConfigured, let p = DebridConfig.provider {
                                Text("Connected: \(p.rawValue)")
                            } else {
                                Text("Not configured")
                            }
                        } icon: {
                            Image(systemName: DebridConfig.isConfigured ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(DebridConfig.isConfigured ? .green : .secondary)
                        }
                    }
                }
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
            .onAppear {
                preferDebrid = DebridConfig.preferDebrid
                audioLang = PlaybackPrefs.audioLanguage
                subLang = PlaybackPrefs.subtitleLanguage
            }
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
                #if os(tvOS)
                // TextEditor does not exist on tvOS; a vertical-axis
                // TextField opens the full-screen remote keyboard editor,
                // which handles long keys/JSON fine.
                TextField("API key / config JSON", text: $text, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                #else
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
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
