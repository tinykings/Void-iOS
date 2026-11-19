import Foundation

// The library as synced through the VoidSync zone (docs/sync-schema.md): one entry
// per movie, show or game, tombstones included, plus the pending local intentions.
// Plain values only; CloudSync does the CloudKit requests. Ported from Royal's
// SavedSyncLibrary, with intentions kept per field group.
//
// Local intentions are dirty marks, stored with the library so they survive being
// offline and relaunches, and coalesce per item. Each mark records the library's
// `rev` when it was made; a push clears it only if nothing changed the item again
// while the push was in flight.
//
// - The last accepted intention wins, per field group: a pending change is written
//   again over a newer remote revision, keeping the remote's other fields.
// - Removals are tombstones (list `none`), never deletions.
// - An import (items from before sync was on) never overwrites a remote record or
//   tombstone.
// - A pending return (a show back from History for a new episode) yields when the
//   remote record left History or was already returned for that episode.

enum ListState: String, Codable, Sendable {
    case playlist, history, none
}

enum FieldGroup: String, Codable, CaseIterable, Sendable {
    case list, favorite, rating
}

struct SyncedItem: Codable, Equatable, Sendable {
    var key: MediaKey
    var title: String
    var image: String?
    var releaseDate: String?
    var list: ListState
    // ISO 8601 UTC with milliseconds: when it entered its current list.
    var addedAt: String
    var isFavorite = false
    var rating = 0
    // The air date of the episode that last brought this show back to the Playlist.
    var returnedFor: String?

    init(key: MediaKey, title: String, image: String? = nil, releaseDate: String? = nil,
         list: ListState, addedAt: String, isFavorite: Bool = false,
         rating: Int = 0, returnedFor: String? = nil) {
        self.key = key
        self.title = title
        self.image = image
        self.releaseDate = releaseDate
        self.list = list
        self.addedAt = addedAt
        self.isFavorite = isFavorite
        self.rating = rating
        self.returnedFor = returnedFor
    }

    init(media: Media, list: ListState, addedAt: String) {
        self.init(key: media.key, title: media.title, image: media.posterPath ?? media.backdropPath,
                  releaseDate: media.releaseDate, list: list, addedAt: addedAt)
    }

    mutating func copy(_ group: FieldGroup, from other: SyncedItem) {
        switch group {
        case .list:
            list = other.list
            addedAt = other.addedAt
            returnedFor = other.returnedFor
        case .favorite: isFavorite = other.isFavorite
        case .rating: rating = other.rating
        }
    }
}

