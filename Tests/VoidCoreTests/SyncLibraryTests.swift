import XCTest
@testable import VoidCore

final class SyncLibraryTests: XCTestCase {
    let show = Media(id: 1399, mediaType: .tv, title: "Game of Thrones", posterPath: "/got.jpg", releaseDate: "2011-04-17")
    let game = Media(id: 1942, mediaType: .game, title: "The Witcher 3", posterPath: "https://images.igdb.com/w3.jpg")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlaylistAndHistoryToggleLikeTheWebapp() {
        var library = SyncLibrary()
        library.togglePlaylist(show, now: t0)
        XCTAssertEqual(library.item(show.key)?.list, .playlist)
        XCTAssertEqual(library.dirty[show.key.recordName]?.fields, [.list])

        library.toggleHistory(show, now: t0)
        XCTAssertEqual(library.item(show.key)?.list, .history)
        library.toggleFavorite(show.key)
        XCTAssertEqual(library.item(show.key)?.isFavorite, true)

        // Played again: out of History, and nothing kept.
        library.toggleHistory(show, now: t0)
        XCTAssertEqual(library.item(show.key)?.list, ListState.none)
        XCTAssertEqual(library.item(show.key)?.isFavorite, false)
        XCTAssertEqual(library.dirty[show.key.recordName]?.fields, Set(FieldGroup.allCases))
    }

    func testFavoriteOnPlaylistCanOnlyBeCleared() {
        var library = SyncLibrary()
        library.togglePlaylist(show, now: t0)
        library.toggleFavorite(show.key)
        XCTAssertEqual(library.item(show.key)?.isFavorite, false)

        library.toggleHistory(show, now: t0)
        library.toggleFavorite(show.key)
        library.togglePlaylist(show, now: t0)
        XCTAssertEqual(library.item(show.key)?.isFavorite, true, "a favorite stays when it goes back to the Playlist")
        library.toggleFavorite(show.key)
        XCTAssertEqual(library.item(show.key)?.isFavorite, false)
    }

    func testPinBelongsToTheListItWasPinnedIn() {
        var library = SyncLibrary()
        library.togglePin(show.key, now: t0)
        XCTAssertNil(library.item(show.key), "nothing to pin outside the library")

        library.togglePlaylist(show, now: t0)
        library.togglePin(show.key, now: t0.addingTimeInterval(1))
        XCTAssertEqual(library.item(show.key)?.isPinned, true)
        XCTAssertEqual(library.dirty[show.key.recordName]?.fields, [.list, .pin])

        // Moving to History lapses the pin without writing it.
        library.toggleHistory(show, now: t0.addingTimeInterval(2))
        XCTAssertEqual(library.item(show.key)?.isPinned, false)
        XCTAssertNotNil(library.item(show.key)?.pinnedAt)

        // Pinning there pins it in History; unpinning clears it.
        library.togglePin(show.key, now: t0.addingTimeInterval(3))
        XCTAssertEqual(library.item(show.key)?.isPinned, true)
        library.togglePin(show.key, now: t0.addingTimeInterval(4))
        XCTAssertEqual(library.item(show.key)?.isPinned, false)
        XCTAssertNil(library.item(show.key)?.pinnedAt)

        // Removing clears it, and a removed item can't be pinned.
        library.togglePin(show.key, now: t0.addingTimeInterval(5))
        library.toggleHistory(show, now: t0.addingTimeInterval(6))
        XCTAssertNil(library.item(show.key)?.pinnedAt)
        library.togglePin(show.key, now: t0.addingTimeInterval(7))
        XCTAssertNil(library.item(show.key)?.pinnedAt)

        // A return to the Playlist lapses a History pin too.
        library.toggleHistory(show, now: t0.addingTimeInterval(8))
        library.togglePin(show.key, now: t0.addingTimeInterval(9))
        library.returnToPlaylist(show.key, airDate: "2027-01-01", now: t0.addingTimeInterval(10))
        XCTAssertEqual(library.item(show.key)?.isPinned, false)
    }

    func testPendingPinSurvivesANewerRemoteRevision() {
        var library = SyncLibrary()
        library.togglePlaylist(show, now: t0)
        library.pushSucceeded(recordName: show.key.recordName, rev: library.rev, systemFields: nil)
        library.togglePin(show.key, now: t0.addingTimeInterval(1))

        // Another device rated it meanwhile: the pin is kept and written again.
        var remote = library.item(show.key)!
        remote.pinnedAt = nil
        remote.rating = 4
        library.applyRemote(recordName: show.key.recordName, item: remote, systemFields: nil)
        XCTAssertEqual(library.item(show.key)?.isPinned, true)
        XCTAssertEqual(library.item(show.key)?.rating, 4)
        XCTAssertEqual(library.dirty[show.key.recordName]?.fields, [.pin])
    }

    func testLoadsPendingMarksFromBeforePurchasedWasRemoved() throws {
        // A library saved by an older build with a pending `purchased` intention.
        let json = #"{"entries":{},"dirty":{"item.igdb.game.1":{"rev":3,"mode":"set","fields":["list","purchased"]}},"rev":3,"systemFields":{},"zoneReady":true}"#
        let library = try JSONDecoder().decode(SyncLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.dirty["item.igdb.game.1"]?.fields, [.list])
    }

