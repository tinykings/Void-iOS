import Foundation

// Media as TMDB and the [void] API Worker describe it. Plain values, no UI or
// CloudKit, so this compiles (and is tested) anywhere Swift runs.

enum MediaType: String, Codable, CaseIterable, Hashable, Sendable {
    case movie, tv, game

    var label: String {
        switch self {
        case .movie: "Movies"
        case .tv: "Shows"
        case .game: "Games"
        }
    }

    var singular: String {
        switch self {
        case .movie: "Movie"
        case .tv: "Show"
        case .game: "Game"
        }
    }
}

enum MediaSource: String, Codable, Hashable, Sendable {
    case tmdb, igdb, rawg, steam

    static func `default`(for type: MediaType) -> MediaSource { type == .game ? .igdb : .tmdb }

    var label: String {
        switch self {
        case .tmdb: "TMDB"
        case .igdb: "IGDB"
        case .rawg: "RAWG"
        case .steam: "Steam"
        }
    }
}

// Identifies an item across lists, devices and the CloudKit record name.
struct MediaKey: Hashable, Codable, Sendable, Comparable {
    var source: MediaSource
    var type: MediaType
    var id: Int

    // `item.tmdb.tv.1399` (docs/sync-schema.md).
    var recordName: String { "item.\(source.rawValue).\(type.rawValue).\(id)" }

    init(source: MediaSource, type: MediaType, id: Int) {
        self.source = source
        self.type = type
        self.id = id
    }

    init?(recordName: String) {
        let parts = recordName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "item",
              let source = MediaSource(rawValue: String(parts[1])),
              let type = MediaType(rawValue: String(parts[2])),
              parts[3].allSatisfy(\.isASCII), parts[3].allSatisfy(\.isNumber),
              let id = Int(parts[3]), id > 0, String(id) == parts[3] else { return nil }
        guard (type == .game) == (source != .tmdb) else { return nil }
        self.init(source: source, type: type, id: id)
    }

    static func < (a: MediaKey, b: MediaKey) -> Bool { a.recordName < b.recordName }
}

enum ImageURL {
    // TMDB paths (`/abc.jpg`) get TMDB's image host; IGDB images are already URLs.
    static func make(_ path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("https://") || path.hasPrefix("http://") {
            guard let url = URL(string: path), url.host != nil else { return nil }
            return url
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

struct Video: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var key: String
    var name: String
    var site: String
    var type: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lenient(String.self, .key) ?? ""
        id = c.lenient(String.self, .id) ?? key
        name = c.lenient(String.self, .name) ?? "Trailer"
        site = c.lenient(String.self, .site) ?? ""
        type = c.lenient(String.self, .type) ?? ""
    }

    var youTubeURL: URL? {
        guard site == "YouTube", !key.isEmpty,
              key.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }
}

struct WatchProvider: Codable, Hashable, Identifiable, Sendable {
    var providerID: Int
    var providerName: String
    var logoPath: String?
    var id: Int { providerID }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id", providerName = "provider_name", logoPath = "logo_path"
    }

    init(providerID: Int, providerName: String, logoPath: String?) {
        self.providerID = providerID
        self.providerName = providerName
        self.logoPath = logoPath
    }
}

struct WatchProvidersResponse: Decodable, Sendable {
    struct Country: Decodable, Sendable {
        var link: String?
        var free: [WatchProvider]?
        var flatrate: [WatchProvider]?
    }
    var results: [String: Country]
}

struct CastMember: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var character: String?
    var profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character, profilePath = "profile_path"
    }
}

struct CreditsResponse: Decodable, Sendable {
    var cast: [CastMember]
}

struct SeasonSummary: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var seasonNumber: Int
    var episodeCount: Int?
    var airDate: String?
    var posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, seasonNumber = "season_number", episodeCount = "episode_count",
             airDate = "air_date", posterPath = "poster_path"
    }
}

struct Episode: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var overview: String?
    var airDate: String?
    var episodeNumber: Int
    var seasonNumber: Int
    var stillPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, airDate = "air_date", episodeNumber = "episode_number",
             seasonNumber = "season_number", stillPath = "still_path"
    }
}

