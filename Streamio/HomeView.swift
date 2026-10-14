import SwiftUI

/// Home tab: search on top, Stremio-Web-style catalog rows below.
/// Tapping any poster opens TitleDetailView (series get the episode picker there).
struct HomeView: View {
    @Environment(WatchStore.self) private var watchStore
    @State private var query = ""
    @State private var results: [StremioMeta] = []
    @State private var searching = false
    @State private var searched = false
    @State private var sections: [CatalogSection] = []
    @State private var loadingCatalogs = true

    private let gridColumns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    /// Poster card width: 110 on iOS; larger on tvOS where the screen is
    /// a 1080p TV across the room.
    private var cardWidth: CGFloat {
        #if os(tvOS)
        return 190
        #else
        return 110
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                homeScroll
                    .searchable(text: $query, prompt: "Movies & series")
                    .onSubmit(of: .search) { Task { await runSearch() } }
                    .onChange(of: query) { _, newValue in
                        if newValue.isEmpty { searched = false; results = [] }
                    }
                #else
                // tvOS: search lives in its own Search tab (SearchView).
                // .searchable here made the keyboard hijack focus at
                // launch and hid the catalog behind a search panel.
                homeScroll
                #endif
            }
            .navigationTitle("Home")
            .navigationDestination(for: StremioMeta.self) { TitleDetailView(meta: $0) }
            .task { await loadCatalogs() }
        }
    }

    private var homeScroll: some View {
            ScrollView {
                if searching {
                    ProgressView().padding(.top, 40)
                } else if searched {
                    if results.isEmpty {
                        Text("No results").foregroundStyle(.secondary).padding(.top, 40)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(results) { meta in
                                NavigationLink(value: meta) { PosterCell(meta: meta) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    catalogRows
                }
            }
    }

    private var catalogRows: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if !watchStore.continueWatching.isEmpty {
                continueWatchingRow
            }
            if loadingCatalogs && sections.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.headline)
                        .padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(section.items) { meta in
                                NavigationLink(value: meta) { PosterCell(meta: meta) }
                                    .buttonStyle(.plain)
                                    .frame(width: cardWidth)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.vertical)
    }

    @ViewBuilder
    private var continueWatchingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching")
                .font(.headline)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(watchStore.continueWatching, id: \.metaId) { rec in
                        NavigationLink(value: StremioMeta(id: rec.metaId, type: rec.type, name: rec.name,
                                                          poster: rec.poster, background: nil,
                                                          description: nil, videos: nil)) {
                            cwCard(rec)
                        }
                        .buttonStyle(.plain)
                        .frame(width: cardWidth)
                        // One tap to playing-at-position (build 19): record
                        // WHICH video to resume; TitleDetailView consumes it
                        // and auto-starts the top-ranked stream there.
                        .simultaneousGesture(TapGesture().onEnded {
                            watchStore.pendingResume = (metaId: rec.metaId, videoId: rec.videoId)
                        })
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func cwCard(_ rec: WatchStore.ProgressRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: rec.poster.flatMap(URL.init(string:))) { img in
                img.resizable().aspectRatio(2/3, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary).aspectRatio(2/3, contentMode: .fit)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.purple)
                        .frame(width: geo.size.width * rec.fraction, height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
            }
            Text(rec.name).font(.caption).lineLimit(2)
            Text("\(formatRemaining(rec.remaining)) left")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func formatRemaining(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }

    private func runSearch() async {        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = (try? await Cinemeta.search(query: q)) ?? []
        searching = false
        searched = true
    }

    private func loadCatalogs() async {
        sections = await Cinemeta.homeSections()
        loadingCatalogs = false
    }
}

struct PosterCell: View {
    let meta: StremioMeta
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: meta.posterURL) { img in
                img.resizable().aspectRatio(2/3, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary).aspectRatio(2/3, contentMode: .fit)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(meta.name).font(.caption).lineLimit(2)
        }
    }
}
