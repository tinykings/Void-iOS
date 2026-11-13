import CloudKit
import Foundation

// Syncs the library between devices, and with the [void] website, through the VoidSync
// zone of the private CloudKit database (docs/sync-schema.md). Ported from Royal's
// SavedSync.
//
// Always on: it turns itself on for the Apple Account signed in to iCloud, and once it
// has, the synced library is the one shown. Until then (no account, or iCloud not
// ready) changes go to a local library on this device, which is imported when sync
// turns on.
//
// It syncs when the app opens or returns to the foreground, about 1.5 s after each
// change, and from pull to refresh. There's no background timer.
@MainActor
final class CloudSync: ObservableObject {
    struct Settings: Codable, Equatable {
        let container: String
        let environment: String
        // The Apple Account's userRecordName.
        let account: String
    }

    @Published private(set) var settings: Settings?
    @Published private(set) var accountLibrary = SyncLibrary()
    @Published private(set) var localLibrary = SyncLibrary()
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    // Sync hasn't turned on for an Apple Account yet: none is signed in, or iCloud
    // wasn't ready. [void] keeps trying.
    @Published private(set) var pendingEnable = true

    // Called after the library changes from a pull, an import, or an account switch.
    var onChange: (() -> Void)?

    private static let settingsKey = "cloudSyncSettings"
    private static let zoneID = CKRecordZone.ID(zoneName: SyncCodec.zoneName, ownerName: CKCurrentUserDefaultName)
    private var verifiedAccount = false
    private var again = false
    private var scheduled: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?
    // No request before this time: iCloud asked [void] to wait, or a retry is backing off.
    private var notBefore: Date?
    private var failures = 0

