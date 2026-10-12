import SwiftUI

struct AddonStreams: Identifiable {
    let addon: AddonDescriptor
    var streams: [StremioStream]
    var failed: Bool
    var id: String { addon.id }
}

struct TitleDetailView: View {
    @Environment(Session.self) private var session
    let meta: StremioMeta

    @State private var full: StremioMeta?
    @State private var selectedSeason: Int = 1
    @State private var selectedVideo: MetaVideo?
    @State private var groups: [AddonStreams] = []
    @State private var loading = false
    @State private var playURL: URL?
    @State private var unsupported = false

    private var current: StremioMeta { full ?? meta }
    private var isSeries: Bool { current.type == "series" }
    private var seasons: [Int] {
        Array(Set((current.videos ?? []).compactMap(\.season).filter { $0 > 0 })).sorted()
    }
    private var episodes: [MetaVideo] {
        (current.videos ?? []).filter { $0.season == selectedSeason }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: current.backgroundURL ?? current.posterURL) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                    .frame(height: 220).clipped()
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.name).font(.title.bold())
                    if let d = current.description { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                    if isSeries { episodePicker }
                    streamList
                }.padding(.horizontal)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMeta() }
        .fullScreenCover(item: $playURL) { PlayerView(url: $0).ignoresSafeArea() }
        .alert("Not supported in v1", isPresented: $unsupported) {
            Button("OK", role: .cancel) {}
        } message: { Text("Only direct https streams can be played. Torrent (infoHash) and YouTube streams are not supported yet.") }
    }

    @ViewBuilder private var episodePicker: some View {
        if !seasons.isEmpty {
            Picker("Season", selection: $selectedSeason) {
                ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) }
            }.pickerStyle(.menu)
            ForEach(episodes) { ep in
                Button {
                    selectedVideo = ep
                    Task { await loadStreams(videoId: ep.id) }
                } label: {
                    HStack {
                        Text("\(ep.episode ?? 0). \(ep.displayTitle)").lineLimit(1)
                        Spacer()
                        if selectedVideo?.id == ep.id { Image(systemName: "checkmark").foregroundStyle(.purple) }
                    }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var streamList: some View {
        if isSeries && selectedVideo == nil {
            Text("Pick an episode to load streams.").font(.footnote).foregroundStyle(.secondary)
        } else if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(g.addon.manifest.name).font(.headline)
                    if g.failed {
                        Text("Couldn't reach this addon.").font(.footnote).foregroundStyle(.secondary)
                    } else if g.streams.isEmpty {
                        Text("No streams.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(g.streams) { s in
                        Button {
                            if let u = s.playableURL { playURL = u } else { unsupported = true }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if let n = s.name { Text(n).font(.caption).foregroundStyle(.purple) }
                                Text(s.displayTitle).font(.subheadline).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func loadMeta() async {
        if let m = try? await Cinemeta.getMeta(type: meta.type, id: meta.id) {
            full = m
            if let first = (m.videos ?? []).compactMap(\.season).filter({ $0 > 0 }).min() { selectedSeason = first }
        }
        if !isSeries { await loadStreams(videoId: meta.id) }
    }

    private func loadStreams(videoId: String) async {
        loading = true
        let addons = session.effectiveAddons
        let type = meta.type
        let results = await withTaskGroup(of: AddonStreams.self) { group in
            for a in addons {
                group.addTask {
                    do { return AddonStreams(addon: a, streams: try await AddonClient(addon: a).getStreams(type: type, id: videoId), failed: false) }
                    catch { return AddonStreams(addon: a, streams: [], failed: true) }
                }
            }
            var out: [AddonStreams] = []
            for await r in group { out.append(r) }
            return out
        }
        groups = addons.compactMap { a in results.first { $0.addon.id == a.id } }
        loading = false
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
