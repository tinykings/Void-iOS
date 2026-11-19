import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importResult: String?
    @AppStorage(DisplaySettings.showTitlesKey) private var showTitles = DisplaySettings.showTitlesDefault
    @AppStorage(ReleaseNotifier.enabledKey) private var notify = false
    @State private var notificationsDenied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(MediaType.allCases, id: \.self) { type in
                        Toggle(type.label, isOn: Binding(
                            get: { store.enabledTypes.contains(type) },
                            set: { on in
                                if on { store.enabledTypes.insert(type) }
                                else if store.enabledTypes.count > 1 { store.enabledTypes.remove(type) }
                            }))
                    }
                } header: {
                    Text("Track")
                } footer: {
                    Text("Turned-off types are hidden everywhere but stay in your library.")
                }

                Section {
                    Toggle("Show Titles", isOn: $showTitles)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Names under the posters on your Playlist and History. Search always shows them.")
                }

                Section {
                    Toggle("New Episodes and Releases", isOn: $notify)
                    if notificationsDenied {
                        Button("Allow Notifications in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notificationsDenied
                         ? "Notifications for [void] are turned off in the Settings app."
                         : "A reminder at 9 AM on the day a show on your Playlist has a new episode, or a movie or game on it comes out.")
                }
                .onChange(of: notify) { _, on in
                    Task {
                        if on, !(await ReleaseNotifier.requestPermission()) {
                            notify = false
                            notificationsDenied = await ReleaseNotifier.isDenied()
                        }
                        await ReleaseNotifier.reschedule(store)
                    }
                }
                // On but blocked in the Settings app since: say so, with the way back.
                .task { if notify { notificationsDenied = await ReleaseNotifier.isDenied() } }

                Section {
                    LabeledContent("Status", value: store.sync.isActive ? "On" : "Waiting for iCloud")
                    if let last = store.library.lastSync {
                        LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if store.sync.isActive && store.library.pendingCount > 0 {
                        LabeledContent("Changes waiting", value: "\(store.library.pendingCount)")
                    }
                    if !store.sync.status.isEmpty {
                        Text(store.sync.status).font(.footnote).foregroundStyle(Color.voidSilver)
                    }
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            if store.sync.busy || store.refreshing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(store.sync.busy || store.refreshing)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Your library syncs through your private iCloud database with your other devices and with [void] on the web at void.tinyk.ing/app (sign in with the same Apple Account).")
                }

                Section {
                    Button("Import from the old [void] webapp…") { importing = true }
                    if let importResult {
                        Text(importResult).font(.footnote).foregroundStyle(Color.voidSilver)
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text("Choose void-data.json from your [void] GitHub Gist (download it from the gist's Raw button). Items already in your library are left as they are.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Privacy Policy", destination: URL(string: "https://void.tinyk.ing/privacy.html")!)
                    Text("Movie and show data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming data from JustWatch. Game data from IGDB and HowLongToBeat; prices from GG.deals.")
                        .font(.footnote).foregroundStyle(Color.voidSilver)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
                importResult = importFile(result)
            }
            .voidScreen()
        }
    }

    private func importFile(_ result: Result<URL, Error>) -> String {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let added = try store.importLegacy(data)
            return added == 0 ? "Nothing new to import." : "Imported \(added) item\(added == 1 ? "" : "s")."
        } catch {
            return "Couldn't import: \(error.localizedDescription)"
        }
    }
}
