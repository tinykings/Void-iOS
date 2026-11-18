import Foundation

// The webapp's list rules, ported from src/lib (sort.ts, library.ts,
// searchRanking.ts, tmdb.ts, streamProviders.ts, gameDeals.ts, ggDeals.ts).
enum LibraryRules {
    static let returnWindowDays = 7
    static let returnCheckInterval: TimeInterval = 24 * 60 * 60
    static let releasePriorityWindowDays = 30

    // MARK: Dates

    // A `YYYY-MM-DD` date as midnight in `calendar`'s time zone.
    static func localDay(_ value: String, calendar: Calendar = .current) -> Date? {
        guard SyncCodec.isCalendarDate(value) else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // Whether a date falls between today and `windowDays` days from today, inclusive.
    static func isInLocalDayWindow(_ value: String, now: Date, windowDays: Int, calendar: Calendar = .current) -> Bool {
        guard let day = localDay(value, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: windowDays, to: calendar.startOfDay(for: now)) else { return false }
        return day >= calendar.startOfDay(for: now) && day <= end
    }

    // Whether a History show should be checked for a returning episode.
    static func needsReturnCheck(status: String?, lastChecked: Date?, now: Date) -> Bool {
        guard status != "Ended", status != "Canceled" else { return false }
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) > returnCheckInterval
    }

    // How long cached details stay fresh. A Playlist show that's still airing refreshes
    // daily so its next episode (and its notification) stays current; the rest weekly.
    static func detailsMaxAge(type: MediaType, list: ListState, status: String?) -> TimeInterval {
        let airing = type == .tv && list == .playlist && status != "Ended" && status != "Canceled"
        return airing ? returnCheckInterval : 7 * 24 * 60 * 60
    }

    // The air date a History show returns for, if its next episode airs within the window.
    static func returnAirDate(nextEpisodeAirDate: String?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date = nextEpisodeAirDate,
              isInLocalDayWindow(date, now: now, windowDays: returnWindowDays, calendar: calendar) else { return nil }
        return date
    }

    // MARK: Sorting

    struct SortInput {
        var type: MediaType
        var releaseDate: String?
        var nextEpisodeAirDate: String?
        var addedAt: String
    }

    private static func relevantDate(_ item: SortInput) -> Date? {
        let value = (item.type == .tv ? item.nextEpisodeAirDate : nil) ?? item.releaseDate
        return value.flatMap { localDay(String($0.prefix(10)), calendar: utc) }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // The Playlist: shows with an episode within 30 days (or aired in the last 3) and
    // movies or games releasing within 30 days come first, soonest first; then the
    // rest, newest added first.
    static func sortPlaylist<T>(_ items: [T], now: Date = Date(), input: (T) -> SortInput) -> [T] {
        let today = Calendar.current.startOfDay(for: now)
        func days(_ date: Date) -> Int {
            // As the webapp: whole days, rounded up, from local midnight.
            Int((date.timeIntervalSince(today) / 86400).rounded(.up))
        }
        var upcoming: [(T, Date)] = []
        var rest: [(T, String)] = []
        for item in items {
            let sortInput = input(item)
            if let date = relevantDate(sortInput) {
                let diff = days(date)
                let isUpcomingShow = sortInput.type == .tv && sortInput.nextEpisodeAirDate != nil
                    && diff >= -3 && diff <= releasePriorityWindowDays
                let isRelease = sortInput.type != .tv && abs(diff) <= releasePriorityWindowDays
                if isUpcomingShow || isRelease {
                    upcoming.append((item, date))
                    continue
                }
            }
            rest.append((item, sortInput.addedAt))
        }
        return upcoming.sorted { $0.1 < $1.1 }.map(\.0) + rest.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: Search

    static func normalizedSearchText(_ value: String) -> String {
        let folded = value.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var space = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if space && !out.isEmpty { out.append(" ") }
                space = false
                out.unicodeScalars.append(scalar)
            } else {
                space = true
            }
        }
        return out
    }

    private static func searchRank(_ media: Media, query: String, index: Int) -> Double {
        let title = normalizedSearchText(media.title)
        let search = normalizedSearchText(query)
        let popularity = (media.popularity > 0 ? media.popularity : Double(media.voteCount)) / 1_000_000
        if title.isEmpty || search.isEmpty { return 10_000 + Double(index) }
        if title == search { return 0 - popularity }
        if title.hasPrefix(search) { return 100 + Double(title.count - search.count) - popularity }
        if let range = title.range(of: search) {
            return 300 + Double(title.distance(from: title.startIndex, to: range.lowerBound)) + Double(title.count) / 100 - popularity
        }
        let searchWords = search.split(separator: " ")
        let titleWords = title.split(separator: " ")
        let matching = searchWords.filter { word in titleWords.contains { $0.hasPrefix(word) } }.count
        if matching > 0 {
            return 600 + Double((searchWords.count - matching) * 50) + Double(title.count) / 100 - popularity
        }
        return 1_000 + Double(index) - popularity
    }

