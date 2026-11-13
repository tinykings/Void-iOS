import SwiftUI

// Movies and shows from TMDB and games from IGDB, ranked together; this week's
// trending titles before you type.
struct SearchView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var results: [Media] = []
    @State private var trending: [Media] = []
    @State private var loading = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shown: [Media] { (trimmed.isEmpty ? trending : results).filter { store.enabledTypes.contains($0.mediaType) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if trimmed.isEmpty && !shown.isEmpty {
                        Text("TRENDING THIS WEEK").font(.voidLabel).tracking(1.3).foregroundStyle(Color.voidSilver)
                    }
                    if let message {
                        Text(message).font(.subheadline).foregroundStyle(Color.voidSilver)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 14) {
                        ForEach(shown, id: \.key) { media in
                            SearchResultCard(media: media)
                        }
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows and games")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .voidRoutes()
            .voidScreen()
            .task(id: trimmed) { await search(trimmed) }
            .task { await loadTrending() }
        }
    }

    @MainActor private func loadTrending() async {
        guard trending.isEmpty, store.enabledTypes.contains(.movie) || store.enabledTypes.contains(.tv) else { return }
        let api = store.api
        trending = (try? await api.trending()) ?? []
    }

    @MainActor private func search(_ text: String) async {
        message = nil
        guard !text.isEmpty else {
            results = []
            loading = false
            return
        }
        // Wait for typing to pause; a new keystroke cancels this task.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        let api = store.api
        let wantsVideo = store.enabledTypes.contains(.movie) || store.enabledTypes.contains(.tv)
        let wantsGames = store.enabledTypes.contains(.game) && text.count >= 2
        async let video: Result<[Media], Error> = wantsVideo ? Self.capture { try await api.search(text) } : .success([])
        async let games: Result<[Media], Error> = wantsGames ? Self.capture { try await api.searchGames(text) } : .success([])
        let (videoResult, gameResult) = await (video, games)
        guard !Task.isCancelled else { return }
        let found = ((try? videoResult.get()) ?? []) + ((try? gameResult.get()) ?? [])
        results = LibraryRules.rankSearchResults(found, query: text)
        if found.isEmpty {
            if case .failure(let error) = videoResult { message = error.localizedDescription }
            else if case .failure(let error) = gameResult { message = error.localizedDescription }
            else { message = "Nothing found for “\(text)”." }
        }
    }

    private static func capture(_ body: @Sendable () async throws -> [Media]) async -> Result<[Media], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

struct SearchResultCard: View {
    let media: Media
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let list = store.item(media.key)?.list
        MediaLink(media: media) {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(path: media.posterPath)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(list == .playlist ? Color.voidCyan : list == .history ? Color.voidHistory : Color.voidBorder))
                    .overlay(alignment: .topTrailing) {
                        if list == .playlist {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.voidCyan).padding(6).shadow(radius: 3)
                        } else if list == .history {
                            // The footer's History icon, in History's green.
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.voidOnAccent)
                                .frame(width: 18, height: 18)
                                .background(Color.voidHistory, in: Circle())
                                .padding(6).shadow(radius: 3)
                        }
                    }
                Text(media.title).font(.caption.weight(.semibold)).lineLimit(2)
                Text([media.mediaType.singular, media.year].compactMap { $0 }.joined(separator: " · ").uppercased())
                    .font(.voidLabel).foregroundStyle(Color.voidSilver)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryActions(media: media) }
    }
}