    func testPendingFieldsSurviveANewerRemoteRevision() {
        var library = SyncLibrary()
        library.toggleHistory(show, now: t0)
        library.toggleFavorite(show.key)
        library.pushSucceeded(recordName: show.key.recordName, rev: library.rev, systemFields: Data([1]))
        XCTAssertTrue(library.dirty.isEmpty)

        // Here: unfavorite. Elsewhere, meanwhile: back to the Playlist.
        library.toggleFavorite(show.key)
        var remote = library.item(show.key)!
        remote.isFavorite = true
        remote.list = .playlist
        remote.addedAt = SyncCodec.iso(t0.addingTimeInterval(60))
        library.applyRemote(recordName: show.key.recordName, item: remote, systemFields: Data([2]))

        let merged = library.item(show.key)!
        XCTAssertEqual(merged.list, .playlist, "the remote list change is taken")
        XCTAssertEqual(merged.isFavorite, false, "the pending favorite change is kept")
        XCTAssertEqual(library.dirty[show.key.recordName]?.fields, [.favorite])
        XCTAssertEqual(library.systemFields[show.key.recordName], Data([2]))
    }

    func testPushClearsOnlyTheRevisionItSent() {
        var library = SyncLibrary()
        library.togglePlaylist(show, now: t0)
        let sent = library.rev
        library.toggleHistory(show, now: t0)
        library.pushSucceeded(recordName: show.key.recordName, rev: sent, systemFields: nil)
        XCTAssertNotNil(library.dirty[show.key.recordName])
        library.pushSucceeded(recordName: show.key.recordName, rev: library.rev, systemFields: nil)
        XCTAssertNil(library.dirty[show.key.recordName])
    }

    func testImportNeverOverwritesRemote() {
        var library = SyncLibrary()
        var remote = SyncedItem(media: show, list: .none, addedAt: SyncCodec.iso(t0))
        library.applyRemote(recordName: show.key.recordName, item: remote, systemFields: nil)
        XCTAssertEqual(library.importItems([SyncedItem(media: show, list: .history, addedAt: SyncCodec.iso(t0))]), 0)

        library = SyncLibrary()
        XCTAssertEqual(library.importItems([SyncedItem(media: show, list: .history, addedAt: SyncCodec.iso(t0))]), 1)
        remote.list = .playlist
        library.applyRemote(recordName: show.key.recordName, item: remote, systemFields: nil)
        XCTAssertEqual(library.item(show.key)?.list, .playlist)
        XCTAssertTrue(library.dirty.isEmpty)

        library = SyncLibrary()
        library.importItems([SyncedItem(media: show, list: .history, addedAt: SyncCodec.iso(t0))])
        library.pushConflicted(recordName: show.key.recordName)
        XCTAssertTrue(library.dirty.isEmpty)
    }

    func testReturnHappensOncePerEpisode() {
        var library = SyncLibrary()
        library.toggleHistory(show, now: t0)
        XCTAssertTrue(library.returnToPlaylist(show.key, airDate: "2027-01-20", now: t0))
        XCTAssertEqual(library.item(show.key)?.returnedFor, "2027-01-20")
        library.toggleHistory(show, now: t0)
        XCTAssertEqual(library.item(show.key)?.list, .history)
        XCTAssertFalse(library.returnToPlaylist(show.key, airDate: "2027-01-20", now: t0))
        XCTAssertTrue(library.returnToPlaylist(show.key, airDate: "2027-01-27", now: t0))
    }

    func testPendingReturnYieldsToAnotherDevice() {
        // Another device returned it and the person marked it played again; this
        // device's stale return for the same episode must not bring it back.
        var library = SyncLibrary()
        library.toggleHistory(show, now: t0)
        library.pushSucceeded(recordName: show.key.recordName, rev: library.rev, systemFields: nil)
        library.returnToPlaylist(show.key, airDate: "2027-01-20", now: t0)
        var remote = SyncedItem(media: show, list: .history, addedAt: SyncCodec.iso(t0.addingTimeInterval(120)))
        remote.returnedFor = "2027-01-20"
        library.applyRemote(recordName: show.key.recordName, item: remote, systemFields: nil)
        XCTAssertEqual(library.item(show.key)?.list, .history)
        XCTAssertTrue(library.dirty.isEmpty)

        // Still in History and never returned for it: the return stands.
        library.returnToPlaylist(show.key, airDate: "2027-01-27", now: t0)
        remote.returnedFor = "2027-01-20"
        library.applyRemote(recordName: show.key.recordName, item: remote, systemFields: nil)
        XCTAssertEqual(library.item(show.key)?.list, .playlist)
        XCTAssertEqual(library.item(show.key)?.returnedFor, "2027-01-27")
    }

    func testUserListChangeCancelsAPendingReturn() {
        var library = SyncLibrary()
        library.toggleHistory(show, now: t0)
        library.returnToPlaylist(show.key, airDate: "2027-01-20", now: t0)
        library.toggleHistory(show, now: t0)
        XCTAssertNil(library.dirty[show.key.recordName]?.returnFor)
    }

    func testDeletionAndZoneLoss() {
        var library = SyncLibrary()
        library.applyRemote(recordName: show.key.recordName, item: SyncedItem(media: show, list: .playlist, addedAt: SyncCodec.iso(t0)), systemFields: Data([1]))
        library.applyRemoteDeletion(recordName: show.key.recordName)
        XCTAssertNil(library.item(show.key))

        library.togglePlaylist(game, now: t0)
        library.systemFields[game.key.recordName] = Data([3])
        library.zoneReady = true
        library.zoneLost()
        XCTAssertTrue(library.systemFields.isEmpty)
        XCTAssertFalse(library.zoneReady)
        XCTAssertEqual(library.pending.map(\.recordName), [game.key.recordName])
    }

    func testCodable() throws {
        var library = SyncLibrary()
        library.togglePlaylist(show, now: t0)
        let data = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(SyncLibrary.self, from: data), library)
    }
}
