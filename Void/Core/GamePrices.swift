import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// GG.deals prices, by Steam App ID. With the user's own GG.deals API key the app asks
// GG.deals directly and spends only that key's allowance; without one it goes through
// the Worker, whose key is shared by everyone and can run out at busy times.
struct GamePrices: Sendable {
    enum Failure: Error, LocalizedError, Equatable {
        // The shared key is out of allowance for now.
        case sharedBusy
        // The user's own key is out of allowance for now.
        case ownKeyBusy
        case invalidKey(String?)

        var errorDescription: String? {
            switch self {
            case .sharedBusy: "Prices are busy right now. Try again in a minute, or add your own GG.deals key in Settings."
            case .ownKeyBusy: "Your GG.deals key has reached its limit for now. Try again in a minute."
            case .invalidKey(let message): message.map { "GG.deals didn't accept your key: \($0)" }
                ?? "GG.deals didn't accept your key. Check it in Settings."
            }
        }
    }

    var worker: VoidAPI
    var ownKey: GGDealsAPI?
    var cache: PriceCache

    func steamPrices(_ appIDs: [Int]) async throws -> [GamePrice] {
        let unique = Array(Set(appIDs.filter { $0 > 0 })).sorted()
        var found = await cache.prices(unique)
        let missing = unique.filter { found[$0] == nil }
        if !missing.isEmpty {
            let fetched = try await fetch(missing)
            let byID = Dictionary(fetched.map { ($0.steamAppId, $0) }, uniquingKeysWith: { a, _ in a })
            for id in missing {
                await cache.store(id, byID[id])
                found[id] = .some(byID[id])
            }
        }
        return unique.compactMap { found[$0] ?? nil }
    }

    func steamPrice(_ appID: Int) async throws -> GamePrice? {
        try await steamPrices([appID]).first
    }

    private func fetch(_ appIDs: [Int]) async throws -> [GamePrice] {
        if let ownKey {
            do { return try await ownKey.steamPrices(appIDs) }
            catch GGDealsAPI.Failure.rateLimited { throw Failure.ownKeyBusy }
            catch GGDealsAPI.Failure.invalidKey(let message) { throw Failure.invalidKey(message) }
        }
        do { return try await worker.steamPrices(appIDs) }
        catch VoidAPI.Failure.rateLimited { throw Failure.sharedBusy }
    }
}

