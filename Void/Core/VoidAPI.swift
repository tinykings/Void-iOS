import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The [void] API Worker (worker/): TMDB through /api/tmdb, IGDB games, and GG.deals
// Steam prices. The app holds no shared API keys; the Worker does. (A user's own
// GG.deals key, if they add one, is used directly: see GamePrices.)
struct VoidAPI: Sendable {
    enum Failure: Error, LocalizedError, Equatable {
        case notConfigured
        case rateLimited
        case notFound
        case status(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: "The [void] API address isn't set (VoidAPIBaseURL in Info.plist)."
            case .rateLimited: "Too many requests. Try again in a minute."
            case .notFound: "Not found."
            case .status(let code): "The server returned an error (\(code))."
            case .invalidResponse: "The server sent something unexpected."
            }
        }
    }

    var baseURL: URL?
    var session: URLSession = .shared

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as type: T.Type,
                                   mediaType: MediaType? = nil) async throws -> T {
        guard let baseURL, var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw Failure.notConfigured
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 404: throw Failure.notFound
        case 429: throw Failure.rateLimited
        default: throw Failure.status(status)
        }
        let decoder = JSONDecoder()
        if let mediaType { decoder.userInfo[.mediaType] = mediaType }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw Failure.invalidResponse
        }
    }

    private struct Page<T: Decodable>: Decodable {
        var results: [Failable<T>]
    }

    // MARK: TMDB

    func search(_ query: String) async throws -> [Media] {
        let page = try await get("api/tmdb/search/multi", ["query": query], as: Page<Media>.self)
        return page.results.compactMap(\.value).filter { $0.mediaType != .game }
    }

    func trending() async throws -> [Media] {
        let page = try await get("api/tmdb/trending/all/week", as: Page<Media>.self)
        return page.results.compactMap(\.value).filter { $0.mediaType != .game }
    }

    // Movies or shows first released in the next `days` days, most popular first.
    func upcoming(_ type: MediaType, days: Int = LibraryRules.upcomingDays, now: Date = Date(),
                  calendar: Calendar = .current) async throws -> [Media] {
        precondition(type != .game)
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: 1, to: today),
              let to = calendar.date(byAdding: .day, value: days, to: today) else { return [] }
        let field = type == .movie ? "primary_release_date" : "first_air_date"
        let page = try await get("api/tmdb/discover/\(type.rawValue)",
                                 ["\(field).gte": Self.day(from, calendar), "\(field).lte": Self.day(to, calendar), "sort_by": "popularity.desc"],
                                 as: Page<Media>.self, mediaType: type)
        return page.results.compactMap(\.value)
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func details(_ type: MediaType, id: Int) async throws -> Media {
        precondition(type != .game)
        return try await get("api/tmdb/\(type.rawValue)/\(id)",
                             ["append_to_response": "videos,images", "include_image_language": "en,null"],
                             as: Media.self, mediaType: type)
    }

    func credits(_ type: MediaType, id: Int) async throws -> [CastMember] {
        try await get("api/tmdb/\(type.rawValue)/\(id)/credits", as: CreditsResponse.self).cast
    }

    func streamingProviders(_ type: MediaType, id: Int) async throws -> [WatchProvider] {
        LibraryRules.usStreamingProviders(try await get("api/tmdb/\(type.rawValue)/\(id)/watch/providers", as: WatchProvidersResponse.self))
    }

    private struct ReleaseDates: Decodable {
        struct Country: Decodable {
            struct Release: Decodable { var certification: String? }
            var iso_3166_1: String
            var release_dates: [Release]
        }
        var results: [Country]
    }

    private struct ContentRatings: Decodable {
        struct Country: Decodable { var iso_3166_1: String; var rating: String? }
        var results: [Country]
    }

    // The US certification (PG-13, TV-MA), if TMDB has one.
    func contentRating(_ type: MediaType, id: Int) async throws -> String? {
        if type == .movie {
            let data = try await get("api/tmdb/movie/\(id)/release_dates", as: ReleaseDates.self)
            return data.results.first { $0.iso_3166_1 == "US" }?.release_dates
                .compactMap(\.certification).first { !$0.isEmpty }
        }
        let data = try await get("api/tmdb/tv/\(id)/content_ratings", as: ContentRatings.self)
        return data.results.first { $0.iso_3166_1 == "US" }?.rating.flatMap { $0.isEmpty ? nil : $0 }
    }

    func season(showID: Int, number: Int) async throws -> SeasonDetails {
        try await get("api/tmdb/tv/\(showID)/season/\(number)", as: SeasonDetails.self)
    }

    func person(_ id: Int) async throws -> PersonDetails {
        try await get("api/tmdb/person/\(id)", as: PersonDetails.self)
    }

    func personCredits(_ id: Int) async throws -> [Media] {
        try await get("api/tmdb/person/\(id)/combined_credits", as: PersonCredits.self).cast
    }

    // MARK: Games

    func searchGames(_ query: String) async throws -> [Media] {
        try await get("api/games/search", ["q": query], as: [Failable<Media>].self, mediaType: .game).compactMap(\.value)
    }

    // The Worker's blend of IGDB popularity signals.
    func trendingGames() async throws -> [Media] {
        try await get("api/games/trending", as: [Failable<Media>].self, mediaType: .game).compactMap(\.value)
    }

    // The most anticipated games out in the next 30 days.
    func upcomingGames() async throws -> [Media] {
        try await get("api/games/upcoming", as: [Failable<Media>].self, mediaType: .game).compactMap(\.value)
    }

    func game(_ id: Int) async throws -> Media {
        try await get("api/games/\(id)", as: Media.self, mediaType: .game)
    }

    func steamPrice(_ appID: Int) async throws -> GamePrice? {
        try await get("api/prices/steam/\(appID)", ["region": "us"], as: GamePrice?.self)
    }

    // At most 50 per request, as the Worker allows.
    func steamPrices(_ appIDs: [Int]) async throws -> [GamePrice] {
        var prices: [GamePrice] = []
        let unique = Array(Set(appIDs)).sorted()
        for start in stride(from: 0, to: unique.count, by: 50) {
            let ids = unique[start..<min(start + 50, unique.count)].map(String.init).joined(separator: ",")
            prices += try await get("api/prices/steam", ["ids": ids, "region": "us"], as: [Failable<GamePrice>].self).compactMap(\.value)
        }
        return prices
    }

    // Movies and shows from TMDB, or a game from the Worker.
    func details(for key: MediaKey) async throws -> Media {
        switch key.type {
        case .game:
            guard key.source == .igdb else { throw Failure.notFound }
            return try await game(key.id)
        case .movie, .tv:
            return try await details(key.type, id: key.id)
        }
    }
}
