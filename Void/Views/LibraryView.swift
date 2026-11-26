import SwiftUI

// The Playlist or History as a poster grid, filtered from the footer.
struct LibraryView: View {
    let list: ListState
    var filter: MediaType?
    var favoritesOnly = false
    @EnvironmentObject private var store: LibraryStore

    private var title: String { favoritesOnly ? "Favorites" : list == .playlist ? "Playlist" : "History" }

    private var items: [SyncedItem] {
        let all = store.entries(list, type: filter)
        return favoritesOnly ? all.filter(\.isFavorite) : all
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 14) {
                        ForEach(items, id: \.key) { item in
                            PosterCard(item: item, media: store.media(for: item), showsUpcoming: list == .playlist)
                        }
                    }
                }
                if store.sync.status.hasPrefix("Sync failed") {
                    Text(store.sync.status).font(.footnote).foregroundStyle(Color.voidSilver)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .navigationTitle(title)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: list == .playlist ? "sparkles.tv" : "clock")
                .font(.largeTitle).foregroundStyle(Color.voidSilver.opacity(0.6))
            Text(list == .playlist ? "Nothing on your Playlist" : favoritesOnly ? "No Favorites" : "Nothing in History")
                .font(.headline)
            Text(list == .playlist
                 ? "Search for movies, shows and games to add them."
                 : favoritesOnly ? "Favorites from History show up here." : "Things you mark played show up here.")
                .font(.subheadline).foregroundStyle(Color.voidSilver).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct PosterCard: View {
    let item: SyncedItem
    let media: Media
    var showsUpcoming = false
    @EnvironmentObject private var store: LibraryStore
    @AppStorage(DisplaySettings.showTitlesKey) private var showTitles = DisplaySettings.showTitlesDefault

    // How long until a show's next episode ("In 5 days"), or until a movie or game
    // comes out; only within the 30 days that also move it to the top of the Playlist.
    private var badge: String? {
        guard showsUpcoming else { return nil }
        let window = LibraryRules.releasePriorityWindowDays
        if item.key.type == .tv, let days = DateText.days(until: media.nextEpisodeToAir?.airDate), (-3...window).contains(days) {
            return DateText.countdown(days)
        }
        if item.key.type != .tv, let days = DateText.days(until: media.releaseDate), (1...window).contains(days) {
            return DateText.countdown(days)
        }
        return nil
    }

    var body: some View {
        MediaLink(media: media) {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(path: media.posterPath ?? item.image)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(item.isPinned ? Color.voidCyan : item.list == .history && item.isFavorite ? Color.pink : Color.voidBorder, lineWidth: item.isPinned ? 2.5 : 1))
                    .overlay(alignment: .bottomLeading) {
                        if let badge {
                            Text(badge.uppercased())
                                .font(.voidLabel)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .foregroundStyle(Color.voidOnAccent)
                                .background(Color.voidCyan, in: RoundedRectangle(cornerRadius: 6))
                                .padding(6)
                        }
                    }
                if showTitles {
                    Text(media.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryActions(media: media) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([media.title, item.isPinned ? "pinned" : nil, item.isFavorite ? "favorite" : nil, badge]
            .compactMap { $0 }.joined(separator: ", "))
    }

}

// The same actions in context menus and on the details screen.
struct LibraryActions: View {
    let media: Media
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let item = store.item(media.key)
        Button { store.togglePlaylist(media) } label: {
            item?.list == .playlist
                ? Label("Remove from Playlist", systemImage: "minus.circle")
                : Label("Add to Playlist", systemImage: "plus.circle")
        }
        Button { store.toggleHistory(media) } label: {
            item?.list == .history
                ? Label("Remove from History", systemImage: "arrow.uturn.backward.circle")
                : Label("Mark Played", systemImage: "checkmark.circle")
        }
        if item?.list == .history || item?.isFavorite == true {
            Button { store.toggleFavorite(media.key) } label: {
                item?.isFavorite == true
                    ? Label("Remove Favorite", systemImage: "heart.slash")
                    : Label("Favorite", systemImage: "heart")
            }
        }
        if let item, item.list == .playlist {
            Button { store.togglePin(media.key) } label: {
                item.isPinned
                    ? Label("Unpin", systemImage: "pin.slash")
                    : Label("Pin to Top", systemImage: "pin")
            }
        }
    }
}
