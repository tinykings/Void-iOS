import SwiftUI

// TMDB recommendations remain grouped by the favorite that suggested them.
struct RecommendationsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var groups: [Group] = []
    @State private var loading = false
    @State private var failed = false
    @State private var requestID = UUID()

    private struct Group: Identifiable {
        let seed: SyncedItem
        let titles: [Media]
        var id: MediaKey { seed.key }
    }

    private var favorites: [SyncedItem] {
        store.entries(.history, type: nil).filter { $0.isFavorite && $0.key.type != .game }
    }

    private var visibleGroups: [Group] {
        var seen = Set((store.library.list(.history) + store.library.list(.playlist)).map(\.key))
        return groups.compactMap { group in
            let titles = group.titles.filter { seen.insert($0.key).inserted }
            return titles.isEmpty ? nil : Group(seed: group.seed, titles: titles)
        }
    }

    var body: some View {
        List {
            Section {
                Text("Movies and shows inspired by your Favorites, excluding titles already in your library. Game recommendations aren't available yet.")
                    .font(.caption).foregroundStyle(Color.voidSilver)
            }.listRowBackground(Color.clear)

            if favorites.isEmpty {
                Text("Favorite movies or shows in History to get recommendations.")
                    .foregroundStyle(Color.voidSilver).listRowBackground(Color.voidSurface)
            }
            ForEach(visibleGroups) { group in
                Section("Because you favorited \(group.seed.title)") {
                    ForEach(group.titles, id: \.key) { media in
                        MediaLink(media: media) {
                            HStack(spacing: 12) {
                                PosterImage(path: media.posterPath, size: "w185")
                                    .frame(width: 36, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(media.title).font(.subheadline.weight(.semibold))
                                    Text([media.mediaType.singular, media.year].compactMap { $0 }.joined(separator: " · "))
                                        .font(.voidLabel).foregroundStyle(Color.voidSilver)
                                }
                            }
                        }.listRowBackground(Color.voidSurface)
                    }
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if !favorites.isEmpty && visibleGroups.isEmpty && !failed {
                Text("No new recommendations right now. Try adding more Favorites.")
                    .foregroundStyle(Color.voidSilver).listRowBackground(Color.clear)
            }
            if failed {
                Section {
                    Text("Some recommendations couldn't load.").foregroundStyle(Color.voidSilver)
                    Button("Try again") { Task { await load() } }.disabled(loading)
                }.listRowBackground(Color.voidSurface)
            }
        }
        .navigationTitle("Recommendations")
        .task(id: favorites.map(\.key)) { await load() }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        let request = UUID()
        requestID = request
        loading = true
        failed = false
        groups = []
        for seed in favorites {
            do {
                let titles = try await store.api.recommendations(for: seed.key)
                try Task.checkCancellation()
                guard requestID == request else { return }
                groups.append(Group(seed: seed, titles: titles))
            } catch {
                if Task.isCancelled || requestID != request { return }
                failed = true
            }
        }
        loading = false
    }
}
