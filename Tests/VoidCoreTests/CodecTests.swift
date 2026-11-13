import XCTest
@testable import VoidCore

final class CodecTests: XCTestCase {
    func testRecordNames() {
        let key = MediaKey(source: .tmdb, type: .tv, id: 1399)
        XCTAssertEqual(key.recordName, "item.tmdb.tv.1399")
        XCTAssertEqual(MediaKey(recordName: "item.tmdb.tv.1399"), key)
        XCTAssertEqual(MediaKey(recordName: "item.igdb.game.7"), MediaKey(source: .igdb, type: .game, id: 7))
        for bad in ["item.tmdb.game.1", "item.igdb.movie.1", "item.tmdb.tv.01", "item.tmdb.tv.-1", "item.tmdb.tv", "saved.x", "item.tmdb.tv.1.2"] {
            XCTAssertNil(MediaKey(recordName: bad), bad)
        }
    }

    func testFieldsRoundTrip() {
        let item = SyncedItem(key: MediaKey(source: .igdb, type: .game, id: 5), title: "Hades", image: "https://images.igdb.com/a.jpg",
                              releaseDate: "2020-09-17", list: .playlist, addedAt: "2026-11-13T22:04:05.123Z",
                              isFavorite: true, isPurchased: true, rating: 4, returnedFor: nil)
        XCTAssertEqual(SyncCodec.decode(recordName: item.key.recordName, fields: SyncCodec.fields(item)), item)
    }

    func testDecodeRejectsWhatItCantRead() {
        let item = SyncedItem(key: MediaKey(source: .tmdb, type: .movie, id: 5), title: "Dune", list: .history, addedAt: "2026-11-13T22:04:05.123Z")
        var fields = SyncCodec.fields(item)
        XCTAssertNotNil(SyncCodec.decode(recordName: "item.tmdb.movie.5", fields: fields))
        XCTAssertNil(SyncCodec.decode(recordName: "item.tmdb.movie.6", fields: fields), "id must match the name")
        fields["schemaVersion"] = .int(2)
        XCTAssertNil(SyncCodec.decode(recordName: "item.tmdb.movie.5", fields: fields), "newer schema is left alone")
        fields = SyncCodec.fields(item)
        fields["addedAt"] = .string("yesterday")
        XCTAssertNil(SyncCodec.decode(recordName: "item.tmdb.movie.5", fields: fields))
        fields = SyncCodec.fields(item)
        fields["image"] = .string("javascript:alert(1)")
        fields["releaseDate"] = .string("2026-02-30")
        fields["isPurchased"] = .int(1)
        let decoded = SyncCodec.decode(recordName: "item.tmdb.movie.5", fields: fields)
        XCTAssertNil(decoded?.image)
        XCTAssertNil(decoded?.releaseDate)
        XCTAssertEqual(decoded?.isPurchased, false, "only games are purchased")
    }

    func testISO() {
        let date = SyncCodec.date("2026-11-13T22:04:05.123Z")!
        XCTAssertEqual(SyncCodec.iso(date), "2026-11-13T22:04:05.123Z")
        XCTAssertNotNil(SyncCodec.date("2026-11-13T22:04:05Z"))
        XCTAssertNil(SyncCodec.date("2026-11-13 22:04:05"))
    }

