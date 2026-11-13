import Foundation

// Reads the old [void] webapp's library file (`void-data.json` in its GitHub Gist,
// versions 1–4) into items for SyncLibrary.importItems. Played-episode marks aren't
// carried over: the webapp never showed them.
enum LegacyImport {
    struct Failure: Error, Equatable, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private struct Payload: Decodable {
        var version: Int
        var watchlist: [Failable<Item>]
        var watched: [Failable<Item>]
        var favorites: [Failable<Item>]?
    }

    private struct Item: Decodable {
        var id: Int
        var title: String
        var media_type: MediaType
        var source: MediaSource?
        var date_added: String?
        var release_date: String?
        var image: String?
        var rating: Int?
        var isPurchased: Bool?

        var key: MediaKey? {
            let source = source ?? .default(for: media_type)
            guard id > 0, (media_type == .game) == (source != .tmdb) else { return nil }
            return MediaKey(source: source, type: media_type, id: id)
        }
    }

    static let maxBytes = 2 * 1024 * 1024

    static func items(from data: Data, now: Date = Date()) throws -> [SyncedItem] {
        guard data.count <= maxBytes else { throw Failure(message: "The file is larger than 2 MB.") }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw Failure(message: "This isn't a [void] library file (void-data.json).")
        }
        guard (1...4).contains(payload.version) else {
            throw Failure(message: "This library file's version (\(payload.version)) isn't supported.")
        }
        let favorites = Set((payload.favorites ?? []).compactMap { $0.value?.key })
        var seen = Set<MediaKey>()
        var result: [SyncedItem] = []
        func add(_ items: [Failable<Item>], to list: ListState) {
            for case let item? in items.map(\.value) {
                guard let key = item.key, seen.insert(key).inserted else { continue }
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let release = item.release_date.map { String($0.prefix(10)) }.flatMap { SyncCodec.isCalendarDate($0) ? $0 : nil }
                result.append(SyncedItem(
                    key: key, title: String(title.prefix(500)), image: SyncCodec.cleanImage(item.image),
                    releaseDate: release, list: list, addedAt: SyncCodec.iso(parseDate(item.date_added) ?? now),
                    isFavorite: favorites.contains(key), isPurchased: key.type == .game && item.isPurchased == true,
                    rating: (1...5).contains(item.rating ?? 0) ? item.rating! : 0))
            }
        }
        add(payload.watchlist, to: .playlist)
        add(payload.watched, to: .history)
        return result
    }

    // The webapp wrote `toISOString()` times, and older versions plain dates.
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = SyncCodec.date(value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withFullDate]
        return plain.date(from: String(value.prefix(10)))
    }
}
