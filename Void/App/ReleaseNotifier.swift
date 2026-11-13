import Foundation
import UserNotifications

// Schedules ReleaseAlerts as local notifications. Rescheduled after every refresh and
// when the app goes to the background, so what's pending matches the Playlist. Nothing
// leaves the device.
@MainActor
enum ReleaseNotifier {
    static let enabledKey = "notifyReleases"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // Asks once; afterwards iOS answers from the Settings app without prompting.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static func reschedule(_ store: LibraryStore, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ReleaseAlerts.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        let status = await center.notificationSettings().authorizationStatus
        guard isEnabled, status == .authorized || status == .provisional else { return }

        let entries = store.entries(.playlist, type: nil).map { (item: $0, media: store.media(for: $0)) }
        for alert in ReleaseAlerts.plan(entries, now: now) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alert.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
    }
}
