import XCTest
@testable import VoidCore

final class LibraryRulesTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    func now(_ day: Int, hour: Int = 23) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testLocalDayWindow() {
        XCTAssertTrue(LibraryRules.isInLocalDayWindow("2026-11-13", now: now(13), windowDays: 7, calendar: calendar))
        XCTAssertTrue(LibraryRules.isInLocalDayWindow("2026-11-20", now: now(13), windowDays: 7, calendar: calendar))
        XCTAssertFalse(LibraryRules.isInLocalDayWindow("2026-11-21", now: now(13), windowDays: 7, calendar: calendar))
        XCTAssertFalse(LibraryRules.isInLocalDayWindow("2026-11-12", now: now(13, hour: 0), windowDays: 7, calendar: calendar))
        XCTAssertFalse(LibraryRules.isInLocalDayWindow("2026-02-30", now: now(13), windowDays: 7, calendar: calendar))
        XCTAssertEqual(LibraryRules.returnAirDate(nextEpisodeAirDate: "2026-11-15", now: now(13), calendar: calendar), "2026-11-15")
        XCTAssertNil(LibraryRules.returnAirDate(nextEpisodeAirDate: nil, now: now(13), calendar: calendar))
    }

    func testReturnCheck() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(LibraryRules.needsReturnCheck(status: "Returning Series", lastChecked: nil, now: t))
        XCTAssertFalse(LibraryRules.needsReturnCheck(status: "Ended", lastChecked: nil, now: t))
        XCTAssertFalse(LibraryRules.needsReturnCheck(status: "Canceled", lastChecked: nil, now: t))
        XCTAssertFalse(LibraryRules.needsReturnCheck(status: nil, lastChecked: t.addingTimeInterval(-3600), now: t))
        XCTAssertTrue(LibraryRules.needsReturnCheck(status: nil, lastChecked: t.addingTimeInterval(-90000), now: t))
    }

    func testPlaylistSort() {
        let today = Date()
        func day(_ offset: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        let items: [(String, LibraryRules.SortInput)] = [
            ("old movie", .init(type: .movie, releaseDate: "1999-01-01", addedAt: "2026-01-02T00:00:00.000Z")),
            ("new add", .init(type: .movie, releaseDate: "1990-01-01", addedAt: "2026-05-02T00:00:00.000Z")),
            ("show soon", .init(type: .tv, releaseDate: "2011-01-01", nextEpisodeAirDate: day(5), addedAt: "2020-01-01T00:00:00.000Z")),
            ("game soon", .init(type: .game, releaseDate: day(2), addedAt: "2020-01-01T00:00:00.000Z")),
            ("ended show", .init(type: .tv, releaseDate: day(1), addedAt: "2019-01-01T00:00:00.000Z")),
            ("show far off", .init(type: .tv, releaseDate: "2013-01-01", nextEpisodeAirDate: day(238), addedAt: "2018-01-01T00:00:00.000Z")),
        ]
        let sorted = LibraryRules.sortPlaylist(items) { $0.1 }.map(\.0)
        XCTAssertEqual(sorted, ["game soon", "show soon", "new add", "old movie", "ended show", "show far off"])
    }

    func testSearchRanking() {
        func m(_ title: String, _ popularity: Double = 1) -> Media {
            var media = Media(id: title.count, mediaType: .movie, title: title)
            media.popularity = popularity
            return media
        }
        let ranked = LibraryRules.rankSearchResults([m("The Dune Saga"), m("Dune: Part Two", 50), m("Dune", 10), m("Unrelated")], query: "dune")
        XCTAssertEqual(ranked.map(\.title), ["Dune", "Dune: Part Two", "The Dune Saga", "Unrelated"])
        XCTAssertEqual(LibraryRules.normalizedSearchText("  Amélie — Le Fabuleux! "), "amelie le fabuleux")
    }

    func testStreamingProviders() throws {
        let json = """
        {"results":{"US":{"flatrate":[
          {"provider_id":8,"provider_name":"Netflix","logo_path":"/n.jpg"},
          {"provider_id":1796,"provider_name":"Netflix Standard with Ads","logo_path":"/n2.jpg"},
          {"provider_id":9,"provider_name":"Amazon Prime Video","logo_path":"/a.jpg"},
          {"provider_id":2100,"provider_name":"Amazon Prime Video with Ads","logo_path":"/a2.jpg"},
          {"provider_id":582,"provider_name":"Paramount+ Amazon Channel","logo_path":"/p.jpg"},
          {"provider_id":15,"provider_name":"Hulu","logo_path":"/h.jpg"}],
         "free":[{"provider_id":73,"provider_name":"Tubi TV","logo_path":"/t.jpg"}]}}}
        """
        let response = try JSONDecoder().decode(WatchProvidersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(LibraryRules.usStreamingProviders(response).map(\.providerName), ["Tubi TV", "Netflix", "Amazon Prime Video", "Hulu"])
    }

    func testGroupingAndDeals() {
        let netflix = WatchProvider(providerID: 8, providerName: "Netflix", logoPath: nil)
        let hulu = WatchProvider(providerID: 15, providerName: "Hulu", logoPath: nil)
        let groups = LibraryRules.groupByProvider([("B", [netflix]), ("A", [netflix, hulu])]) { $0 }
        XCTAssertEqual(groups.map(\.provider.providerName), ["Netflix", "Hulu"])
        XCTAssertEqual(groups[0].items, ["A", "B"])

        func price(_ amount: String?) -> GamePrice {
            GamePrice(steamAppId: 1, title: "", url: "", currency: "USD", lowestCurrent: amount.map { .init(amount: $0, source: "retail") })
        }
        let deals = LibraryRules.sortDeals([("x", price("9.99")), ("y", price("4.20")), ("z", price(nil))]) { $0 }
        XCTAssertEqual(deals.map(\.item), ["y", "x", "z"])
        XCTAssertEqual(LibraryRules.formatPrice(price("4.2")), "$4.20")

        var media = Media(id: 3, mediaType: .game, title: "G")
        media.sourceURL = "https://store.steampowered.com/app/620/Portal_2/"
        XCTAssertEqual(LibraryRules.steamAppID(media), 620)
        media.steamAppId = 400
        XCTAssertEqual(LibraryRules.steamAppID(media), 400)
    }
}
