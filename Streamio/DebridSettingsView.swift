import SwiftUI

/// Dedicated Debrid settings: provider picker + API key stored in the Keychain.
/// When configured, Debrid-cached streams are preferred; the built-in torrent
/// client remains as fallback. Both playback paths stay permanently.
struct DebridSettingsView: View {
    @State private var provider: DebridProvider = .torbox
    @State private var apiKey: String = ""
    @State private var saved = false
    @State private var showKey = false
    @State private var preferDebrid = DebridConfig.preferDebrid

    var body: some View {
        Form {
            Section {
                Toggle("Prefer Debrid", isOn: $preferDebrid)
                    .onChange(of: preferDebrid) { _, v in DebridConfig.preferDebrid = v }
            } footer: {
                Text("On: Debrid-cached streams first, torrent as fallback. Off: built-in torrent client first. Both paths stay available.")
            }

            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(DebridProvider.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
            } footer: {
                Text("Cached Debrid streams play first when available. The built-in torrent client stays as fallback.")
            }

            Section("API key") {
                if showKey {
                    TextField("Paste API key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    SecureField("Paste API key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("Show key", isOn: $showKey)
            }

            Section {
                Button(saved ? "Saved" : "Save") {
                    DebridConfig.save(provider: provider, apiKey: apiKey)
                    saved = true
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if DebridConfig.isConfigured {
                    Button("Remove Debrid", role: .destructive) {
                        DebridConfig.clear()
                        apiKey = ""
                        saved = false
                    }
                }
            }

            if DebridConfig.isConfigured, let p = DebridConfig.provider {
                Section("Status") {
                    Label("Connected: \(p.rawValue)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Debrid")
        .onAppear {
            if let p = DebridConfig.provider { provider = p }
            apiKey = DebridConfig.apiKey ?? ""
        }
        .onChange(of: apiKey) { saved = false }
        .onChange(of: provider) { saved = false }
    }
}
