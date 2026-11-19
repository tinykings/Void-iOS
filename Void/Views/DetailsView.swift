import SwiftUI
import WebKit

// A movie, show or game: details, where it streams or what it costs, cast, seasons,
// and the library actions.
struct DetailsView: View {
    let seed: Media
    @EnvironmentObject private var store: LibraryStore
    @State private var media: Media?
    @State private var cast: [CastMember] = []
    @State private var providers: [WatchProvider]?
    @State private var contentRating: String?
    @State private var price: GamePrice?
    @State private var priceError: String?
    @State private var failed = false
    @State private var loading = false
    @State private var playing: Video?

    private var shown: Media { media ?? store.cachedMedia(seed.key) ?? seed }
    private var item: SyncedItem? { store.item(seed.key) }
    private var isGame: Bool { seed.mediaType == .game }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                if loading && media == nil {
                    // Until the details arrive, only what the list or search knew is shown.
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading details…").font(.footnote).foregroundStyle(Color.voidSilver)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                if failed && media == nil && !loading {
                    // No pull-to-refresh: pulling down drags the details card away.
                    HStack {
                        Text("Couldn't load all the details.").font(.footnote).foregroundStyle(Color.voidSilver)
                        Button("Try Again") { Task { await load() } }.font(.footnote.weight(.semibold))
                    }
                }
                if isGame { bestPrice }
                if !shown.overview.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let tagline = shown.tagline { Text(tagline).font(.subheadline.italic()).foregroundStyle(Color.voidSilver) }
                        Text(shown.overview).font(.body)
                    }
                }
                if shown.mediaType == .tv { nextEpisode }
                if isGame { gameInfo }
                trailers
                castRow
                if shown.mediaType == .tv && !shown.seasons.isEmpty { seasons }
                screenshots
                Text(isGame ? "Game data from IGDB and HowLongToBeat; Steam game prices from GG.deals." : "Data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming data from JustWatch.")
                    .font(.caption2).foregroundStyle(Color.voidSilver.opacity(0.7))
            }
            .padding(16)
        }
        // The title stays for the back button and history menu, but isn't drawn: the
        // header already shows the name.
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        .voidScreen()
        .task(id: seed.key) { await load() }
    }

    @MainActor private func load() async {
        let key = seed.key
        let api = store.api
        loading = true
        defer { loading = false }
        do {
            let loaded = try await api.details(for: key)
            media = loaded
            store.didLoadDetails(loaded)
            failed = false
        } catch {
            failed = true
        }
        if isGame {
            if let appID = LibraryRules.steamAppID(shown) {
                do {
                    price = try await store.prices.steamPrice(appID)
                    priceError = nil
                } catch let error as GamePrices.Failure {
                    // Busy or a bad key is worth saying; other failures just leave no price.
                    priceError = error.localizedDescription
                } catch {}
            }
        } else {
            async let credits = try? api.credits(key.type, id: key.id)
            async let streams = try? api.streamingProviders(key.type, id: key.id)
            async let rating = try? api.contentRating(key.type, id: key.id)
            cast = Array((await credits ?? []).prefix(20))
            providers = await streams ?? []
            contentRating = await rating ?? nil
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(path: shown.posterPath ?? item?.image, size: "w342")
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.voidBorder))
            VStack(alignment: .leading, spacing: 8) {
                Text(shown.title).font(.title2.weight(.black)).fixedSize(horizontal: false, vertical: true)
                Text(facts.joined(separator: " · ").uppercased())
                    .font(.voidLabel).foregroundStyle(Color.voidSilver)
                if !shown.genres.isEmpty {
                    Text(shown.genres.prefix(3).joined(separator: ", ")).font(.footnote).foregroundStyle(Color.voidSilver)
                }
                if shown.voteAverage > 0 {
                    Label(String(format: "%.1f", shown.voteAverage), systemImage: "star.fill")
                        .font(.voidReadout).foregroundStyle(Color.voidCyan)
                }
                if isGame {
                    if !shown.platforms.isEmpty {
                        Text(shown.platforms.joined(separator: ", ")).font(.footnote).foregroundStyle(Color.voidSilver)
                    }
                } else {
                    streaming
                }
            }
        }
    }

    private var facts: [String] {
        var facts = [shown.mediaType.singular]
        if let year = shown.year { facts.append(year) }
        if let runtime = shown.runtime, runtime > 0, shown.mediaType == .movie {
            facts.append(runtime >= 60 ? "\(runtime / 60)h \(runtime % 60)m" : "\(runtime)m")
        }
        if let seasons = shown.numberOfSeasons { facts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
        if let status = shown.status, shown.mediaType == .tv { facts.append(status) }
        if let contentRating { facts.append(contentRating) }
        return facts
    }

    private var actions: some View {
        let list = item?.list
        return HStack(spacing: 10) {
            actionButton(list == .playlist ? "On Playlist" : "Playlist", systemImage: list == .playlist ? "checkmark" : "plus",
                         on: list == .playlist) { store.togglePlaylist(shown) }
            actionButton(list == .history ? "Played" : "Mark Played", systemImage: list == .history ? "checkmark.circle.fill" : "checkmark.circle",
                         on: list == .history) { store.toggleHistory(shown) }
            if list == .history || item?.isFavorite == true {
                iconButton(item?.isFavorite == true ? "heart.fill" : "heart", label: item?.isFavorite == true ? "Remove favorite" : "Favorite",
                           on: item?.isFavorite == true) { store.toggleFavorite(seed.key) }
            }
        }
        .sensoryFeedback(.selection, trigger: item)
    }

    private func actionButton(_ title: String, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(on ? Color.voidOnAccent : .primary)
                .background(on ? Color.voidCyan : Color.voidSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.voidBorder))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemImage: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 46, height: 44)
                .foregroundStyle(on ? Color.voidCyan : .primary)
                .background(Color.voidSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.voidCyan : Color.voidBorder))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.voidLabel).tracking(1.3).foregroundStyle(Color.voidSilver)
    }

    @ViewBuilder private var nextEpisode: some View {
        if let next = shown.nextEpisodeToAir, let date = next.airDate {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Next episode")
                let number = [next.seasonNumber.map { "S\($0)" }, next.episodeNumber.map { "E\($0)" }].compactMap { $0 }.joined()
                Text([number, next.name, DateText.short(date)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
            }
        }
    }

    // Where it streams, under the rating: service logos linking to JustWatch.
    @ViewBuilder private var streaming: some View {
        if let providers {
            if providers.isEmpty {
                Text("Not on a US streaming service").font(.footnote).foregroundStyle(Color.voidSilver)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(providers) { provider in
                            if let url = LibraryRules.justWatchURL(title: shown.title) {
                                Link(destination: url) { ProviderLogo(provider: provider, size: 34) }
                                    .accessibilityLabel("\(provider.providerName), open on JustWatch")
                            }
                        }
                    }
                    .padding(1)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var gameInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !playtimes.isEmpty {
                sectionTitle("How long to beat")
                HStack(spacing: 10) {
                    ForEach(playtimes, id: \.label) { time in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(time.hours < 10 ? String(format: "%.1fh", time.hours) : "\(Int(time.hours.rounded()))h").font(.voidReadout).foregroundStyle(Color.voidCyan)
                            Text(time.label).font(.caption2).foregroundStyle(Color.voidSilver)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.voidSurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if !gameLinks.isEmpty {
                HStack(spacing: 16) {
                    ForEach(gameLinks, id: \.label) { link in Link(link.label, destination: link.url).font(.footnote) }
                }
            }
        }
    }

    @ViewBuilder private var bestPrice: some View {
        if let price, let formatted = LibraryRules.formatPrice(price), let url = URL(string: price.url), url.scheme == "https" {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Best price")
                Link(destination: url) {
                    HStack {
                        Text(formatted).font(.title3.weight(.bold)).foregroundStyle(Color.voidCyan)
                        Text(price.lowestCurrent?.source == "keyshop" ? "Keyshop" : "Retail").font(.voidLabel).foregroundStyle(Color.voidSilver)
                        Spacer()
                        Text("GG.deals").font(.footnote)
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(12)
                    .background(Color.voidSurface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else if let priceError {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Best price")
                Text(priceError).font(.footnote).foregroundStyle(Color.voidSilver)
            }
        }
    }

    private struct Playtime { var label: String; var hours: Double }
    private var playtimes: [Playtime] {
        let all: [Playtime?] = [
            shown.playtimeMain.map { Playtime(label: "Main", hours: $0) },
            shown.playtimeExtra.map { Playtime(label: "Main + extras", hours: $0) },
            shown.playtimeCompletionist.map { Playtime(label: "Completionist", hours: $0) },
        ]
        return all.compactMap { $0 }.filter { $0.hours > 0 }
    }

    private struct ExternalLink { var label: String; var url: URL }
    private var gameLinks: [ExternalLink] {
        let all: [(String, String?)] = [("HowLongToBeat", shown.hltbURL)]
        return all.compactMap { label, value in
            guard let value, let url = URL(string: value), url.scheme == "https" else { return nil }
            return ExternalLink(label: label, url: url)
        }
    }

    @ViewBuilder private var trailers: some View {
        let videos = shown.videos.filter { $0.youTubeURL != nil && ($0.type == "Trailer" || $0.type == "Teaser") }.prefix(3)
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Trailers")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(videos)) { video in
                            VStack(alignment: .leading, spacing: 6) {
                                // Tapping the thumbnail swaps in the player right there.
                                if playing == video {
                                    YouTubeEmbed(key: video.key)
                                        .frame(width: 300, height: 169)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Button { playing = video } label: {
                                        PosterImage(path: video.youTubeThumbnailURL?.absoluteString)
                                            .frame(width: 300, height: 169)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.voidBorder))
                                            .overlay {
                                                Image(systemName: "play.fill")
                                                    .font(.title3)
                                                    .foregroundStyle(.white)
                                                    .frame(width: 48, height: 48)
                                                    .background(.black.opacity(0.55), in: Circle())
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Play \(video.name)")
                                }
                                Text(video.name).font(.caption.weight(.semibold)).lineLimit(2)
                            }
                            .frame(width: 300, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var castRow: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Cast")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(cast) { person in
                            NavigationLink(value: Route.person(id: person.id, name: person.name)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    PosterImage(path: person.profilePath, size: "w185")
                                        .frame(width: 76, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(person.name).font(.caption.weight(.semibold)).lineLimit(2)
                                    if let character = person.character, !character.isEmpty {
                                        Text(character).font(.caption2).foregroundStyle(Color.voidSilver).lineLimit(2)
                                    }
                                }
                                .frame(width: 76, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var seasons: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Seasons")
            ForEach(shown.seasons.filter { $0.seasonNumber > 0 || shown.seasons.count == 1 }) { season in
                NavigationLink(value: Route.season(showID: shown.id, showTitle: shown.title, season: season)) {
                    HStack {
                        Text(season.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text([season.episodeCount.map { "\($0) ep" }, season.airDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.voidReadout).foregroundStyle(Color.voidSilver)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.voidSilver)
                    }
                    .padding(12)
                    .background(Color.voidSurface, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var screenshots: some View {
        if !shown.screenshots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shown.screenshots, id: \.self) { path in
                        PosterImage(path: path, size: "w780")
                            .frame(width: 260, height: 146)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

// YouTube's privacy-enhanced embed, playing inline in the page.
private struct YouTubeEmbed: UIViewRepresentable {
    // Already checked against YouTube's ID characters by `Video.youTubeURL`.
    let key: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(key)?playsinline=1&autoplay=1&rel=0"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        // YouTube refuses embeds without a web origin to identify the page.
        view.loadHTMLString(html, baseURL: URL(string: "https://void.tinyk.ing/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

// Unaired episode summaries look encoded until revealed: each letter and digit becomes
// a stand-in glyph, spaces and punctuation stay, and the same text always scrambles the
// same way so it doesn't flicker as the view redraws.
enum Scramble {
    private static let glyphs = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#%&@$")

    // Stand-in text, roughly a two-line summary, for episodes TMDB has no summary for.
    private static let fillers = [
        "The story takes a turn as old allies return and a new threat comes into view before the night is out.",
        "Plans unravel when a secret comes to light, and an unlikely pair must decide who they can still trust.",
        "With time running short, everyone is pushed toward a choice that will change what comes next for all of them.",
    ]

    static func filler(for id: Int) -> String { fillers[abs(id) % fillers.count] }

    static func text(_ text: String, seed: Int = 0) -> String {
        var state: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(seed))
        return String(text.map { character in
            guard character.isLetter || character.isNumber else { return character }
            for scalar in character.unicodeScalars { state = (state ^ UInt64(scalar.value)) &* 0x100000001B3 }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return glyphs[Int((state >> 33) % UInt64(glyphs.count))]
        })
    }
}

struct ProviderLogo: View {
    let provider: WatchProvider
    var size: CGFloat = 44

    var body: some View {
        PosterImage(path: provider.logoPath, size: "w92")
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(Color.voidBorder))
    }
}

struct SeasonView: View {
    let showID: Int
    let showTitle: String
    let season: SeasonSummary
    @EnvironmentObject private var store: LibraryStore
    @State private var details: SeasonDetails?
    @State private var failed = false
    @State private var revealed: Set<Int> = []

    var body: some View {
        List {
            if let details {
                ForEach(details.episodes) { episode in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            still(episode)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("E\(episode.episodeNumber)").font(.voidReadout).foregroundStyle(Color.voidCyan)
                                Text(episode.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                if let date = DateText.short(episode.airDate) {
                                    Text(date).font(.voidReadout).foregroundStyle(Color.voidSilver)
                                }
                            }
                        }
                        let overview = episode.overview.flatMap { $0.isEmpty ? nil : $0 }
                        if hidden(episode) {
                            // No summary yet still gets a scrambled block, so every
                            // upcoming episode looks the same until revealed.
                            Text(Scramble.text(overview ?? Scramble.filler(for: episode.id), seed: episode.id))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Color.voidSilver.opacity(0.7))
                                .lineLimit(4)
                        } else if let overview {
                            Text(overview).font(.footnote).foregroundStyle(Color.voidSilver).lineLimit(4)
                        } else if !aired(episode) {
                            Text("No summary yet.").font(.footnote).foregroundStyle(Color.voidSilver)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    // Not aired yet: the still and summary stay hidden until tapped.
                    .onTapGesture {
                        guard !aired(episode) else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            if revealed.contains(episode.id) { revealed.remove(episode.id) } else { revealed.insert(episode.id) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(hidden(episode) ? "Hidden until it airs. Double-tap to reveal." : "")
                    .listRowBackground(Color.voidSurface)
                }
            } else if failed {
                Text("Couldn't load this season.").foregroundStyle(Color.voidSilver).listRowBackground(Color.voidSurface)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .navigationTitle(season.name)
        .navigationBarTitleDisplayMode(.inline)
        .voidScreen()
        .task {
            let api = store.api
            do { details = try await api.season(showID: showID, number: season.seasonNumber) } catch { failed = true }
        }
    }

    private func aired(_ episode: Episode) -> Bool {
        guard let days = DateText.days(until: episode.airDate) else { return false }
        return days <= 0
    }

    private func hidden(_ episode: Episode) -> Bool { !aired(episode) && !revealed.contains(episode.id) }

    // The episode's still once it has aired or been tapped. Before that, a blurred image
    // with a clock, so the still (or the season poster, if there's no still yet) can't
    // spoil anything.
    private func still(_ episode: Episode) -> some View {
        let isOut = !hidden(episode)
        return PosterImage(path: episode.stillPath ?? (aired(episode) ? nil : season.posterPath), size: "w300")
            .blur(radius: isOut ? 0 : 14)
            .overlay {
                if !isOut {
                    Color.black.opacity(0.25)
                    Image(systemName: "clock").font(.headline).foregroundStyle(.white)
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.voidBorder))
            .accessibilityHidden(true)
    }
}

struct PersonView: View {
    let id: Int
    let name: String
    @EnvironmentObject private var store: LibraryStore
    @State private var person: PersonDetails?
    @State private var credits: [Media] = []
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    PosterImage(path: person?.profilePath, size: "w185")
                        .frame(width: 96, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(.title2.weight(.black))
                        if let born = person?.birthday { Text("Born \(DateText.short(born) ?? born)").font(.footnote).foregroundStyle(Color.voidSilver) }
                        if let place = person?.placeOfBirth { Text(place).font(.footnote).foregroundStyle(Color.voidSilver) }
                    }
                }
                if let bio = person?.biography, !bio.isEmpty {
                    Text(bio).font(.subheadline).lineLimit(expanded ? nil : 6)
                        .onTapGesture { expanded.toggle() }
                }
                if !credits.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .top)], spacing: 14) {
                        ForEach(credits) { media in
                            MediaLink(media: media) {
                                VStack(alignment: .leading, spacing: 6) {
                                    PosterImage(path: media.posterPath)
                                        .aspectRatio(2 / 3, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(media.title).font(.caption.weight(.semibold)).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { LibraryActions(media: media) }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .voidScreen()
        .task {
            let api = store.api
            async let details = try? api.person(id)
            async let cast = try? api.personCredits(id)
            person = await details
            // Most popular first, one entry per title.
            var seen = Set<MediaKey>()
            credits = (await cast ?? []).filter { $0.posterPath != nil && seen.insert($0.key).inserted }
                .sorted { $0.popularity > $1.popularity }
        }
    }
}
