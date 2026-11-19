import Foundation
import XCTest
@testable import VoidCore

final class GamePricesTests: XCTestCase {
    private func game(_ title: String, retail: String? = "9.99", keyshop: String? = "4.20", url: String? = nil) -> [String: Any] {
        ["title": title, "url": url ?? "https://gg.deals/game/\(title.lowercased())/",
         "prices": ["currentRetail": retail as Any, "currentKeyshops": keyshop as Any, "historicalRetail": "0.99",
                    "historicalKeyshops": NSNull(), "currency": "USD"]]
    }

    private func body(_ data: Any, success: Bool = true) -> Data {
        try! JSONSerialization.data(withJSONObject: ["success": success, "data": data])
    }

    func testDecodeMatchesTheWorker() throws {
        let data = body([
            "620": game("Portal2"),
            "1": game("Free", retail: "0", keyshop: "1.00"),
            "2": game("Keys", retail: nil, keyshop: "3.50"),
            "3": game("Tie", retail: "5.00", keyshop: "5.00"),
            "4": game("None", retail: nil, keyshop: nil),
            "5": game("Bad", retail: "-1", keyshop: "x"),
            "6": game("OffSite", url: "https://evil.example/game/"),
            "7": NSNull(),
            "8": 42,
        ])
        let prices = try GGDealsAPI.decode([620, 1, 2, 3, 4, 5, 6, 7, 8, 9], data: data, status: 200)
        let byID = Dictionary(uniqueKeysWithValues: prices.map { ($0.steamAppId, $0) })
        XCTAssertEqual(prices.map(\.steamAppId), [620, 1, 2, 3, 4, 5])
        XCTAssertEqual(byID[620]?.lowestCurrent, .init(amount: "4.20", source: "keyshop"))
        XCTAssertEqual(byID[620]?.historicalRetail, "0.99")
        XCTAssertNil(byID[620]?.historicalKeyshops)
        XCTAssertEqual(byID[1]?.lowestCurrent, .init(amount: "0", source: "retail"))
        XCTAssertEqual(byID[2]?.lowestCurrent, .init(amount: "3.50", source: "keyshop"))
        XCTAssertEqual(byID[3]?.lowestCurrent, .init(amount: "5.00", source: "retail"))
        XCTAssertNil(byID[4]?.lowestCurrent)
        XCTAssertNil(byID[5]?.lowestCurrent)
    }

    func testDecodeErrors() {
        let keyError = try! JSONSerialization.data(withJSONObject: ["success": false, "data": ["message": "Invalid API key"]])
        XCTAssertThrowsError(try GGDealsAPI.decode([1], data: keyError, status: 400)) {
            XCTAssertEqual($0 as? GGDealsAPI.Failure, .invalidKey("Invalid API key"))
        }
        XCTAssertThrowsError(try GGDealsAPI.decode([1], data: Data(), status: 401)) {
            XCTAssertEqual($0 as? GGDealsAPI.Failure, .invalidKey(nil))
        }
        XCTAssertThrowsError(try GGDealsAPI.decode([1], data: Data(), status: 429)) {
            XCTAssertEqual($0 as? GGDealsAPI.Failure, .rateLimited)
        }
        XCTAssertThrowsError(try GGDealsAPI.decode([1], data: Data(), status: 400)) {
            XCTAssertEqual($0 as? GGDealsAPI.Failure, .status(400))
        }
        XCTAssertThrowsError(try GGDealsAPI.decode([1], data: body([:], success: false), status: 200)) {
            XCTAssertEqual($0 as? GGDealsAPI.Failure, .invalidResponse)
        }
    }

    func testCleanKey() {
        XCTAssertEqual(GGDealsAPI.cleanKey("  abc-DEF_123\n"), "abc-DEF_123")
        XCTAssertNil(GGDealsAPI.cleanKey(""))
        XCTAssertNil(GGDealsAPI.cleanKey("   "))
        XCTAssertNil(GGDealsAPI.cleanKey("has space"))
        XCTAssertNil(GGDealsAPI.cleanKey("a&b=c"))
        XCTAssertNil(GGDealsAPI.cleanKey("ключ"))
        XCTAssertNil(GGDealsAPI.cleanKey(String(repeating: "a", count: 201)))
    }

    func testCacheExpiresPricesAndMissesSeparately() async {
        final class Clock: @unchecked Sendable { var time = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let cache = PriceCache { clock.time }
        let price = GamePrice(steamAppId: 1, title: "A", url: "https://gg.deals/game/a/", currency: "USD")
        await cache.store(1, price)
        await cache.store(2, nil)

        var found = await cache.prices([1, 2, 3])
        XCTAssertEqual(found[1], .some(price))
        XCTAssertEqual(found[2], .some(nil))
        XCTAssertFalse(found.keys.contains(3))

        clock.time += PriceCache.missLifetime
        found = await cache.prices([1, 2])
        XCTAssertEqual(found[1], .some(price))
        XCTAssertFalse(found.keys.contains(2))

        clock.time += PriceCache.priceLifetime
        found = await cache.prices([1])
        XCTAssertTrue(found.isEmpty)
    }

    func testCachedPricesSkipTheNetwork() async throws {
        // No Worker address and no key: any network call would throw.
        let cache = PriceCache()
        let price = GamePrice(steamAppId: 7, title: "A", url: "https://gg.deals/game/a/", currency: "USD")
        await cache.store(7, price)
        await cache.store(8, nil)
        let prices = GamePrices(worker: VoidAPI(baseURL: nil), ownKey: nil, cache: cache)
        let found = try await prices.steamPrices([8, 7, 7])
        XCTAssertEqual(found, [price])
        let none = try await prices.steamPrice(8)
        XCTAssertNil(none)
        do {
            _ = try await prices.steamPrices([9])
            XCTFail("expected the uncached ID to need the Worker")
        } catch {
            XCTAssertEqual(error as? VoidAPI.Failure, .notConfigured)
        }
    }
}