// Prices seen recently on this device, so reopening Deals or a game doesn't spend
// allowance again. A game GG.deals has no price for is remembered for less time.
actor PriceCache {
    static let priceLifetime: TimeInterval = 60 * 60
    static let missLifetime: TimeInterval = 60 * 10

    private var entries: [Int: (price: GamePrice?, at: Date)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    // For each cached ID: `.some(price)`, or `.some(nil)` for a known miss.
    func prices(_ appIDs: [Int]) -> [Int: GamePrice?] {
        var result: [Int: GamePrice?] = [:]
        let time = now()
        for id in appIDs {
            guard let entry = entries[id] else { continue }
            let lifetime = entry.price == nil ? Self.missLifetime : Self.priceLifetime
            if time.timeIntervalSince(entry.at) < lifetime { result[id] = .some(entry.price) }
            else { entries[id] = nil }
        }
        return result
    }

    func store(_ appID: Int, _ price: GamePrice?) { entries[appID] = (price, now()) }

    func removeAll() { entries.removeAll() }
}

// Direct calls to the GG.deals Prices API with the user's own key. The response is
// checked the same way the Worker checks it (worker/src/index.ts).
struct GGDealsAPI: Sendable {
    enum Failure: Error, LocalizedError, Equatable {
        case invalidKey(String?)
        case rateLimited
        case status(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidKey(let message): message.map { "GG.deals didn't accept the key: \($0)" } ?? "GG.deals didn't accept the key."
            case .rateLimited: "This key has reached its GG.deals limit for now. Try again in a minute."
            case .status(let code): "GG.deals returned an error (\(code))."
            case .invalidResponse: "GG.deals sent something unexpected."
            }
        }
    }

    static let pricesURL = URL(string: "https://api.gg.deals/v1/prices/by-steam-app-id/")!
    // GG.deals allows 100 a request, and 100 a minute per key: smaller batches leave
    // room for a second screen in the same minute.
    static let batchSize = 50

    var key: String
    var region = "us"
    var session: URLSession = .shared

    // Trimmed, or nil if it can't be a key.
    static func cleanKey(_ value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 200,
              key.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) || "-_".unicodeScalars.contains($0) })
        else { return nil }
        return key
    }

    func steamPrices(_ appIDs: [Int]) async throws -> [GamePrice] {
        var prices: [GamePrice] = []
        let unique = Array(Set(appIDs)).sorted()
        for start in stride(from: 0, to: unique.count, by: Self.batchSize) {
            prices += try await batch(Array(unique[start..<min(start + Self.batchSize, unique.count)]))
        }
        return prices
    }

    private func batch(_ appIDs: [Int]) async throws -> [GamePrice] {
        var components = URLComponents(url: Self.pricesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ids", value: appIDs.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "region", value: region),
        ]
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No retries: every ID counts against the key's allowance, even on failure.
        let (data, response) = try await session.data(for: request)
        return try Self.decode(appIDs, data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func decode(_ appIDs: [Int], data: Data, status: Int) throws -> [GamePrice] {
        let body = try? JSONDecoder().decode(Response.self, from: data)
        switch status {
        case 200..<300: break
        case 429: throw Failure.rateLimited
        case 401, 403: throw Failure.invalidKey(body?.errorMessage)
        case 400 where body?.errorMessage?.localizedCaseInsensitiveContains("key") == true:
            throw Failure.invalidKey(body?.errorMessage)
        default: throw Failure.status(status)
        }
        guard let body, body.success == true, let games = body.games else { throw Failure.invalidResponse }
        return appIDs.compactMap { id in (games[String(id)] ?? nil).flatMap { normalize(steamAppId: id, $0) } }
    }

    static func normalize(steamAppId: Int, _ game: RawGame) -> GamePrice? {
        guard let title = game.title, let url = game.url.flatMap(ggDealsURL),
              let currency = game.prices?.currency, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
        else { return nil }
        let retail = amount(game.prices?.currentRetail)
        let keyshop = amount(game.prices?.currentKeyshops)
        let lowest: GamePrice.Lowest?
        switch (retail, keyshop) {
        case (nil, nil): lowest = nil
        case let (r?, k?): lowest = Double(r)! <= Double(k)! ? .init(amount: r, source: "retail") : .init(amount: k, source: "keyshop")
        case let (r?, nil): lowest = .init(amount: r, source: "retail")
        case let (nil, k?): lowest = .init(amount: k, source: "keyshop")
        }
        return GamePrice(steamAppId: steamAppId, title: title, url: url, currency: currency, lowestCurrent: lowest,
                         historicalRetail: amount(game.prices?.historicalRetail),
                         historicalKeyshops: amount(game.prices?.historicalKeyshops))
    }

    // A non-negative decimal string, as GG.deals sends them.
    private static func amount(_ value: String?) -> String? {
        guard let value, value.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    // Only https links on gg.deals itself.
    private static func ggDealsURL(_ value: String) -> String? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "gg.deals" || url.host == "www.gg.deals" else { return nil }
        return url.absoluteString
    }

    struct RawGame: Decodable {
        struct Prices: Decodable {
            var currentRetail: String?
            var currentKeyshops: String?
            var historicalRetail: String?
            var historicalKeyshops: String?
            var currency: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                currentRetail = try? c.decodeIfPresent(String.self, forKey: .currentRetail)
                currentKeyshops = try? c.decodeIfPresent(String.self, forKey: .currentKeyshops)
                historicalRetail = try? c.decodeIfPresent(String.self, forKey: .historicalRetail)
                historicalKeyshops = try? c.decodeIfPresent(String.self, forKey: .historicalKeyshops)
                currency = try? c.decodeIfPresent(String.self, forKey: .currency)
            }

            enum CodingKeys: String, CodingKey { case currentRetail, currentKeyshops, historicalRetail, historicalKeyshops, currency }
        }
        var title: String?
        var url: String?
        var prices: Prices?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            prices = try? c.decodeIfPresent(Prices.self, forKey: .prices)
        }

        enum CodingKeys: String, CodingKey { case title, url, prices }
    }

    // `data` maps IDs to games (or null) on success, and holds the error otherwise.
    private struct Response: Decodable {
        var success: Bool?
        var games: [String: RawGame?]?
        var errorMessage: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            success = try? c.decodeIfPresent(Bool.self, forKey: .success)
            if let games = try? c.decodeIfPresent([String: Failable<RawGame>?].self, forKey: .data) {
                self.games = games.mapValues { $0?.value }
            }
            errorMessage = (try? c.decodeIfPresent(ErrorBody.self, forKey: .data))?.message
                ?? (try? c.decodeIfPresent(String.self, forKey: .message))
        }

        private struct ErrorBody: Decodable { var message: String? }
        enum CodingKeys: String, CodingKey { case success, data, message }
    }
}
