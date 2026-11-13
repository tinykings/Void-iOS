import SwiftUI

// Current prices for the games on your Playlist that you haven't bought, cheapest first.
struct DealsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var prices: [Int: GamePrice] = [:]
    @State private var loading = false
    @State private var message: String?
    @Environment(\.openURL) private var openURL

    private struct Game {
        var media: Media
        var appID: Int?
    }

    private struct Deal {
        var media: Media
        var price: GamePrice
    }

    private var games: [Game] {
        store.entries(.playlist, type: .game).map { item in
            let media = store.media(for: item)
            return Game(media: media, appID: LibraryRules.steamAppID(media))
        }
    }

    private var appIDs: [Int] { games.compactMap { $0.appID } }

    private var deals: [Deal] {
        var found: [(item: Media, price: GamePrice)] = []
        for game in games {
            if let id = game.appID, let price = prices[id], price.lowestCurrent != nil {
                found.append((item: game.media, price: price))
            }
        }
        return LibraryRules.sortDeals(found) { $0.title }.map { Deal(media: $0.item, price: $0.price) }
    }

    private var unpriced: [Game] {
        games.filter { game in game.appID.map { prices[$0] == nil } ?? true }
    }

    var body: some View {
        List {
            if games.isEmpty {
                Text("Add games to your Playlist to see their prices.")
                    .foregroundStyle(Color.voidSilver).listRowBackground(Color.voidSurface)
            }
            ForEach(deals, id: \.media.key) { deal in
                HStack(spacing: 12) {
                    NavigationLink(value: Route.media(deal.media)) {
                        HStack(spacing: 12) {
                            PosterImage(path: deal.media.posterPath, size: "w185")
                                .frame(width: 36, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deal.media.title).font(.subheadline.weight(.semibold))
                                Text(deal.price.lowestCurrent?.source == "keyshop" ? "KEYSHOP" : "RETAIL")
                                    .font(.voidLabel).foregroundStyle(Color.voidSilver)
                            }
                            Spacer()
                            Text(LibraryRules.formatPrice(deal.price) ?? "").font(.headline).foregroundStyle(Color.voidCyan)
                        }
                    }
                }
                .listRowBackground(Color.voidSurface)
                .swipeActions {
                    if let url = URL(string: deal.price.url), url.scheme == "https" {
                        Button { openURL(url) } label: { Label("GG.deals", systemImage: "arrow.up.right") }.tint(.voidCyan)
                    }
                }
            }
            if !unpriced.isEmpty && !loading {
                Section("No Steam price") {
                    ForEach(unpriced, id: \.media.key) { game in
                        NavigationLink(value: Route.media(game.media)) { Text(game.media.title) }
                            .listRowBackground(Color.voidSurface)
                    }
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            if let message { Text(message).font(.footnote).foregroundStyle(Color.voidSilver).listRowBackground(Color.clear) }
            Section {
                Text("Prices in USD from GG.deals. Swipe a game to open its deals.")
                    .font(.caption2).foregroundStyle(Color.voidSilver).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Deals")
        .refreshable { await load() }
        .task(id: appIDs) { await load() }
    }

    @MainActor private func load() async {
        let ids = appIDs
        guard !ids.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let api = store.api
            let found = try await api.steamPrices(ids)
            prices = Dictionary(found.map { ($0.steamAppId, $0) }, uniquingKeysWith: { a, _ in a })
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
