import SwiftUI

// DESIGN.md from the webapp: a dark ground, a cyan accent, compact and quiet.
extension Color {
    static let voidBackground = Color(red: 0x0F / 255, green: 0x11 / 255, blue: 0x15 / 255)
    static let voidSurface = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x23 / 255)
    static let voidCyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let voidSilver = Color(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255)
    static let voidBorder = Color.white.opacity(0.1)
}

extension Font {
    // Mono uppercase labels and readouts.
    static let voidLabel = Font.system(size: 11, weight: .bold, design: .monospaced)
    static let voidReadout = Font.system(size: 12, weight: .semibold, design: .monospaced)
}

// Screens pushed from any tab.
enum Route: Hashable {
    case media(Media)
    case person(id: Int, name: String)
    case season(showID: Int, showTitle: String, season: SeasonSummary)
}

extension View {
    func voidRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .media(let media): DetailsView(seed: media)
            case .person(let id, let name): PersonView(id: id, name: name)
            case .season(let showID, let showTitle, let season): SeasonView(showID: showID, showTitle: showTitle, season: season)
            }
        }
    }

    func voidScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.voidBackground.ignoresSafeArea())
            .toolbarBackground(Color.voidBackground, for: .navigationBar, .tabBar)
    }
}

struct PosterImage: View {
    var path: String?
    var size = "w342"

    var body: some View {
        AsyncImage(url: ImageURL.make(path, size: size), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                Rectangle().fill(Color.voidSurface)
                    .overlay(Image(systemName: "film").foregroundStyle(Color.voidSilver.opacity(0.4)))
            }
        }
    }
}

// Calendar dates shown as "Nov 20" or "Nov 20, 2027".
enum DateText {
    static func short(_ value: String?) -> String? {
        guard let value, let date = LibraryRules.localDay(String(value.prefix(10))) else { return nil }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    // Days from today to a calendar date; negative in the past.
    static func days(until value: String?) -> Int? {
        guard let value, let date = LibraryRules.localDay(String(value.prefix(10))) else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day
    }
}