    func testLegacyImport() throws {
        let json = """
        {"version":4,
         "watchlist":[{"id":1399,"title":"Game of Thrones","media_type":"tv","source":"tmdb","date_added":"2025-01-02T03:04:05.678Z","image":"/got.jpg"},
                      {"id":9,"title":"Hades","media_type":"game","date_added":"2025-01-02","isPurchased":true}],
         "watched":[{"id":5,"title":"Dune","media_type":"movie","date_added":"2024-05-06T00:00:00.000Z","release_date":"2021-10-22","rating":4},
                    {"id":1399,"title":"dupe","media_type":"tv","date_added":"2024-05-06T00:00:00.000Z"},
                    {"id":"bad"}],
         "favorites":[{"id":5,"title":"Dune","media_type":"movie","date_added":"2024-05-06T00:00:00.000Z"}],
         "playedEpisodes":{}}
        """
        let items = try LegacyImport.items(from: Data(json.utf8))
        XCTAssertEqual(items.map(\.key.recordName), ["item.tmdb.tv.1399", "item.igdb.game.9", "item.tmdb.movie.5"])
        XCTAssertEqual(items[0].list, .playlist)
        XCTAssertEqual(items[0].addedAt, "2025-01-02T03:04:05.678Z")
        XCTAssertEqual(items[1].isPurchased, true)
        XCTAssertEqual(items[1].addedAt, "2025-01-02T00:00:00.000Z")
        XCTAssertEqual(items[2].list, .history)
        XCTAssertEqual(items[2].isFavorite, true)
        XCTAssertEqual(items[2].rating, 4)
        XCTAssertThrowsError(try LegacyImport.items(from: Data("{}".utf8)))
    }

    func testMediaDecodesTMDBAndWorkerShapes() throws {
        let details = """
        {"id":1399,"name":"Game of Thrones","first_air_date":"2011-04-17","genres":[{"id":1,"name":"Drama"}],
         "status":"Ended","episode_run_time":[60],"next_episode_to_air":null,
         "videos":{"results":[{"id":"v","key":"abc_123","name":"Trailer","site":"YouTube","type":"Trailer"}]},
         "images":{"backdrops":[{"file_path":"/a.jpg"},{"file_path":"/b.jpg"}]},
         "seasons":[{"id":3,"name":"Season 1","season_number":1,"episode_count":10,"air_date":"2011-04-17","poster_path":null}]}
        """
        let decoder = JSONDecoder()
        decoder.userInfo[.mediaType] = MediaType.tv
        let show = try decoder.decode(Media.self, from: Data(details.utf8))
        XCTAssertEqual(show.title, "Game of Thrones")
        XCTAssertEqual(show.releaseDate, "2011-04-17")
        XCTAssertEqual(show.genres, ["Drama"])
        XCTAssertEqual(show.runtime, 60)
        XCTAssertEqual(show.videos.first?.youTubeURL?.absoluteString, "https://www.youtube.com/watch?v=abc_123")
        XCTAssertEqual(show.screenshots, ["/a.jpg", "/b.jpg"])
        XCTAssertEqual(show.seasons.first?.episodeCount, 10)

        let cached = try JSONDecoder().decode(Media.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(cached.key, show.key)
        XCTAssertEqual(cached.genres, ["Drama"])
        XCTAssertEqual(cached.status, "Ended")

        let game = """
        {"id":7,"title":"Hades","name":"Hades","poster_path":"https://images.igdb.com/x.jpg","backdrop_path":null,"overview":"",
         "release_date":"2020-09-17","vote_average":9.3,"vote_count":10,"popularity":10,"media_type":"game","source":"igdb",
         "platforms":["PC"],"genres":["Roguelike"],"steam_app_id":1145360,"screenshots":[],"videos":[]}
        """
        let decoded = try JSONDecoder().decode(Media.self, from: Data(game.utf8))
        XCTAssertEqual(decoded.key, MediaKey(source: .igdb, type: .game, id: 7))
        XCTAssertEqual(decoded.steamAppId, 1145360)
        XCTAssertEqual(ImageURL.make(decoded.posterPath)?.host, "images.igdb.com")
        XCTAssertEqual(ImageURL.make("/a.jpg", size: "w500")?.absoluteString, "https://image.tmdb.org/t/p/w500/a.jpg")

        let person = """
        {"cast":[{"id":1,"media_type":"movie","title":"A"},{"id":2,"media_type":"person","name":"B"},{"id":3,"media_type":"tv","name":"C"}]}
        """
        XCTAssertEqual(try JSONDecoder().decode(PersonCredits.self, from: Data(person.utf8)).cast.map(\.title), ["A", "C"])
    }
}
