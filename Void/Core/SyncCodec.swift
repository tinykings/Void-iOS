import Foundation

// The VoidItem record's fields (docs/sync-schema.md), without CloudKit: CloudSync
// copies these into a CKRecord, and web/shared/sync.mjs writes the same names.
enum SyncCodec {
    static let recordType = "VoidItem"
    static let zoneName = "VoidSync"
    static let schemaVersion = 1

    enum Value: Equatable, Sendable {
        case string(String)
        case int(Int64)

        var string: String? { if case .string(let value) = self { value } else { nil } }
        var int: Int64? { if case .int(let value) = self { value } else { nil } }
    }

    // MARK: Times

    private static let isoOut: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$"#

    // `2026-11-13T22:04:05.123Z`, as the web writes it.
    static func iso(_ date: Date) -> String { isoOut.string(from: date) }

    static func date(_ string: String) -> Date? {
        guard string.range(of: isoPattern, options: .regularExpression) != nil else { return nil }
        return isoOut.date(from: string) ?? isoPlain.date(from: string)
    }

    // `YYYY-MM-DD` that names a real day.
    static func isCalendarDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard value.count == 10, parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d
    }

    // MARK: Images

    // A TMDB path or an http(s) URL; anything else is dropped.
    static func cleanImage(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 1000 else { return nil }
        if value.range(of: #"^/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil { return value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return value
    }

    // MARK: Records

    static func fields(_ item: SyncedItem) -> [String: Value] {
        [
            "source": .string(item.key.source.rawValue),
            "mediaType": .string(item.key.type.rawValue),
            "mediaID": .int(Int64(item.key.id)),
            "title": .string(item.title),
            "image": .string(item.image ?? ""),
            "releaseDate": .string(item.releaseDate ?? ""),
            "list": .string(item.list.rawValue),
            "addedAt": .string(item.addedAt),
            "isFavorite": .int(item.isFavorite ? 1 : 0),
            "isPurchased": .int(item.isPurchased ? 1 : 0),
            "rating": .int(Int64(item.rating)),
            "returnedFor": .string(item.returnedFor ?? ""),
            "schemaVersion": .int(Int64(schemaVersion)),
        ]
    }

    // A VoidItem record's fields; nil when it's not one [void] understands, including a
    // newer schemaVersion, which is left alone rather than misread.
    static func decode(recordName: String, fields: [String: Value]) -> SyncedItem? {
        guard let version = fields["schemaVersion"]?.int, version <= schemaVersion,
              let key = MediaKey(recordName: recordName),
              fields["source"]?.string == key.source.rawValue,
              fields["mediaType"]?.string == key.type.rawValue,
              fields["mediaID"]?.int == Int64(key.id),
              let title = fields["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 500,
              let list = fields["list"]?.string.flatMap(ListState.init(rawValue:)),
              let addedAt = fields["addedAt"]?.string, let added = date(addedAt) else { return nil }
        let release = fields["releaseDate"]?.string.flatMap { isCalendarDate($0) ? $0 : nil }
        let returned = fields["returnedFor"]?.string.flatMap { isCalendarDate($0) ? $0 : nil }
        let rating = Int(clamping: fields["rating"]?.int ?? 0)
        return SyncedItem(
            key: key, title: title, image: cleanImage(fields["image"]?.string), releaseDate: release,
            list: list, addedAt: iso(added), isFavorite: fields["isFavorite"]?.int == 1,
            isPurchased: key.type == .game && fields["isPurchased"]?.int == 1,
            rating: (0...5).contains(rating) ? rating : 0, returnedFor: returned)
    }
}
