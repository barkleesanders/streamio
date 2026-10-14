import SwiftUI

struct LibraryView: View {
    @Environment(WatchStore.self) private var watchStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recently watched").font(.title2.bold())
                    if watchStore.recent.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Nothing here yet").font(.headline)
                            Text("Things you watch will show up here.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        ForEach(watchStore.recent.prefix(30), id: \.0) { item in
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: item.1.poster ?? "")) { img in
                                    img.resizable().aspectRatio(2/3, contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(.quaternary).aspectRatio(2/3, contentMode: .fit)
                                }
                                .frame(width: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.1.name).font(.subheadline).lineLimit(2)
                                    Text(item.1.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                            }
                            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    NavigationLink {
                        HomeView()
                    } label: {
                        Label("Browse titles", systemImage: "magnifyingglass")
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