struct SeasonDetails: Decodable, Sendable {
    var name: String
    var overview: String?
    var seasonNumber: Int
    var episodes: [Episode]

    enum CodingKeys: String, CodingKey {
        case name, overview, seasonNumber = "season_number", episodes
    }
}

struct EpisodeAir: Codable, Hashable, Sendable {
    var airDate: String?
    var episodeNumber: Int?
    var seasonNumber: Int?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case airDate = "air_date", episodeNumber = "episode_number", seasonNumber = "season_number", name
    }
}

struct PersonDetails: Decodable, Sendable {
    var id: Int
    var name: String
    var biography: String?
    var birthday: String?
    var placeOfBirth: String?
    var profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, placeOfBirth = "place_of_birth", profilePath = "profile_path"
    }
}

struct PersonCredits: Decodable, Sendable {
    var cast: [Media]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Combined credits mix movies and shows; anything else is skipped.
        let items = c.lenient([Failable<Media>].self, .cast) ?? []
        cast = items.compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case cast }
}

struct GamePrice: Codable, Hashable, Sendable {
    struct Lowest: Codable, Hashable, Sendable {
        var amount: String
        var source: String
    }
    var steamAppId: Int
    var title: String
    var url: String
    var currency: String
    var lowestCurrent: Lowest?
    var historicalRetail: String?
    var historicalKeyshops: String?
}

