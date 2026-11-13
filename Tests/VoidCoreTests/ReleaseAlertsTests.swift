import XCTest
@testable import VoidCore

final class ReleaseAlertsTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    func at(_ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func entry(_ type: MediaType, id: Int, list: ListState = .playlist, release: String? = nil,
               next: EpisodeAir? = nil) -> (item: SyncedItem, media: Media) {
        let key = MediaKey(source: type == .game ? .igdb : .tmdb, type: type, id: id)
        var media = Media(id: id, mediaType: type, title: "Title \(id)", releaseDate: release)
        media.nextEpisodeToAir = next
        return (SyncedItem(key: key, title: media.title, releaseDate: release, list: list, addedAt: "2026-11-01T00:00:00.000Z"), media)
    }

    func testPlansUpcomingPlaylistReleasesAtNine() {
        let entries = [
            entry(.tv, id: 1, next: EpisodeAir(airDate: "2026-11-18", episodeNumber: 5, seasonNumber: 3, name: "The Forge")),
            entry(.movie, id: 2, release: "2026-11-14"),
            entry(.game, id: 3, release: "2026-12-01"),
            entry(.movie, id: 4, release: "2026-11-01"),               // already out
            entry(.movie, id: 5, list: .history, release: "2026-11-20"), // not on the Playlist
            entry(.tv, id: 6, next: EpisodeAir(airDate: "2026-11-13", episodeNumber: 2, seasonNumber: 1, name: "Episode 2")),
        ]
        let alerts = ReleaseAlerts.plan(entries, now: at(13, hour: 10), calendar: calendar)
        XCTAssertEqual(alerts.map(\.day), ["2026-11-14", "2026-11-18", "2026-12-01"], "soonest first; today's 9 AM has passed")
        XCTAssertEqual(alerts[0].body, "Out today.")
        XCTAssertEqual(alerts[1].body, "New episode today: S3E5 · The Forge")
        XCTAssertEqual(alerts[1].id, "release.item.tmdb.tv.1.2026-11-18")
        XCTAssertEqual(calendar.component(.hour, from: alerts[1].fireDate), 9)
        XCTAssertEqual(alerts[2].body, "Out today. Time to play.")

        // Before 9 AM, today's episode still gets one, without TMDB's placeholder name.
        let early = ReleaseAlerts.plan(entries, now: at(13, hour: 8), calendar: calendar)
        XCTAssertEqual(early.first?.body, "New episode today: S1E2")
    }

    func testKeepsTheSoonestWithinTheLimit() {
        let entries = (1...80).map { entry(.movie, id: $0, release: String(format: "2027-01-%02d", $0 % 28 + 1)) }
        let alerts = ReleaseAlerts.plan(entries, now: at(13, hour: 10), calendar: calendar)
        XCTAssertEqual(alerts.count, ReleaseAlerts.limit)
        XCTAssertEqual(alerts.first?.day, "2027-01-01")
    }

    func testAiringPlaylistShowsRefreshDaily() {
        XCTAssertEqual(LibraryRules.detailsMaxAge(type: .tv, list: .playlist, status: "Returning Series"), 24 * 60 * 60)
        XCTAssertEqual(LibraryRules.detailsMaxAge(type: .tv, list: .playlist, status: "Ended"), 7 * 24 * 60 * 60)
        XCTAssertEqual(LibraryRules.detailsMaxAge(type: .tv, list: .history, status: "Returning Series"), 7 * 24 * 60 * 60)
        XCTAssertEqual(LibraryRules.detailsMaxAge(type: .movie, list: .playlist, status: nil), 7 * 24 * 60 * 60)
    }
}