    static func rankSearchResults(_ results: [Media], query: String) -> [Media] {
        results.enumerated()
            .map { (media: $0.element, rank: searchRank($0.element, query: query, index: $0.offset), index: $0.offset) }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.media.popularity != b.media.popularity { return a.media.popularity > b.media.popularity }
                return a.index < b.index
            }
            .map(\.media)
    }

    // MARK: Trending

    static let upcomingEach = 6
    static let upcomingDays = 30

    // As the website's Trending tab: one game after every two movies or shows, then
    // whatever's left of either. Upcoming titles (up to six each, rotating movie, show,
    // game) go in after every fourth of those, and any already trending are left out.
    static func mixTrending(titles: [Media], games: [Media], upcomingMovies: [Media] = [],
                            upcomingShows: [Media] = [], upcomingGames: [Media] = []) -> [Media] {
        var trending: [Media] = []
        var t = 0, g = 0
        while t < titles.count || g < games.count {
            for _ in 0..<2 where t < titles.count { trending.append(titles[t]); t += 1 }
            if g < games.count { trending.append(games[g]); g += 1 }
        }

        var seen = Set(trending.map(\.key))
        let lists = [upcomingMovies, upcomingShows, upcomingGames].map { list in
            Array(list.filter { !seen.contains($0.key) }.prefix(upcomingEach))
        }
        var upcoming: [Media] = []
        for index in 0..<upcomingEach {
            for list in lists where index < list.count && seen.insert(list[index].key).inserted {
                upcoming.append(list[index])
            }
        }

        var mixed: [Media] = []
        var u = 0
        for (index, media) in trending.enumerated() {
            mixed.append(media)
            if index % 4 == 3 && u < upcoming.count { mixed.append(upcoming[u]); u += 1 }
        }
        return mixed + upcoming[u...]
    }

    // MARK: Streaming providers

    private static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func canonicalName(_ name: String) -> String {
        let cleaned = clean(name)
        let lower = cleaned.lowercased()
        func dropping(_ suffix: String) -> String { clean(String(cleaned.dropLast(suffix.count))) }
        if lower.hasSuffix(" standard with ads") { return dropping(" standard with ads") }
        if lower.hasSuffix(" with ads") { return dropping(" with ads") }
        if lower.hasSuffix(" essential") { return dropping(" essential") }
        if lower.hasSuffix(" premium plus") { return dropping(" plus") }
        if lower.hasSuffix(" plus premium") { return dropping(" premium") }
        return cleaned
    }

    // US subscription and free providers, without channels, ad tiers or duplicate plans.
    static func usStreamingProviders(_ response: WatchProvidersResponse) -> [WatchProvider] {
        let us = response.results["US"]
        var seenIDs = Set<Int>()
        let providers = ((us?.free ?? []) + (us?.flatrate ?? []))
            .filter { !$0.providerName.lowercased().contains("channel") }
            .filter { seenIDs.insert($0.providerID).inserted }
            .map { WatchProvider(providerID: $0.providerID, providerName: canonicalName($0.providerName), logoPath: $0.logoPath) }
        var seenNames = Set<String>()
        let unique = providers.filter { seenNames.insert($0.providerName.lowercased()).inserted }
        return unique.filter { provider in
            let name = provider.providerName.lowercased()
            return !unique.contains { candidate in
                candidate.providerID != provider.providerID && name.hasPrefix(candidate.providerName.lowercased() + " ")
            }
        }
    }

    static func justWatchURL(title: String) -> URL? {
        var components = URLComponents(string: "https://www.justwatch.com/us/search")
        components?.queryItems = [URLQueryItem(name: "q", value: title)]
        return components?.url
    }

    struct StreamGroup<T> {
        var provider: WatchProvider
        var items: [T]
    }

    // Playlist titles grouped by the services that stream them, the services with the
    // most titles first.
    static func groupByProvider<T>(_ results: [(item: T, providers: [WatchProvider])], title: (T) -> String) -> [StreamGroup<T>] {
        var groups: [Int: StreamGroup<T>] = [:]
        var order: [Int] = []
        for result in results {
            for provider in result.providers {
                if groups[provider.providerID] == nil {
                    groups[provider.providerID] = StreamGroup(provider: provider, items: [])
                    order.append(provider.providerID)
                }
                groups[provider.providerID]?.items.append(result.item)
            }
        }
        return order.compactMap { groups[$0] }
            .map { StreamGroup(provider: $0.provider, items: $0.items.sorted { title($0).localizedCompare(title($1)) == .orderedAscending }) }
            .sorted {
                if $0.items.count != $1.items.count { return $0.items.count > $1.items.count }
                return $0.provider.providerName.localizedCompare($1.provider.providerName) == .orderedAscending
            }
    }

    // MARK: Game deals

    static func steamAppID(_ media: Media) -> Int? {
        if let id = media.steamAppId, id > 0 { return id }
        if media.source == .steam, media.id > 0 { return media.id }
        guard let value = media.sourceURL, let url = URL(string: value),
              ["store.steampowered.com", "www.store.steampowered.com"].contains(url.host ?? "") else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "app", let id = Int(parts[1]), id > 0 else { return nil }
        return id
    }

    static func formatPrice(_ price: GamePrice) -> String? {
        guard let lowest = price.lowestCurrent, let amount = Decimal(string: lowest.amount, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = price.currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(lowest.amount) \(price.currency)"
    }

    // Lowest current price first.
    static func sortDeals<T>(_ deals: [(item: T, price: GamePrice)], title: (T) -> String) -> [(item: T, price: GamePrice)] {
        func amount(_ price: GamePrice) -> Double { Double(price.lowestCurrent?.amount ?? "") ?? .infinity }
        return deals.sorted {
            let a = amount($0.price), b = amount($1.price)
            if a != b { return a < b }
            return title($0.item).localizedCompare(title($1.item)) == .orderedAscending
        }
    }
}
