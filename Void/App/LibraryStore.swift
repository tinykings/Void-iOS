import Combine
import Foundation
import SwiftUI

// The app's state: the synced library (CloudSync), a per-device cache of details from
// TMDB and the Worker, the returning-shows check, and which media types are on.
@MainActor
final class LibraryStore: ObservableObject {
    struct Cached: Codable {
        var media: Media
        var fetchedAt: Date
        // When this device last checked a History show for a new episode.
        var returnCheckedAt: Date?
    }

    let sync = CloudSync()
    let api: VoidAPI

    @Published private(set) var cache: [String: Cached] = [:]
    @Published private(set) var refreshing = false
    @Published var enabledTypes: Set<MediaType> {
        didSet { UserDefaults.standard.set(enabledTypes.map(\.rawValue), forKey: Self.enabledTypesKey) }
    }
    // Providers per item, for Stream, kept for this session.
    @Published private(set) var providers: [String: [WatchProvider]] = [:]

    private var forward: AnyCancellable?
    private static let enabledTypesKey = "enabledMediaTypes"
    private static let cacheURL = URL.cachesDirectory.appending(path: "metadata.json")

    init() {
        let base = (Bundle.main.object(forInfoDictionaryKey: "VoidAPIBaseURL") as? String)
            .flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
        api = VoidAPI(baseURL: base)
        let stored = UserDefaults.standard.stringArray(forKey: Self.enabledTypesKey)
        let types = Set((stored ?? MediaType.allCases.map(\.rawValue)).compactMap(MediaType.init(rawValue:)))
        enabledTypes = types.isEmpty ? Set(MediaType.allCases) : types
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: Cached].self, from: data) {
            cache = decoded
        }
        forward = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    var library: SyncLibrary { sync.library }

    func item(_ key: MediaKey) -> SyncedItem? { library.item(key) }

    // What's known about an item: cached details, or what the synced record says.
    func media(for item: SyncedItem) -> Media {
        if var cached = cache[item.key.recordName]?.media {
            if cached.posterPath == nil { cached.posterPath = item.image }
            return cached
        }
        return Media(id: item.key.id, mediaType: item.key.type, source: item.key.source, title: item.title,
                     posterPath: item.image, releaseDate: item.releaseDate)
    }

    func cachedMedia(_ key: MediaKey) -> Media? { cache[key.recordName]?.media }

    func entries(_ list: ListState, type: MediaType?) -> [SyncedItem] {
        let items = library.list(list).filter { enabledTypes.contains($0.key.type) && (type == nil || $0.key.type == type) }
        switch list {
        case .playlist:
            return LibraryRules.sortPlaylist(items) { item in
                let media = cache[item.key.recordName]?.media
                return .init(type: item.key.type, releaseDate: media?.releaseDate ?? item.releaseDate,
                             nextEpisodeAirDate: media?.nextEpisodeToAir?.airDate, addedAt: item.addedAt)
            }
        default:
            return items.sorted { $0.addedAt > $1.addedAt }
        }
    }

    // MARK: Changing

    func togglePlaylist(_ media: Media) {
        remember(media)
        sync.change { $0.togglePlaylist(media) }
    }

    func toggleHistory(_ media: Media) {
        remember(media)
        sync.change { $0.toggleHistory(media) }
    }

    func toggleFavorite(_ key: MediaKey) { sync.change { $0.toggleFavorite(key) } }

    // MARK: Details cache

    private func remember(_ media: Media, returnCheckedAt: Date? = nil) {
        let name = media.key.recordName
        // A search result knows less than details do; don't let it replace them.
        if let existing = cache[name], existing.media.status != nil, media.status == nil {
            var kept = existing
            kept.returnCheckedAt = returnCheckedAt ?? existing.returnCheckedAt
            cache[name] = kept
        } else {
            cache[name] = Cached(media: media, fetchedAt: Date(), returnCheckedAt: returnCheckedAt ?? cache[name]?.returnCheckedAt)
        }
        saveCache()
    }

    // Details screens report what they loaded, so lists and sorting stay current.
    func didLoadDetails(_ media: Media) { remember(media) }

    private var saveTask: Task<Void, Never>?
    private func saveCache() {
        saveTask?.cancel()
        saveTask = Task { [cache] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: Refreshing

    // On launch, on returning to the foreground, and from pull to refresh: sync, bring
    // History shows with a new episode back to the Playlist, then fill in missing details.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await sync.syncNow()
        await checkReturningShows()
        await fillDetails()
        await ReleaseNotifier.reschedule(self)
    }

    // docs/sync-schema.md, "Returning shows". Checked once a day per show on this device.
    func checkReturningShows(now: Date = Date()) async {
        guard enabledTypes.contains(.tv) else { return }
        let shows = library.list(.history).filter { $0.key.type == .tv }
        for show in shows {
            let cached = cache[show.key.recordName]
            guard LibraryRules.needsReturnCheck(status: cached?.media.status, lastChecked: cached?.returnCheckedAt, now: now) else { continue }
            do {
                let details = try await api.details(.tv, id: show.key.id)
                remember(details, returnCheckedAt: now)
                if let airDate = LibraryRules.returnAirDate(nextEpisodeAirDate: details.nextEpisodeToAir?.airDate, now: now) {
                    sync.change { $0.returnToPlaylist(show.key, airDate: airDate, now: now) }
                }
            } catch VoidAPI.Failure.rateLimited {
                return
            } catch {
                continue
            }
        }
    }

    // Details for library items that have none cached, or old ones, a few at a time.
    func fillDetails(limit: Int = 30) async {
        let now = Date()
        let missing = library.entries.values
            .filter { $0.list != .none && $0.key.source != .steam && $0.key.source != .rawg }
            .filter { item in
                guard let cached = cache[item.key.recordName], cached.media.status != nil || item.key.type == .game else { return true }
                let maxAge = LibraryRules.detailsMaxAge(type: item.key.type, list: item.list, status: cached.media.status)
                return now.timeIntervalSince(cached.fetchedAt) > maxAge
            }
            .sorted { $0.list == .playlist && $1.list != .playlist }
            .prefix(limit)
        for item in missing {
            do {
                remember(try await api.details(for: item.key))
            } catch VoidAPI.Failure.rateLimited {
                return
            } catch {
                continue
            }
        }
    }

    // Details for the given games that have none cached on this device, such as ones
    // imported or added on the website (iCloud doesn't carry their Steam app ID), a few
    // at a time. Stops if the Worker rate-limits.
    func fillMissingGameDetails(_ items: [SyncedItem], batchSize: Int = 4) async {
        let missing = items.filter {
            $0.key.type == .game && $0.key.source == .igdb && cache[$0.key.recordName] == nil
        }
        let api = api
        var start = 0
        while start < missing.count {
            let batch = missing[start..<min(start + batchSize, missing.count)].map(\.key)
            start += batchSize
            var limited = false
            await withTaskGroup(of: Result<Media, Error>.self) { group in
                for key in batch {
                    group.addTask {
                        do { return .success(try await api.details(for: key)) } catch { return .failure(error) }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let media): remember(media)
                    case .failure(VoidAPI.Failure.rateLimited): limited = true
                    case .failure: continue
                    }
                }
            }
            if limited { return }
        }
    }

    // MARK: Stream

    // Streaming services for Playlist movies and shows, fetched once per session.
    func loadProviders(for items: [SyncedItem]) async {
        for item in items where providers[item.key.recordName] == nil && item.key.type != .game {
            do {
                providers[item.key.recordName] = try await api.streamingProviders(item.key.type, id: item.key.id)
            } catch VoidAPI.Failure.rateLimited {
                return
            } catch {
                continue
            }
        }
    }
}
