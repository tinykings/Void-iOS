# Multi-platform deals investigation

> **Decision (2026-11-19): abandoned. Prices are for Steam games only.**
> GG.deals' Prices API returns one aggregate PC quote with no platform, shop or
> DRM data, so it can't price console games, and matching non-Steam PC games to
> GG.deals slugs wasn't worth the risk of wrong matches. The `/api/prices/slug`
> Worker route was added and then removed. What stayed: per-game price caching
> in the Worker, and the optional personal GG.deals key on iOS (both Steam-only).
> The app, website and READMEs say "Steam games only". The rest of this document
> is the original research, kept for reference if a provider with platform-level
> console prices turns up.

Status: abandoned (see the decision above). Updated with official API
text supplied by the user and a concrete agent handoff below.

## Findings

- The Worker calls GG.deals `/v1/prices/by-steam-app-id/`. Both single and
  batch routes in `worker/src/index.ts` require Steam App IDs. This is an identity
  constraint, not proof that the quoted offer is sold by Steam or activates there.
- The response we consume has aggregate retail/keyshop current and historical
  prices. It does not identify the winning shop, activation platform, edition,
  console generation, or individual offer. We cannot derive these from a game's
  IGDB platform list.
- iOS `GamePrice` in `Void/Core/Models.swift` requires `steamAppId`;
  `Void/Views/DealsView.swift` indexes prices by it. Details also use the Steam
  route. Non-Steam games cannot enter this lookup.
- IGDB already supplies platform names and external-game IDs upstream, but the
  Worker currently exposes only platform names and a Steam ID. Preserve stable
  platform IDs and useful external identifiers when adding a real resolver.
- The current website (`web/shared/api.mjs`) has no price API methods and drops
  the Steam ID during game normalization. It does not yet have parity with iOS
  deals; this is additional work, not just renaming an existing web endpoint.
- Price data and provider mappings need not be stored in CloudKit. Its records
  identify games independently of Steam; see `docs/sync-schema.md`.

## External verification and limitations

Attempted the official GG.deals documentation at <https://gg.deals/api/>.
Cloudflare returned a browser challenge, so expanded API capabilities could not
be verified in this environment. The API root <https://api.gg.deals/> responds,
but `/openapi.json` returned a JSON 404. Neither result establishes whether
additional public or partner endpoints exist. No authenticated quota was used.

**Do not assume console website coverage implies console API access.** The
previous conversational suggestion of console support is not an API capability
confirmed by this investigation. Do not build guessed endpoints or scrape around
the browser challenge.

