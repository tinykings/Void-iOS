import SwiftUI

struct RecommendationsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var recommendations: [Media] = []
    @State private var sourceTitles: [MediaKey: String] = [:]
    @State private var loading = false
    @State private var failed = false
    @State private var requestID = UUID()

    private var favorites: [MediaKey] {
        store.entries(.history, type: nil)
            .filter { $0.isFavorite && $0.key.type != .game }
            .map(\.key)
            .sorted()
    }

    private var libraryKeys: Set<MediaKey> {
        Set((store.library.list(.history) + store.library.list(.playlist)).map(\.key))
    }

    private var visibleRecommendations: [Media] {
        let saved = libraryKeys
        return recommendations.filter { !saved.contains($0.key) }
    }

    var body: some View {
        let favorites = favorites
        let shown = visibleRecommendations
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if favorites.isEmpty {
                    Text("Favorite movies or shows in History to get recommendations.")
                        .foregroundStyle(Color.voidSilver)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 14) {
                    ForEach(shown, id: \.key) { media in
                        SearchResultCard(media: media, recommendationSource: sourceTitles[media.key])
                    }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if !favorites.isEmpty && shown.isEmpty && !failed {
                    Text("No new recommendations right now. Try adding more Favorites.")
                        .foregroundStyle(Color.voidSilver)
                }
                if failed {
                    Text("Some recommendations couldn't load.").foregroundStyle(Color.voidSilver)
                    Button("Try again") { Task { await load(favorites) } }.disabled(loading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Recommendations")
        .task(id: favorites) { await load(favorites) }
        .refreshable { await load(favorites) }
    }

    @MainActor private func load(_ favorites: [MediaKey]) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        loading = !favorites.isEmpty
        failed = false
        recommendations = []
        sourceTitles = [:]
        defer {
            if requestID == request { loading = false }
        }

        var selection: [Media] = []
        var seen = Set<MediaKey>()
        for seed in favorites.shuffled() {
            guard selection.count < 50 else { break }
            do {
                let titles = try await store.api.recommendations(for: seed)
                try Task.checkCancellation()
                guard requestID == request else { return }
                let saved = libraryKeys
                var picked = 0
                for media in titles.shuffled() where !saved.contains(media.key) && seen.insert(media.key).inserted {
                    selection.append(media)
                    sourceTitles[media.key] = store.item(seed)?.title
                    picked += 1
                    if picked == 5 || selection.count == 50 { break }
                }
                // Random picks for variety, then order by TMDB popularity.
                recommendations = selection.sorted { $0.popularity > $1.popularity }
            } catch {
                if Task.isCancelled || requestID != request { return }
                failed = true
            }
        }
    }
}
