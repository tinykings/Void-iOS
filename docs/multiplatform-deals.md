# Multi-platform deals investigation

Status: research / proposed design, not implemented.

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

## Next concrete step

Get the GG.deals API documentation visible in a browser (or supplied by their
team) and resolve the provider gate above. Implementation can then start with
one verified additional platform/provider without speculative endpoint work.
