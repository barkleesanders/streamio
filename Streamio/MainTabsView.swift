import SwiftUI

struct MainTabsView: View {
    #if DEBUG
    @State private var vlcTestURL: URL? = {
        if let s = ProcessInfo.processInfo.environment["STREAMIO_VLC_TEST"],
           let u = URL(string: s) { return u }
        return nil
    }()
    #endif

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house") }
            #if os(tvOS)
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            #endif
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }
            AddonSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.purple)
        #if DEBUG
        .fullScreenCover(item: $vlcTestURL) { url in
            VLCPlayerView(url: url, errorMessage: .constant(nil)).ignoresSafeArea()
        }
        #endif
    }
}