As a PC-only alternative, the accessible official IsThereAnyDeal documentation
(<https://docs.isthereanydeal.com/>) documents title search, title/shop-ID lookup,
`/games/prices/v3`, and offer-level shop, DRM, OS platforms, currency, URL and
expiry data. This is a credible candidate for non-Steam PC coverage, subject to
credentials, terms, coverage and matching validation. Its Windows/Mac/Linux
platform fields are not evidence of console support. It is not a drop-in source
for GG.deals' keyshop prices.

## Recommendation

Keep existing GG.deals Steam lookups working. First confirm a supported data
source, then add a platform-aware Worker interface alongside the old routes.
Do not refactor the entire client around an unverified GG.deals capability.

### 1. Resolve the provider gate

Ask GG.deals for current API documentation or partner access covering:

- Lookup by GG.deals ID, IGDB ID, storefront ID/URL, or title; batch support.
- Non-Steam PC games and PlayStation/Xbox/Nintendo coverage **through the API**.
- Individual offers with platform, activation DRM, edition, region, currency,
  physical/digital format and membership requirements.
- Rate limits, cache requirements, attribution, permitted links and licensing.

Obtain sample responses for a Steam game, a non-Steam PC exclusive, a console
exclusive and a multi-generation console game. If no suitable GG.deals API is
available, evaluate ITAD for broader PC support and a licensed console provider
separately. Do not promise console price support until a source is verified.

### 2. Worker-first, provider-independent identity

Proposed new batch request: IGDB game IDs plus country and optional platform
filters. Keep the existing `/api/prices/steam` routes for installed clients.
Resolve identifiers on the server, not by accepting arbitrary URLs from clients.
Cache provider mappings separately from volatile prices; country, platform,
provider and edition must participate in relevant cache keys.

Return per-game status (`ok`, `unsupported`, `no_match`, `no_offers`, or temporary
failure) and a list of offers, rather than collapsing everything to one price.
Each offer should carry provider, provider game ID, target platform, activation
DRM when known, edition, shop, retail/keyshop classification, amount as a decimal
string, currency, country, URL and observation time. Preserve relevant format and
membership restrictions. Missing fields must stay unknown, not be inferred.
A legacy aggregate GG.deals quote should be explicitly represented as an
aggregate with unknown offer details, not presented as a verified Steam offer.

Prefer exact storefront IDs or curated mappings. Title search should generate
candidates only: editions, remakes, DLC, similarly named games and regional
variants make first-result matching unsafe. Cache ambiguous/no-match results
briefly; never cache temporary upstream failures as permanent unsupported games.
Keep API keys Worker-only and enforce provider-specific shared quotas.

### 3. Client behavior

- Introduce a new offer model rather than making `GamePrice.steamAppId` a
  misleading universal identifier. Key new results by the game's source and ID.
- Show platform and shop/DRM when known; never call an aggregate PC quote a
  console price. Filter by platform before choosing the cheapest offer.
- Keep current USD behavior initially unless region selection is included in
  scope. Do not numerically rank prices in different currencies together.
- Distinguish unsupported coverage, no offer, no match, and retryable errors.
- Provide links only where a documented URL or verified mapping is available;
  a search link is not a live-price integration.
- Update both Deals and game Details. If website deals are in scope, implement
  API methods, normalization and UI there as a separate explicit deliverable.
- Start with per-device platform filters. Persisting a preferred purchase
  platform in CloudKit would require a separate schema design and simultaneous
  iOS/web codec and conflict-rule changes.

### 4. Validation before release

Fixture-test exact/ambiguous mappings, DLC versus base game, editions, console
generations, region restrictions, unknown DRM, free offers, missing prices,
keyshops, expired offers, mixed currencies, rate limits and partial batch
failures. Verify old Steam clients still decode unchanged responses.

Run Worker tests for provider/route changes, `swift test` for Core changes, root
`npm test` for web changes, and an app build when a simulator is booted.

## Updated findings: official documentation supplied by the user

The user supplied the Prices API documentation after the initial investigation.
It documents these endpoints:

- `/v1/prices/by-steam-app-id/` (`ids`)
- `/v1/prices/by-steam-sub-id/` (`ids`)
- `/v1/prices/by-steam-bundle-id/` (`ids`)
- **`/v1/prices/by-slug/` (`slugs`)**, added 2026-10-14

Each accepts a comma-separated list of up to 100 identifiers, the Worker-only
`key`, and an optional `region`. Slug results are keyed by slug. Missing matches
are `null`. All four return the same aggregate GamePrices shape already used by
the Worker (title, URL, current/historical retail/keyshop prices, currency).

The documented quota is **100 records per minute and 1,000 per hour**, shared by
the API key. Every ID/slug counts, including invalid requests. A batch larger
than the remaining allowance fails entirely with 429. Headers expose
`x-ratelimit-limit`, `x-ratelimit-remaining`, and `x-ratelimit-reset`.

This resolves the earlier documentation blocker for slug lookup. It does NOT
confirm console coverage or individual platform-specific offers. No title search
or IGDB-to-slug resolver appears in the supplied documentation. Steam Sub/Bundle
support concerns packages, not additional platforms, and is outside this task.

## Implementation handoff for the next agent

### Goal and boundaries

Add non-Steam game pricing using verified GG.deals slugs, retaining all existing
Steam behavior. Do not add another provider yet, promise console support, guess
slugs from titles or IGDB slugs, scrape GG.deals, or present aggregate prices as
verified platform-specific offers. The earlier provider-independent offer model
is a future direction, not a requirement to invent metadata this API lacks.

**First slice done (2026-11-19).** The Worker has `/api/prices/slug` and
per-game record caching shared by all price routes; see `worker/README.md`
(Prices). Global record-quota enforcement was deliberately deferred: the Worker
relies on upstream 429 + `Retry-After`, as documented there. iOS models and views
still require Steam IDs, and no verified non-Steam mapping has been collected,
so the second slice hasn't started.

### Optional personal GG.deals key (iOS, done 2026-11-19)

Settings → GG.deals lets a user add their own GG.deals API key (checked with one
lookup, stored in the iCloud Keychain, never in CloudKit). With a key, iOS calls
GG.deals directly (`Void/Core/GamePrices.swift`) and spends only that key's
allowance; without one, prices go through the Worker's shared key, and a shared
429 tells the user they can add their own. Both paths share a per-device cache
(1 hour; 10 minutes for no-price). Lookups are still by Steam App ID only; slug
lookups wait for verified mappings (second slice).

### First slice: Worker slug support and per-game caching

1. Add `GET /api/prices/slug?slugs=foo,bar&region=us`, returning an array of
   normalized aggregate quotes with `slug` instead of a required `steamAppId`.
   Reuse price validation, lowest-price selection and GG.deals URL allowlisting.
   Keep old Steam response shapes unchanged, including single-result `null` and
   omitted unmatched IDs in batches. Prefer a shared aggregate normalizer with
   separate Steam and slug identity wrappers.
2. Validate slugs conservatively (lowercase ASCII letters/digits separated by
   hyphens, bounded length), reject empty entries and unsupported query params,
   deduplicate before quota accounting, and cap batches. Retaining the existing
   Worker cap of 50 is fine; the upstream maximum of 100 is not a target.
   Reject overlong request URLs using the existing global guard. Use the same
   region allowlist as Steam and include the new route in price rate limiting.
3. Cache individual records by lookup kind, identifier and region, not only by
   the original request URL. Use internal cache keys without API keys or client
   identifiers and construct CORS on the outgoing response. Both Steam single
   and batch calls should share this cache. Fetch only misses in batches;
   reconstruct the caller's normalized result order afterward. Cache confirmed
   missing matches briefly; never turn failures into negative matches.
   Do not cache an omitted or malformed upstream entry as a confirmed miss.
4. Preserve upstream 429 handling and Retry-After. Existing native rate limiting
   counts HTTP requests per Cloudflare location, not records globally, so it
   **does not enforce the GG.deals quota**. Per-game caches are also local to a
   Cloudflare location. Do not claim they guarantee the shared quota. For hard
   enforcement, design a globally coordinated record-budget limiter (e.g. a
   Durable Object) with minute/hour windows, or explicitly defer this and rely
   on upstream 429 with clearly documented limitations. Do not make speculative
   retries that consume more quota. Consider concurrent identical cache misses
   and avoid claiming local in-flight deduplication works across locations.
5. Unit-test validation, identity wrappers, no match, free price, malformed data,
   ties and keyshops. Add mocked route/upstream/cache tests for overlapping
   batches, single/batch cache reuse, regions, partial cached results, and 429
   without successful-cache poisoning. No live API key is needed for tests.

Relevant code: `worker/src/index.ts` (`normalizeGgDealsGamePrice`,
`fetchSteamGamePrices`, `withCache`, price routes and rate-limit classification),
`worker/src/index.test.ts`, and `worker/README.md`.

### Second slice: verified identity mapping and iOS integration

1. Establish an explicit server-side mapping from IGDB ID to verified GG.deals
   slug. Each curated entry should retain the checked GG.deals URL and enough
   provenance to review edition/base-game identity. Do not seed it with assumed
   IDs or fabricated examples. A GG.deals URL actually supplied by metadata can
   be a candidate, but it still needs identity verification. Ask the user for
   initial non-Steam game URLs if necessary.
2. Prefer exposing a verified `gg_deals_slug` on normalized IGDB game details,
   or provide a server-resolved game-price endpoint. Pick and document one
   approach; do not put a growing curated table in the iOS app. Cached IGDB
   details may require a cache-version bump when mapping data changes.
3. Introduce an explicit quote identity (Steam ID or GG.deals slug), keeping
   legacy decoding intact. An aggregate quote has no verified platform/DRM
   metadata. Add helpers that prefer Steam where available and use the verified
   slug otherwise. Keep unsupported games distinguishable from network errors.
4. Update `Void/Views/DealsView.swift` to index quotes by media identity rather
   than assuming every priced game has a Steam ID. Update
   `Void/Views/DetailsView.swift` to use the same resolution policy. Rename
   “No Steam price” to an accurate unavailable-price label; retain retail/keyshop
   disclosure and GG.deals links. Keep USD initially.
5. Update `Void/Core/Models.swift`, `Void/Core/VoidAPI.swift` and
   `Void/Core/LibraryRules.swift` as necessary, with Foundation-only Core tests
   covering Steam compatibility and slug-backed games. Provider IDs and prices
   remain metadata/cache, not CloudKit fields; no sync migration is required.
6. Website deals do not currently exist. If web parity is requested, explicitly
   scope API normalization and new UI rather than claiming an existing feature
   was updated. If any CloudKit preference is added, follow the simultaneous
   iOS/web schema requirements in `docs/sync-schema.md` instead.

### Completion checks

- Run `npm test` in `worker/` for Worker changes and a Wrangler deployment dry
  run (`npx wrangler deploy --dry-run --config wrangler.toml`). Do not deploy.
- Run `swift test` after Core changes. If changing the app, check
  `xcrun simctl list devices booted` and rebuild for the booted simulator per
  `AGENTS.md`.
- Run root `npm test` if changing `web/`.
- Commit completed changes with a clear message; do not push.
- Leave the pre-existing untracked `Void.xcodeproj/xcshareddata/xcodecloud/`
  directory alone.

Suggested first implementation commit: Worker slug endpoint, shared per-game
price caching, regression tests and endpoint documentation. Then wire iOS only
once at least one real non-Steam mapping has been verified.
