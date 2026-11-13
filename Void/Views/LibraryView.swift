import SwiftUI

// The Playlist or History: a poster grid with a type filter.
struct LibraryView: View {
    let list: ListState
    @EnvironmentObject private var store: LibraryStore
    @State private var filter: MediaType?
    @State private var favoritesOnly = false
    @State private var showSettings = false

    private var title: String { list == .playlist ? "Playlist" : "History" }

    private var items: [SyncedItem] {
        let all = store.entries(list, type: filter)
        return favoritesOnly ? all.filter(\.isFavorite) : all
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    filterBar
                    if items.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 14) {
                            ForEach(items, id: \.key) { item in
                                PosterCard(item: item, media: store.media(for: item), showsUpcoming: list == .playlist)
                            }
                        }
                    }
                    if !store.sync.status.isEmpty && store.sync.status.hasPrefix("Sync failed") {
                        Text(store.sync.status).font(.footnote).foregroundStyle(Color.voidSilver)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await store.refresh() }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .voidRoutes()
            .voidScreen()
        }
    }

    private var types: [MediaType] { MediaType.allCases.filter(store.enabledTypes.contains) }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if types.count > 1 {
                    chip("All", selected: filter == nil) { filter = nil }
                    ForEach(types, id: \.self) { type in
                        chip(type.label, selected: filter == type) { filter = filter == type ? nil : type }
                    }
                }
                if list == .history {
                    chip("Favorites", systemImage: "heart.fill", selected: favoritesOnly) { favoritesOnly.toggle() }
                }
                Spacer(minLength: 0)
                Text("\(items.count)").font(.voidReadout).foregroundStyle(Color.voidSilver)
            }
        }
        .onChange(of: store.enabledTypes) { _, enabled in
            if let current = filter, !enabled.contains(current) { filter = nil }
        }
    }

    private func chip(_ text: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(text.uppercased())
            }
            .font(.voidLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.voidBackground : Color.voidSilver)
            .background(selected ? Color.voidCyan : Color.voidSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.voidBorder))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: list == .playlist ? "sparkles.tv" : "clock")
                .font(.largeTitle).foregroundStyle(Color.voidSilver.opacity(0.6))
            Text(list == .playlist ? "Nothing on your Playlist" : "Nothing in History")
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

    // "S2E3 · Nov 20" for a show with an episode on the way, a release date for a
    // movie or game coming out.
    private var badge: String? {
        guard showsUpcoming else { return nil }
        if item.key.type == .tv, let next = media.nextEpisodeToAir, let days = DateText.days(until: next.airDate), days >= -3 {
            let episode = [next.seasonNumber.map { "S\($0)" }, next.episodeNumber.map { "E\($0)" }].compactMap { $0 }.joined()
            let when = days == 0 ? "Today" : days == 1 ? "Tomorrow" : DateText.short(next.airDate) ?? ""
            return [episode, when].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if item.key.type != .tv, let days = DateText.days(until: media.releaseDate), days > 0 {
            return days == 1 ? "Tomorrow" : DateText.short(media.releaseDate)
        }
        return nil
    }

    var body: some View {
        NavigationLink(value: Route.media(media)) {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(path: media.posterPath ?? item.image)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.voidBorder))
                    .overlay(alignment: .topTrailing) { marks }
                    .overlay(alignment: .bottomLeading) {
                        if let badge {
                            Text(badge.uppercased())
                                .font(.voidLabel)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .foregroundStyle(Color.voidBackground)
                                .background(Color.voidCyan, in: RoundedRectangle(cornerRadius: 6))
                                .padding(6)
                        }
                    }
                Text(media.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryActions(media: media) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([media.title, item.isFavorite ? "favorite" : nil, item.isPurchased ? "purchased" : nil, badge]
            .compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder private var marks: some View {
        HStack(spacing: 4) {
            if item.isPurchased { Image(systemName: "dollarsign.circle.fill") }
            if item.isFavorite { Image(systemName: "heart.fill") }
        }
        .font(.caption)
        .foregroundStyle(Color.voidCyan)
        .padding(6)
        .shadow(radius: 3)
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
        if media.mediaType == .game, item?.list == .playlist {
            Button { store.togglePurchased(media.key) } label: {
                item?.isPurchased == true
                    ? Label("Mark Not Purchased", systemImage: "dollarsign.circle")
                    : Label("Mark Purchased", systemImage: "dollarsign.circle.fill")
            }
        }
    }
}
