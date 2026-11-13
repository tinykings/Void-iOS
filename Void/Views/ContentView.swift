import SwiftUI

// One screen with a floating footer, like the webapp: a filter menu (type, Favorites,
// Stream, Deals, Settings), a History/Playlist switch and Search.
struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var list = ListState.playlist
    @State private var filter: MediaType?
    @State private var favoritesOnly = false
    @State private var special: Special?
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var details: Media?
    @Namespace private var segment

    enum Special { case stream, deals }

    var body: some View {
        NavigationStack {
            Group {
                switch special {
                case .stream: StreamView()
                case .deals: DealsView()
                case nil: LibraryView(list: favoritesOnly ? .history : list, filter: filter, favoritesOnly: favoritesOnly)
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            // The floating label over the footer names the view; the title only labels
            // the back button on pushed screens.
            .toolbar(.hidden, for: .navigationBar)
            .voidRoutes()
            .voidScreen()
            .environment(\.openDetails, OpenDetailsAction { details = $0 })
        }
        // Details come up as a card you drag down to dismiss; cast, seasons and other
        // titles push inside it.
        .sheet(item: $details) { media in
            NavigationStack {
                DetailsView(seed: media)
                    .toolbar(.hidden, for: .navigationBar)
                    .voidRoutes()
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: store.enabledTypes) { _, types in
            if special == .deals && !types.contains(.game) { special = nil }
            if special == .stream && !types.contains(.movie) && !types.contains(.tv) { special = nil }
            if let current = filter, !types.contains(current) { filter = nil }
        }
    }

    // MARK: - Footer

    private var types: [MediaType] { MediaType.allCases.filter(store.enabledTypes.contains) }
    private var showsStream: Bool { store.enabledTypes.contains(.movie) || store.enabledTypes.contains(.tv) }
    private var showsDeals: Bool { store.enabledTypes.contains(.game) }
    private var clearsOnTap: Bool { special != nil || favoritesOnly }

    private var status: String {
        switch special {
        case .stream: return "Stream · Playlist"
        case .deals: return "Deals · Playlist"
        case nil:
            let mode = favoritesOnly ? "Favorites" : list == .history ? "History" : "Playlist"
            return "\(mode) · \(filter?.label ?? "All")"
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text(status.uppercased())
                .font(.voidReadout)
                .foregroundStyle(Color.voidCyan)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.voidCyan.opacity(0.2)))
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                filterButton
                listSwitch
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(Color.voidSilver)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 28).fill(Color.voidBackground.opacity(0.6)))
            }
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.voidBorder))
            .shadow(color: .voidShadow, radius: 20, y: 8)
            .frame(maxWidth: 384)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var filterIcon: String {
        switch special {
        case .stream: return "antenna.radiowaves.left.and.right"
        case .deals: return "tag"
        case nil:
            if favoritesOnly { return "heart.fill" }
            switch filter {
            case .movie: return "film"
            case .tv: return "tv"
            case .game: return "gamecontroller"
            case nil: return "slider.horizontal.3"
            }
        }
    }

    private var filterLabel: some View {
        let active = clearsOnTap || filter != nil
        return Image(systemName: filterIcon)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 48, height: 48)
            .foregroundStyle(active ? Color.voidCyan : Color.voidSilver)
            .background(active ? Color.voidCyan.opacity(0.12) : .clear, in: Circle())
            .contentShape(Circle())
    }

    // While Stream, Deals or Favorites is showing, the button clears it; otherwise it
    // opens the menu.
    @ViewBuilder private var filterButton: some View {
        if clearsOnTap {
            Button { change { special = nil; favoritesOnly = false } } label: { filterLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(special == .stream ? "Clear Stream view" : special == .deals ? "Clear Deals view" : "Clear Favorites view")
        } else {
            Menu {
                if types.count > 1 {
                    Picker("Type", selection: Binding(get: { filter }, set: { value in change { filter = value } })) {
                        Label("All", systemImage: "square.grid.2x2").tag(MediaType?.none)
                        ForEach(types, id: \.self) { type in
                            Label(type.label, systemImage: icon(for: type)).tag(Optional(type))
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    Button { change { favoritesOnly = true } } label: { Label("Favorites", systemImage: "heart") }
                }
                if showsStream || showsDeals {
                    Section {
                        if showsStream {
                            Button { change { special = .stream } } label: { Label("Stream", systemImage: "antenna.radiowaves.left.and.right") }
                        }
                        if showsDeals {
                            Button { change { special = .deals } } label: { Label("Deals", systemImage: "tag") }
                        }
                    }
                }
                Section {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            } label: { filterLabel }
            .menuOrder(.fixed)
            .accessibilityLabel("Filter: \(filter?.label ?? "All")")
        }
    }

    private var listSwitch: some View {
        HStack(spacing: 0) {
            listButton(.history, systemImage: "clock.arrow.circlepath", label: "History")
            listButton(.playlist, systemImage: "bookmark", label: "Playlist")
        }
        .padding(4)
        .background(Color.voidWell, in: Capsule())
        .overlay(Capsule().stroke(Color.voidBorder))
    }

    private func listButton(_ target: ListState, systemImage: String, label: String) -> some View {
        let selected = special == nil && !favoritesOnly && list == target
        return Button {
            change { special = nil; favoritesOnly = false; list = target }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color.voidCyan : Color.voidSilver)
                .background {
                    if selected {
                        Capsule().fill(Color.voidCyan.opacity(0.15))
                            .matchedGeometryEffect(id: "selected", in: segment)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func icon(for type: MediaType) -> String {
        switch type {
        case .movie: "film"
        case .tv: "tv"
        case .game: "gamecontroller"
        }
    }

    private func change(_ update: () -> Void) {
        withAnimation(.easeOut(duration: 0.25)) { update() }
    }
}
