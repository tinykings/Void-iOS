# [void]

Track the movies, shows and games you want to watch or play, and the ones you have.
An iPhone app with a companion website, synced through your private iCloud.

- **Playlist and History.** Add anything to your Playlist; mark it played and it moves to
  History. Favorites live in History.
- **Returning shows.** A show in History whose next episode airs within a week moves back
  to the Playlist on its own, once per episode, and stays until you mark it played.
- **Stream.** Which US subscription services carry what's on your Playlist, the services
  covering the most first, to help pick what to subscribe to.
- **Deals.** Current prices for the Playlist games you haven't bought, cheapest first
  (Steam games only).
- **Search** movies and shows (TMDB) and games (IGDB) together; details with cast,
  seasons, trailers, streaming services, How Long to Beat and Steam game prices.
- **iCloud sync** between devices and with [void] on the web (`web/`), where you sign in
  with your Apple Account.

## Layout

| Path | What |
|---|---|
| `Void/Core/` | Plain Swift: models, the synced library and its conflict rules, the list rules, the API client. No UIKit/SwiftUI/CloudKit, so `swift test` runs it anywhere, including Linux. |
| `Void/App/` | CloudKit sync (`CloudSync`, ported from Royal) and the app's state (`LibraryStore`). |
| `Void/Views/` | SwiftUI screens. |
| `Tests/` | `swift test` for `Void/Core`, and a record fixture both clients decode. |
| `web/` | The info page and privacy policy (`index.html`), and [void] on the web (`app/`, with `shared/`): plain ES modules, no build step, CloudKit Web Services directly. |
| `worker/` | The Cloudflare Worker the app and site call: TMDB proxy, IGDB, HowLongToBeat, GG.deals. |
| `docs/sync-schema.md` | The CloudKit record format every client must follow. |

## Build

Open `Void.xcodeproj` in Xcode (iOS 17+). The target uses team `7F4K5N55BN`,
bundle ID `com.tinykings.void` and container `iCloud.com.tinykings.void`. Debug builds use
the CloudKit Development environment, Release builds Production (`VOID_CLOUDKIT_ENVIRONMENT`).
The Worker's address is `VOID_API_BASE_URL` in the target's build settings.

```
swift test                     # Void/Core, on any machine
npm test                       # web/
cd worker && npm install && npm test
```

## Setup (once)

1. **Apple Developer:** register the App ID `com.tinykings.void` with iCloud (CloudKit) and
   the container `iCloud.com.tinykings.void`. Xcode's automatic signing can do this.
2. **CloudKit schema:** run a Debug build on a device or simulator signed in to iCloud and
   add something; that creates the `VoidItem` record type in Development. In CloudKit
   Console, check its fields match `docs/sync-schema.md`, then **Deploy Schema Changes** to
   Production before TestFlight or the App Store.
3. **Worker:** `cd worker && npx wrangler secret put TMDB_READ_ACCESS_TOKEN`, then
   `npm run deploy`. It replaces the Worker the old webapp used, under the same name, and
   keeps serving it.
4. **Website:** in CloudKit Console (container `iCloud.com.tinykings.void`, Production)
   create a web API token with sign-in callback **URL Redirect** `https://void.tinyk.ing/app/`
   and allowed origin `void.tinyk.ing`, and put it in `web/site.mjs` (`SITE_CLOUDKIT.apiToken`).
   Point a DNS `CNAME` for `void` on `tinyk.ing` at `tinykings.github.io`, and in this
   repository's **Settings → Pages** choose *GitHub Actions* and the custom domain
   `void.tinyk.ing`. Pushing to `main` publishes `web/` through `.github/workflows/pages.yml`.

`https://void.tinyk.ing/` is the app's info page and privacy policy (`web/index.html`); [void] on
the web is at `/app/`. The App Store listing's privacy policy URL is
`https://void.tinyk.ing/privacy.html`, which forwards to it.

## Data

TMDB for movies and shows (this product uses the TMDB API but is not endorsed or certified
by TMDB), JustWatch streaming data through TMDB, IGDB and HowLongToBeat for games, GG.deals
for Steam game prices.