struct Media: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var mediaType: MediaType
    var source: MediaSource
    var title: String
    var posterPath: String?
    var backdropPath: String?
    var overview: String = ""
    var tagline: String?
    var releaseDate: String?
    var voteAverage: Double = 0
    var voteCount: Int = 0
    var popularity: Double = 0
    var status: String?
    var genres: [String] = []
    var runtime: Int?
    var numberOfSeasons: Int?
    var numberOfEpisodes: Int?
    var seasons: [SeasonSummary] = []
    var nextEpisodeToAir: EpisodeAir?
    var videos: [Video] = []
    var screenshots: [String] = []
    // Games, from the Worker.
    var platforms: [String] = []
    var steamAppId: Int?
    var website: String?
    var sourceURL: String?
    var playtimeMain: Double?
    var playtimeExtra: Double?
    var playtimeCompletionist: Double?
    var hltbURL: String?

    var key: MediaKey { MediaKey(source: source, type: mediaType, id: id) }

    init(id: Int, mediaType: MediaType, source: MediaSource? = nil, title: String,
         posterPath: String? = nil, releaseDate: String? = nil) {
        self.id = id
        self.mediaType = mediaType
        self.source = source ?? .default(for: mediaType)
        self.title = title
        self.posterPath = posterPath
        self.releaseDate = releaseDate
    }

    enum CodingKeys: String, CodingKey {
        case id, mediaType = "media_type", source, title, name, posterPath = "poster_path",
             backdropPath = "backdrop_path", overview, tagline, releaseDate = "release_date",
             firstAirDate = "first_air_date", voteAverage = "vote_average", voteCount = "vote_count",
             popularity, status, genres, runtime, episodeRunTime = "episode_run_time",
             numberOfSeasons = "number_of_seasons", numberOfEpisodes = "number_of_episodes", seasons,
             nextEpisodeToAir = "next_episode_to_air", videos, images, screenshots, platforms,
             steamAppId = "steam_app_id", website, sourceURL = "source_url", playtimeMain = "playtime_main",
             playtimeExtra = "playtime_extra", playtimeCompletionist = "playtime_completionist",
             hltbURL = "hltb_url"
    }

    private struct NamedItem: Decodable { var name: String }
    private struct VideoResults: Decodable { var results: [Video] }
    private struct Images: Decodable {
        struct Image: Decodable { var file_path: String }
        var backdrops: [Image]?
    }

    // Reads TMDB's shapes (search results, details with appended videos/images, credits)
    // and the Worker's game shape, as well as what `encode` writes. A details response
    // has no media_type; the decoder's userInfo supplies it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        guard let type = c.lenient(MediaType.self, .mediaType) ?? decoder.userInfo[.mediaType] as? MediaType else {
            throw DecodingError.dataCorruptedError(forKey: .mediaType, in: c, debugDescription: "Not a movie, show or game")
        }
        mediaType = type
        source = c.lenient(MediaSource.self, .source) ?? .default(for: type)
        title = c.lenient(String.self, .title) ?? c.lenient(String.self, .name) ?? "Unknown title"
        posterPath = c.lenient(String.self, .posterPath)
        backdropPath = c.lenient(String.self, .backdropPath)
        overview = c.lenient(String.self, .overview) ?? ""
        tagline = c.lenient(String.self, .tagline).flatMap { $0.isEmpty ? nil : $0 }
        releaseDate = (c.lenient(String.self, .releaseDate) ?? c.lenient(String.self, .firstAirDate))
            .flatMap { $0.isEmpty ? nil : $0 }
        voteAverage = c.lenient(Double.self, .voteAverage) ?? 0
        voteCount = c.lenient(Int.self, .voteCount) ?? 0
        popularity = c.lenient(Double.self, .popularity) ?? 0
        status = c.lenient(String.self, .status)
        genres = c.lenient([String].self, .genres) ?? c.lenient([NamedItem].self, .genres)?.map(\.name) ?? []
        runtime = c.lenient(Int.self, .runtime) ?? c.lenient([Int].self, .episodeRunTime)?.first
        numberOfSeasons = c.lenient(Int.self, .numberOfSeasons)
        numberOfEpisodes = c.lenient(Int.self, .numberOfEpisodes)
        seasons = c.lenient([SeasonSummary].self, .seasons) ?? []
        nextEpisodeToAir = c.lenient(EpisodeAir.self, .nextEpisodeToAir)
        videos = c.lenient([Video].self, .videos) ?? c.lenient(VideoResults.self, .videos)?.results ?? []
        screenshots = c.lenient([String].self, .screenshots)
            ?? (c.lenient(Images.self, .images)?.backdrops ?? []).prefix(3).map(\.file_path)
        platforms = c.lenient([String].self, .platforms) ?? []
        steamAppId = c.lenient(Int.self, .steamAppId)
        website = c.lenient(String.self, .website)
        sourceURL = c.lenient(String.self, .sourceURL)
        playtimeMain = c.lenient(Double.self, .playtimeMain)
        playtimeExtra = c.lenient(Double.self, .playtimeExtra)
        playtimeCompletionist = c.lenient(Double.self, .playtimeCompletionist)
        hltbURL = c.lenient(String.self, .hltbURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encode(source, forKey: .source)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(posterPath, forKey: .posterPath)
        try c.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try c.encode(overview, forKey: .overview)
        try c.encodeIfPresent(tagline, forKey: .tagline)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encode(voteAverage, forKey: .voteAverage)
        try c.encode(voteCount, forKey: .voteCount)
        try c.encode(popularity, forKey: .popularity)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(numberOfSeasons, forKey: .numberOfSeasons)
        try c.encodeIfPresent(numberOfEpisodes, forKey: .numberOfEpisodes)
        try c.encode(seasons, forKey: .seasons)
        try c.encodeIfPresent(nextEpisodeToAir, forKey: .nextEpisodeToAir)
        try c.encode(screenshots, forKey: .screenshots)
        try c.encode(platforms, forKey: .platforms)
        try c.encodeIfPresent(steamAppId, forKey: .steamAppId)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encodeIfPresent(playtimeMain, forKey: .playtimeMain)
        try c.encodeIfPresent(playtimeExtra, forKey: .playtimeExtra)
        try c.encodeIfPresent(playtimeCompletionist, forKey: .playtimeCompletionist)
        try c.encodeIfPresent(hltbURL, forKey: .hltbURL)
        // Videos aren't cached: they're only shown on the details screen, which refetches.
    }

    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
}

extension CodingUserInfoKey {
    static let mediaType = CodingUserInfoKey(rawValue: "void.mediaType")!
}

// Decodes an element if it can, so one odd entry doesn't fail a whole list.
struct Failable<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    // A present, well-typed value, or nil (absent, null or another type).
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