    static var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "VoidCloudKitContainer") as? String,
              value.hasPrefix("iCloud.") else { return nil }
        return value
    }

    static var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "VoidCloudKitEnvironment") as? String ?? "Unknown"
    }

    var isOn: Bool { settings != nil }

    // Whether the synced library is the one shown.
    var isActive: Bool { configurationMatches }

    // The library the app shows and changes.
    var library: SyncLibrary { isActive ? accountLibrary : localLibrary }

    private var configurationMatches: Bool {
        guard let settings else { return false }
        return settings.container == Self.containerIdentifier && settings.environment == Self.environment
    }

    init() {
        localLibrary = Self.load(Self.localURL) ?? SyncLibrary()
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = stored
            if configurationMatches {
                accountLibrary = Self.load(Self.libraryURL(stored)) ?? SyncLibrary()
                pendingEnable = false
            } else {
                // A build for another container or environment (Debug vs. TestFlight):
                // turn on afresh for this one. The other's library file stays.
                settings = nil
                UserDefaults.standard.removeObject(forKey: Self.settingsKey)
            }
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.verifiedAccount = false
                self.notBefore = nil
                self.failures = 0
                self.scheduleSync(after: 0)
            }
        }
    }

    // MARK: Turning sync on

    // Turns sync on for the signed-in Apple Account, importing this device's local
    // library. Earlier synced data for the same account on this device is picked up
    // again. If iCloud isn't ready, it's tried again later.
    private func attemptEnable() async {
        guard pendingEnable, !isOn, let identifier = Self.containerIdentifier, !busy else { return }
        busy = true
        status = "Turning on iCloud sync…"
        do {
            let container = CKContainer(identifier: identifier)
            try await Self.checkAccount(container)
            let account = try await container.userRecordID().recordName
            let new = Settings(container: identifier, environment: Self.environment, account: account)
            accountLibrary = Self.load(Self.libraryURL(new)) ?? SyncLibrary()
            accountLibrary.importItems(Array(localLibrary.entries.values))
            settings = new
            verifiedAccount = true
            if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
            pendingEnable = false
            persist()
            // They're this account's now, kept with its pending intentions; what stays
            // local is only what's changed while no account is syncing.
            localLibrary = SyncLibrary()
            Self.save(localLibrary, to: Self.localURL)
            onChange?()
        } catch {
            busy = false
            handle(error, enabling: true)
            return
        }
        busy = false
        await sync()
    }

    // Another Apple Account signed in to iCloud: hide this one's library, keeping its
    // file and pending intentions for when it signs in again, and turn on for the new one.
    private func switchAccount() {
        settings = nil
        verifiedAccount = false
        UserDefaults.standard.removeObject(forKey: Self.settingsKey)
        accountLibrary = SyncLibrary()
        pendingEnable = true
        onChange?()
    }

    // MARK: Local changes

    // Changes the shown library and schedules a sync.
    func change(_ body: (inout SyncLibrary) -> Void) {
        if isActive {
            body(&accountLibrary)
        } else {
            body(&localLibrary)
        }
        persist()
        scheduleSync()
    }

    // Also finishes turning sync on when that's still pending.
    func scheduleSync(after seconds: Double = 1.5) {
        guard configurationMatches || (pendingEnable && !isOn) else { return }
        let wait = max(seconds, notBefore?.timeIntervalSinceNow ?? 0)
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            // Run apart from this task, so a later schedule can't cancel a sync midway.
            Task { await self?.run() }
        }
    }

    private func run() async {
        if pendingEnable && !isOn { await attemptEnable() } else { await sync() }
    }

    // For pull to refresh: waits for the sync to finish.
    func syncNow() async {
        notBefore = nil
        await run()
    }

    // MARK: Syncing

    func sync() async {
        guard configurationMatches else { return }
        if busy {
            again = true
            return
        }
        busy = true
        repeat {
            again = false
            do {
                status = "Syncing…"
                status = try await runSync()
                failures = 0
                notBefore = nil
            } catch {
                handle(error, enabling: false)
            }
        } while again && configurationMatches && notBefore == nil
        busy = false
        // The Apple Account changed during the sync.
        if pendingEnable && !isOn { await attemptEnable() }
    }

    private struct Paused: Error {
        let message: String
        var retry: Retry = .later
    }

    // Pulls zone changes, then pushes pending intentions with conditional writes,
    // pulling again after conflicts. Mirrors web/shared/sync-runner.mjs.
    private func runSync() async throws -> String {
        guard let settings else { throw Paused(message: "Sync is off.") }
        let container = CKContainer(identifier: settings.container)
        try await Self.checkAccount(container)
        // userRecordID asks Apple's account service, which throttles repeated requests,
        // so it's checked once per launch and after the account changes.
        if !verifiedAccount {
            let current = try await container.userRecordID().recordName
            if current != settings.account {
                switchAccount()
                return "Switching to the Apple Account signed in to iCloud…"
            }
            verifiedAccount = true
        }
        let database = container.privateCloudDatabase
        if !accountLibrary.zoneReady { try await ensureZone(database) }

        var pulled = 0, pushed = 0, failed = 0
        for _ in 0..<4 {
            pulled += try await pull(database)
            let pending = accountLibrary.pending
            if pending.isEmpty { break }
            var retry = false
            for start in stride(from: 0, to: pending.count, by: 100) {
                let batch = Array(pending[start..<min(start + 100, pending.count)])
                let records = batch.compactMap { record(for: $0.recordName) }
                let result = try await database.modifyRecords(
                    saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                for item in batch {
                    let id = CKRecord.ID(recordName: item.recordName, zoneID: Self.zoneID)
                    switch result.saveResults[id] ?? .failure(CKError(.internalError)) {
                    case .success(let saved):
                        accountLibrary.pushSucceeded(recordName: item.recordName, rev: item.rev, systemFields: Self.archive(saved))
                        pushed += 1
                    case .failure(let error as CKError) where error.code == .serverRecordChanged:
                        accountLibrary.pushConflicted(recordName: item.recordName)
                        if let server = error.serverRecord { apply(server) }
                        retry = true
                    case .failure(let error as CKError) where Self.isZoneMissing(error):
                        accountLibrary.zoneLost()
                        retry = true
                    default:
                        failed += 1
                    }
                }
                persist()
            }
            if !retry { break }
            if !accountLibrary.zoneReady { try await ensureZone(database) }
        }
        accountLibrary.lastSync = Date()
        persist()
        if pulled > 0 { onChange?() }
        var summary = "Synced. Received \(pulled), sent \(pushed)."
        if failed > 0 { summary += " \(failed) couldn't be sent and will be tried again." }
        if accountLibrary.pendingCount > 0 { summary += " \(accountLibrary.pendingCount) pending." }
        return summary
    }

    // Every page of changes since the stored token.
    private func pull(_ database: CKDatabase) async throws -> Int {
        var pulled = 0
        for _ in 0..<50 {
            let token = accountLibrary.changeToken.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
                for result in changes.modificationResultsByID.values {
                    guard case .success(let modification) = result else { continue }
                    apply(modification.record)
                    pulled += 1
                }
                for deletion in changes.deletions where deletion.recordID.zoneID == Self.zoneID {
                    accountLibrary.applyRemoteDeletion(recordName: deletion.recordID.recordName)
                }
                accountLibrary.changeToken = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
                persist()
                if !changes.moreComing { break }
            } catch let error as CKError where Self.isZoneMissing(error) {
                // Deleted, for example from iCloud settings. Start over, keeping pending
                // intentions; every record is created anew.
                accountLibrary.zoneLost()
                try await ensureZone(database)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                accountLibrary.changeToken = nil
            }
        }
        return pulled
    }

    private func apply(_ record: CKRecord) {
        guard record.recordType == SyncCodec.recordType, record.recordID.zoneID == Self.zoneID,
              MediaKey(recordName: record.recordID.recordName) != nil else { return }
        var fields: [String: SyncCodec.Value] = [:]
        for key in record.allKeys() {
            if let string = record[key] as? String {
                fields[key] = .string(string)
            } else if let number = record[key] as? NSNumber {
                fields[key] = .int(number.int64Value)
            }
        }
        let item = SyncCodec.decode(recordName: record.recordID.recordName, fields: fields)
        accountLibrary.applyRemote(recordName: record.recordID.recordName, item: item, systemFields: Self.archive(record))
    }

    // The record to write: the last known revision when there is one, so the write is
    // conditional on it; otherwise a new record, which fails if another client created it.
    private func record(for recordName: String) -> CKRecord? {
        guard let entry = accountLibrary.entries[recordName] else { return nil }
        let id = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
        let record = accountLibrary.systemFields[recordName].flatMap(Self.unarchiveRecord)
            ?? CKRecord(recordType: SyncCodec.recordType, recordID: id)
        for (key, value) in SyncCodec.fields(entry) {
            switch value {
            case .string(let string): record[key] = string as NSString
            case .int(let int): record[key] = NSNumber(value: int)
            }
        }
        return record
    }

    private func ensureZone(_ database: CKDatabase) async throws {
        let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        if case .failure(let error)? = result.saveResults[Self.zoneID] { throw error }
        accountLibrary.zoneReady = true
        persist()
    }

    // MARK: Storage

    private func persist() {
        if isActive, let settings {
            Self.save(accountLibrary, to: Self.libraryURL(settings))
        } else {
            Self.save(localLibrary, to: Self.localURL)
        }
    }

    private static func save(_ library: SyncLibrary, to url: URL) {
        guard let data = try? JSONEncoder().encode(library) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func load(_ url: URL) -> SyncLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncLibrary.self, from: data)
    }

    private static let localURL = URL.applicationSupportDirectory.appending(path: "library-local.json")

    // One library per container, environment, and Apple Account, so another account's
    // data and pending intentions are kept apart.
    private static func libraryURL(_ settings: Settings) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let name = [settings.container, settings.environment, settings.account]
            .map { String($0.unicodeScalars.filter(allowed.contains)) }
            .joined(separator: "-")
        return URL.applicationSupportDirectory.appending(path: "library-\(name).json")
    }

    private static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func unarchiveRecord(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Errors

    private static func isZoneMissing(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    // When to try again after a failure.
    private enum Retry {
        // On a timer: after iCloud's suggested wait, or backing off when it gave none.
        case timer(Double?)
        // When the app returns to the foreground or the Apple Account changes.
        case later
        case never
    }

    // Checked on the device, before any request that has to authenticate.
    private static func checkAccount(_ container: CKContainer) async throws {
        switch try await container.accountStatus() {
        case .available:
            return
        case .noAccount:
            throw Paused(message: "No Apple Account is signed in to iCloud on this device. Your library is kept on this iPhone.")
        case .restricted:
            throw Paused(message: "iCloud is restricted on this device.")
        case .temporarilyUnavailable:
            throw Paused(message: "iCloud needs attention. Open Settings › Apple Account and confirm your sign-in.")
        case .couldNotDetermine:
            throw Paused(message: "iCloud account status could not be determined.", retry: .timer(nil))
        @unknown default:
            throw Paused(message: "iCloud is unavailable.")
        }
    }

    private func handle(_ error: Error, enabling: Bool) {
        let (message, retry) = Self.classify(error)
        switch retry {
        case .timer(let suggested):
            let backoff = min(30 * pow(2, Double(min(failures, 5))), 600)
            let delay = max(suggested ?? backoff, 5)
            failures += 1
            notBefore = Date().addingTimeInterval(delay)
            status = message + " [void] will try again in about \(Self.duration(delay))."
            scheduleSync(after: 0)
        case .later:
            status = message + " [void] will try again when you return to the app."
        case .never:
            status = enabling ? "Couldn't turn on iCloud sync. " + message : message
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded(.up))) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }

    private static func classify(_ error: Error) -> (String, Retry) {
        if let paused = error as? Paused { return (paused.message, paused.retry) }
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""
        let text = nsError.localizedDescription
        let combined = text + " " + underlying
        let ckError = error as? CKError
        switch ckError?.code {
        case .networkUnavailable?, .networkFailure?:
            return ("Offline. Changes are kept.", .timer(nil))
        case .requestRateLimited?, .serviceUnavailable?, .zoneBusy?:
            return ("iCloud asked [void] to wait. Changes are kept.", .timer(ckError?.retryAfterSeconds))
        case .notAuthenticated?, .accountTemporarilyUnavailable?:
            return ("iCloud needs your Apple Account password confirmed. Open Settings › Apple Account if it asks.", .later)
        case .unknownItem?, .invalidArguments?, .serverRejectedRequest?:
            return ("CloudKit rejected the request (\(text)). The VoidItem record type may not be deployed to \(environment) yet; see docs/sync-schema.md.", .never)
        default:
            break
        }
        // Apple's account service reports these without a CloudKit error code.
        if combined.localizedCaseInsensitiveContains("throttl") {
            return ("iCloud is rate-limiting sign-in requests from this device.", .timer(60))
        }
        if combined.localizedCaseInsensitiveContains("password") || combined.localizedCaseInsensitiveContains("rejected a prompt") {
            return ("iCloud needs your Apple Account password confirmed, and the prompt was dismissed.", .later)
        }
        if ckError != nil { return ("Sync failed: \(text)", .timer(nil)) }
        return ("Sync failed: \(text)", .never)
    }
}
