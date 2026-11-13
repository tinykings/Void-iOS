import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var tab = Tab.playlist

    enum Tab: Hashable { case playlist, history, stream, deals, search }

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(list: .playlist)
                .tabItem { Label("Playlist", systemImage: "list.bullet.rectangle") }
                .tag(Tab.playlist)
            LibraryView(list: .history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            if store.enabledTypes.contains(.movie) || store.enabledTypes.contains(.tv) {
                StreamView()
                    .tabItem { Label("Stream", systemImage: "play.tv") }
                    .tag(Tab.stream)
            }
            if store.enabledTypes.contains(.game) {
                DealsView()
                    .tabItem { Label("Deals", systemImage: "tag") }
                    .tag(Tab.deals)
            }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
        }
        .onChange(of: store.enabledTypes) { _, types in
            if tab == .deals && !types.contains(.game) { tab = .playlist }
            if tab == .stream && !types.contains(.movie) && !types.contains(.tv) { tab = .playlist }
        }
    }
}
