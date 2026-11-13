import Foundation

// Local notifications for what's coming on the Playlist: a show's next episode, or the
// day a movie or game comes out. Each fires at `hour` local time on that day. The app
// schedules them; this decides what they say and when.
enum ReleaseAlerts {
    struct Alert: Equatable, Sendable {
        var id: String
        var title: String
        var body: String
        var day: String      // YYYY-MM-DD
        var fireDate: Date
    }

    static let idPrefix = "release."
    // iOS keeps at most 64 pending notifications per app; leave some room.
    static let limit = 60
    static let hour = 9

    static func plan(_ entries: [(item: SyncedItem, media: Media)], now: Date,
                     calendar: Calendar = .current) -> [Alert] {
        var alerts: [Alert] = []
        for (item, media) in entries where item.list == .playlist {
            let alert: (day: String, body: String)?
            if item.key.type == .tv {
                alert = media.nextEpisodeToAir.flatMap { next in
                    next.airDate.map { ($0, episodeBody(next)) }
                }
            } else {
                alert = (media.releaseDate ?? item.releaseDate).map { ($0, item.key.type == .game ? "Out today. Time to play." : "Out today.") }
            }
            guard let alert, let start = LibraryRules.localDay(String(alert.day.prefix(10)), calendar: calendar),
                  let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start),
                  fire > now else { continue }
            let day = String(alert.day.prefix(10))
            alerts.append(Alert(id: "\(idPrefix)\(item.key.recordName).\(day)", title: media.title,
                                body: alert.body, day: day, fireDate: fire))
        }
        return Array(alerts.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(limit))
    }

    // "New episode today: S3E5 · The Last Stand", without a name TMDB fills in as
    // "Episode 5".
    static func episodeBody(_ next: EpisodeAir) -> String {
        let number = [next.seasonNumber.map { "S\($0)" }, next.episodeNumber.map { "E\($0)" }].compactMap { $0 }.joined()
        var name = next.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let episode = next.episodeNumber, name == "Episode \(episode)" { name = "" }
        let detail = [number, name].filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? "New episode today." : "New episode today: \(detail)"
    }
}
