import SwiftUI

/// tvOS Search tab. tvOS convention is a dedicated search tab; putting
/// `.searchable` on Home (the iOS pattern) made the keyboard hijack focus
/// at launch and hid the catalog behind a search panel. Only added to the
/// tab bar on tvOS (see MainTabsView); compiles on iOS but is unused there.
struct SearchView: View {
    @State private var query = ""
    @State private var results: [StremioMeta] = []
    @State private var searching = false
    @State private var searched = false

    private let gridColumns = [GridItem(.adaptive(minimum: 190), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if searching {
                    ProgressView().padding(.top, 60)
                } else if searched {
                    if results.isEmpty {
                        Text("No results").foregroundStyle(.secondary).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            ForEach(results) { meta in
                                NavigationLink(value: meta) { PosterCell(meta: meta) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: StremioMeta.self) { TitleDetailView(meta: $0) }
            .searchable(text: $query, prompt: "Movies & series")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { searched = false; results = [] }
            }
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = (try? await Cinemeta.search(query: q)) ?? []
        searching = false
        searched = true
    }
}
