import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [StremioMeta] = []
    @State private var searching = false
    @State private var searched = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if searching { ProgressView().padding(.top, 40) }
                else if searched && results.isEmpty { Text("No results").foregroundStyle(.secondary).padding(.top, 40) }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(results) { meta in
                        NavigationLink(value: meta) { PosterCell(meta: meta) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Search")
            .navigationDestination(for: StremioMeta.self) { TitleDetailView(meta: $0) }
            .searchable(text: $query, prompt: "Movies & series")
            .onSubmit(of: .search) { Task { await run() } }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = (try? await Cinemeta.search(query: q)) ?? []
        searching = false; searched = true
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
