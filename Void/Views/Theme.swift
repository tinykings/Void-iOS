import SwiftUI

// DESIGN.md from the webapp: a dark ground, a cyan accent, compact and quiet. Dark is
// the webapp's palette; light keeps the same feel with a deeper cyan that reads on white.
extension Color {
    static let voidBackground = adaptive(light: 0xF4F6F9, dark: 0x0F1115)
    static let voidSurface = adaptive(light: 0xFFFFFF, dark: 0x1A1D23)
    static let voidCyan = adaptive(light: 0x0891B2, dark: 0x22D3EE)
    static let voidSilver = adaptive(light: 0x64748B, dark: 0x94A3B8)
    static let voidBorder = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.1, darkAlpha: 0.1)
    // Text and icons on a cyan fill.
    static let voidOnAccent = adaptive(light: 0xFFFFFF, dark: 0x0F1115)
    // A recessed track, like the History/Playlist switch.
    static let voidWell = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.05, darkAlpha: 0.2)
    static let voidShadow = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.35)

    private static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func color(_ hex: UInt32, _ alpha: CGFloat) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark, darkAlpha) : color(light, lightAlpha) })
    }
}

extension Font {
    // Mono uppercase labels and readouts.
    static let voidLabel = Font.system(size: 11, weight: .bold, design: .monospaced)
    static let voidReadout = Font.system(size: 12, weight: .semibold, design: .monospaced)
}

// Preferences kept on this device only, not synced.
enum DisplaySettings {
    static let showTitlesKey = "showPosterTitles"
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

// Takes exactly the size it's offered and crops the image to it, so a cover that isn't
// 2:3 (many game covers) can't spill into its neighbors.
struct PosterImage: View {
    var path: String?
    var size = "w342"

    var body: some View {
        Color.voidSurface
            .overlay {
                AsyncImage(url: ImageURL.make(path, size: size), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Image(systemName: "film").foregroundStyle(Color.voidSilver.opacity(0.4))
                    }
                }
            }
            .clipped()
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
