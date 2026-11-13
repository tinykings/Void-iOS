import SwiftUI

@main
struct VoidApp: App {
    @StateObject private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(.voidCyan)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
            // Leaving the app: match pending notifications to the Playlist as it is now.
            if phase == .background { Task { await ReleaseNotifier.reschedule(store) } }
        }
    }
}
