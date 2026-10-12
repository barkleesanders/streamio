import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Continue watching").font(.title2.bold())
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nothing here yet").font(.headline)
                        Text("Library sync is coming in a later update.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    NavigationLink {
                        SearchView()
                    } label: {
                        Label("Search titles", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity).padding()
                            .background(.purple, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                }
                .padding()
            }
            .navigationTitle("Library")
        }
    }
}
