import XCTest
@testable import VoidCore

final class LibraryExportTests: XCTestCase {
    func testExportsAllListsWithFavoritesFirstAndExcludesRemovedItems() {
        var library = SyncLibrary()
        let movie = Media(id: 1, mediaType: .movie, title: "Amélie", releaseDate: "2001-04-25")
        let game = Media(id: 2, mediaType: .game, title: "Portal")
        let removed = Media(id: 3, mediaType: .tv, title: "Removed")
        library.toggleHistory(movie)
        library.toggleFavorite(movie.key)
        library.togglePlaylist(game)
        library.togglePlaylist(removed)
        library.togglePlaylist(removed)
        let text = library.exportText
        XCTAssertTrue(text.hasPrefix("[void] Library\n\nFavorites (1)\n- Amélie"))
        XCTAssertTrue(text.contains("Playlist (1)\n- Portal — Game"))
        XCTAssertTrue(text.contains("History (1)\n- Amélie — Movie (2001)"))
        XCTAssertFalse(text.contains("Removed"))
    }

    func testEmptyLibraryStillHasAllSections() {
        XCTAssertEqual(SyncLibrary().exportText,
                       "[void] Library\n\nFavorites (0)\nNone\n\nPlaylist (0)\nNone\n\nHistory (0)\nNone\n")
    }
}
