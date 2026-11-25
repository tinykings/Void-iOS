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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if items.isEmpty {
                    Text("Add movies and shows to your Playlist to see where they stream.")
                        .foregroundStyle(Color.voidSilver)
                }
                ForEach(groups, id: \.provider.providerID) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            ProviderLogo(provider: group.provider, size: 28)
                            Text(group.provider.providerName).font(.headline).foregroundStyle(.primary)
                            Spacer()
                            Text("\(group.items.count) of \(items.count)").font(.voidReadout).foregroundStyle(Color.voidCyan)
                        }
                        .accessibilityAddTraits(.isHeader)
                        posters(group.items)
                    }
                }
                if !notStreaming.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Not on a subscription service")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        posters(notStreaming)
                    }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Text("US streaming data from JustWatch, through TMDB. Tap a title for details.")
                    .font(.caption2).foregroundStyle(Color.voidSilver)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Stream")
        .refreshable { await load() }
        .task(id: items.map(\.key)) { await load() }
    }

    private func posters(_ items: [SyncedItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 14) {
            ForEach(items, id: \.key) { item in
                PosterCard(item: item, media: store.media(for: item), showsUpcoming: true)
            }
        }
    }

    @MainActor private func load() async {
        loading = true
        await store.loadProviders(for: items)
        loading = false
    }
}
