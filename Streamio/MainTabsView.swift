import SwiftUI

struct MainTabsView: View {
    var body: some View {
        TabView {
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            AddonSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.purple)
    }
}
