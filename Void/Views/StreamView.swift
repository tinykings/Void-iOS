import SwiftUI

// Which streaming services carry the movies and shows on your Playlist, the services
// covering the most first, to help pick a subscription.
struct StreamView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var loading = false

    private var items: [SyncedItem] {
        store.entries(.playlist, type: nil).filter { $0.key.type != .game }
    }

    private var groups: [LibraryRules.StreamGroup<SyncedItem>] {
        let results = items.compactMap { item in
            store.providers[item.key.recordName].map { (item: item, providers: $0) }
        }
        return LibraryRules.groupByProvider(results) { $0.title }
    }

    private var notStreaming: [SyncedItem] {
        items.filter { store.providers[$0.key.recordName]?.isEmpty == true }
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("Add movies and shows to your Playlist to see where they stream.")
                        .foregroundStyle(Color.voidSilver).listRowBackground(Color.voidSurface)
                }
                ForEach(groups, id: \.provider.providerID) { group in
                    Section {
                        ForEach(group.items, id: \.key) { item in
                            row(item)
                        }
                    } header: {
                        HStack(spacing: 10) {
                            ProviderLogo(provider: group.provider, size: 28)
                            Text(group.provider.providerName).font(.headline).foregroundStyle(.white).textCase(nil)
                            Spacer()
                            Text("\(group.items.count) of \(items.count)").font(.voidReadout).foregroundStyle(Color.voidCyan)
                        }
                    }
                }
                if !notStreaming.isEmpty {
                    Section("Not on a subscription service") {
                        ForEach(notStreaming, id: \.key) { item in row(item) }
                    }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section {
                    Text("US streaming data from JustWatch, through TMDB. Tap a title for details.")
                        .font(.caption2).foregroundStyle(Color.voidSilver).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Stream")
            .refreshable { await load() }
            .voidRoutes()
            .voidScreen()
            .task(id: items.map(\.key)) { await load() }
        }
    }

    private func row(_ item: SyncedItem) -> some View {
        let media = store.media(for: item)
        return NavigationLink(value: Route.media(media)) {
            HStack(spacing: 12) {
                PosterImage(path: media.posterPath ?? item.image, size: "w185")
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title).font(.subheadline.weight(.semibold))
                    Text([media.mediaType.singular, media.year].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(.voidLabel).foregroundStyle(Color.voidSilver)
                }
            }
        }
        .listRowBackground(Color.voidSurface)
    }

    @MainActor private func load() async {
        loading = true
        await store.loadProviders(for: items)
        loading = false
    }
}
