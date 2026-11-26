import Foundation

extension SyncLibrary {
    /// All saved media, including types hidden by the display settings.
    var exportText: String {
        let items = entries.values.filter { $0.list != .none }.sorted {
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.key < $1.key
        }
        func section(_ title: String, _ items: [SyncedItem]) -> String {
            let lines = items.map { item in
                let name = item.title.components(separatedBy: .newlines).joined(separator: " ")
                let year = item.releaseDate.map { String($0.prefix(4)) } ?? ""
                var line = "- \(name) — \(item.key.type.singular)"
                if !year.isEmpty { line += " (\(year))" }
                if item.rating > 0 { line += " | Rating: \(item.rating)" }
                line += " | \(item.key.source.label): \(item.key.id)"
                return line
            }
            return "\(title) (\(items.count))\n" + (lines.isEmpty ? "None" : lines.joined(separator: "\n"))
        }
        return "[void] Library\n\n" + [
            section("Favorites", items.filter(\.isFavorite)),
            section("Playlist", items.filter { $0.list == .playlist }),
            section("History", items.filter { $0.list == .history })
        ].joined(separator: "\n\n") + "\n"
    }
}