struct SyncLibrary: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case set, `import` }
    struct Mark: Codable, Equatable, Sendable {
        var rev: Int
        var mode: Mode
        var fields: Set<FieldGroup>
        // Set while the pending list change is a return for this air date.
        var returnFor: String?

        init(rev: Int, mode: Mode, fields: Set<FieldGroup>, returnFor: String? = nil) {
            self.rev = rev
            self.mode = mode
            self.fields = fields
            self.returnFor = returnFor
        }

        // Field groups saved by an older version that no longer exist (`purchased`)
        // are dropped rather than failing to load the library.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rev = try c.decode(Int.self, forKey: .rev)
            mode = try c.decode(Mode.self, forKey: .mode)
            fields = Set(try c.decode([String].self, forKey: .fields).compactMap(FieldGroup.init(rawValue:)))
            returnFor = try c.decodeIfPresent(String.self, forKey: .returnFor)
        }
    }

    // recordName -> its latest state, tombstones included.
    var entries: [String: SyncedItem] = [:]
    var dirty: [String: Mark] = [:]
    var rev = 0
    // An archived CKServerChangeToken (iOS) for the VoidSync zone.
    var changeToken: Data?
    var zoneReady = false
    // recordName -> the record's archived CloudKit system fields (its change tag).
    var systemFields: [String: Data] = [:]
    var lastSync: Date?

    init() {}

    var pendingCount: Int { dirty.count }

    func item(_ key: MediaKey) -> SyncedItem? { entries[key.recordName] }

    func list(_ list: ListState) -> [SyncedItem] {
        entries.values.filter { $0.list == list }
    }

    // The items with pending intentions, for a push.
    var pending: [(recordName: String, rev: Int)] {
        dirty.compactMap { name, mark in entries[name] == nil ? nil : (name, mark.rev) }
            .sorted { $0.recordName < $1.recordName }
    }

    // MARK: Local changes (the webapp's rules, src/lib/library.ts)

    private mutating func write(_ item: SyncedItem, _ fields: Set<FieldGroup>, returnFor: String? = nil) {
        rev += 1
        let name = item.key.recordName
        entries[name] = item
        var mark = dirty[name].flatMap { $0.mode == .set ? $0 : nil } ?? Mark(rev: rev, mode: .set, fields: [])
        mark.rev = rev
        mark.fields.formUnion(fields)
        if fields.contains(.list) { mark.returnFor = returnFor }
        dirty[name] = mark
    }

    // Removed from both lists: what's left is a tombstone with nothing set.
    private mutating func remove(_ item: SyncedItem, now: Date) {
        var gone = item
        gone.list = .none
        gone.addedAt = SyncCodec.iso(now)
        gone.isFavorite = false
        gone.rating = 0
        write(gone, Set(FieldGroup.allCases))
    }

    // Playlist button: adds to the Playlist (out of History), or removes from it.
    mutating func togglePlaylist(_ media: Media, now: Date = Date()) {
        let existing = item(media.key)
        if let existing, existing.list == .playlist {
            remove(existing, now: now)
            return
        }
        var next = existing ?? SyncedItem(media: media, list: .playlist, addedAt: SyncCodec.iso(now))
        next.refreshMetadata(from: media)
        next.list = .playlist
        next.addedAt = SyncCodec.iso(now)
        write(next, [.list])
    }

    // Played button: moves to History, or out of History when it's already there.
    mutating func toggleHistory(_ media: Media, now: Date = Date()) {
        let existing = item(media.key)
        if let existing, existing.list == .history {
            remove(existing, now: now)
            return
        }
        var next = existing ?? SyncedItem(media: media, list: .history, addedAt: SyncCodec.iso(now))
        next.refreshMetadata(from: media)
        next.list = .history
        next.addedAt = SyncCodec.iso(now)
        write(next, [.list])
    }

    // Favorites belong to History; on the Playlist a favorite can only be cleared.
    mutating func toggleFavorite(_ key: MediaKey) {
        guard var entry = item(key) else { return }
        switch entry.list {
        case .history: entry.isFavorite.toggle()
        case .playlist where entry.isFavorite: entry.isFavorite = false
        default: return
        }
        write(entry, [.favorite])
    }

    // A History show with an episode airing soon goes back to the Playlist, once per
    // episode. Returns whether it moved.
    @discardableResult
    mutating func returnToPlaylist(_ key: MediaKey, airDate: String, now: Date = Date()) -> Bool {
        guard var entry = item(key), key.type == .tv, entry.list == .history,
              entry.returnedFor != airDate else { return false }
        entry.list = .playlist
        entry.addedAt = SyncCodec.iso(now)
        entry.returnedFor = airDate
        write(entry, [.list], returnFor: airDate)
        return true
    }

    // Offers items from outside sync (this device before sync was on, or the old
    // webapp's library). Only items the library has no record of at all are added,
    // and a remote copy found later wins. Returns how many were added.
    @discardableResult
    mutating func importItems(_ items: [SyncedItem]) -> Int {
        var added = 0
        for item in items where entries[item.key.recordName] == nil && item.list != .none {
            if added == 0 { rev += 1 }
            added += 1
            entries[item.key.recordName] = item
            dirty[item.key.recordName] = Mark(rev: rev, mode: .import, fields: Set(FieldGroup.allCases))
        }
        return added
    }

    // MARK: Remote changes

    // A remote record. `item` is nil when it couldn't be read (or is a newer schema);
    // its revision is still kept so a pending write can succeed.
    mutating func applyRemote(recordName: String, item remote: SyncedItem?, systemFields fields: Data?) {
        if let fields { systemFields[recordName] = fields }
        guard let remote else { return }
        guard var mark = dirty[recordName] else {
            entries[recordName] = remote
            return
        }
        if mark.mode == .import {
            dirty[recordName] = nil
            entries[recordName] = remote
            return
        }
        if let airDate = mark.returnFor, remote.list != .history || remote.returnedFor == airDate {
            mark.fields.remove(.list)
            mark.returnFor = nil
        }
        var merged = remote
        if let local = entries[recordName] {
            for group in mark.fields { merged.copy(group, from: local) }
        }
        entries[recordName] = merged
        dirty[recordName] = mark.fields.isEmpty ? nil : mark
    }

    // [void] never deletes records; another client did. Forget the revision, and drop
    // a copy with no pending intention.
    mutating func applyRemoteDeletion(recordName: String) {
        systemFields[recordName] = nil
        if dirty[recordName] == nil { entries[recordName] = nil }
    }

    mutating func pushSucceeded(recordName: String, rev pushedRev: Int, systemFields fields: Data?) {
        if let fields { systemFields[recordName] = fields }
        if dirty[recordName]?.rev == pushedRev { dirty[recordName] = nil }
    }

    // Another client wrote first. An import yields to it; anything else is written
    // again once the newer revision has been applied.
    mutating func pushConflicted(recordName: String) {
        if dirty[recordName]?.mode == .import { dirty[recordName] = nil }
    }

    // The zone was deleted: every record is created anew, keeping pending intentions.
    mutating func zoneLost() {
        zoneReady = false
        changeToken = nil
        systemFields = [:]
    }
}

extension SyncedItem {
    // Title, poster and release date follow the latest details.
    mutating func refreshMetadata(from media: Media) {
        title = media.title
        if let poster = media.posterPath ?? media.backdropPath { image = poster }
        if let date = media.releaseDate { releaseDate = date }
    }
}
