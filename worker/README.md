# [void] API Worker

Cloudflare Worker proxy for TMDB (movies and shows, `/api/tmdb/...`), IGDB game search/details, HowLongToBeat completion data, and GG.deals prices for Steam games (by Steam App ID). It serves the iOS app, [void] on the web, and the old [void] webapp, so no client ships an API key.

Moved here from the old `tinykings/void` repository. It deploys under the same name (`void-game-api`), so the old webapp keeps working. **This is the only copy: deploy it from here.** An older copy in `tinykings/void` blocks requests without an `Origin` header and has no TMDB proxy, so deploying that one breaks the iOS app with 403s.

## TMDB proxy

`GET /api/tmdb/<path>` forwards to `https://api.themoviedb.org/3/<path>` with the Worker's `TMDB_READ_ACCESS_TOKEN`. Only the endpoints the clients use are allowed (`tmdbProxyPath` in `src/index.ts`), each with its own query parameters; anything else is a 400. Responses are cached for an hour.

## Security controls

- **Origin allowlist:** Browser requests are accepted only from `ALLOWED_ORIGINS`. Originless requests are allowed (`ALLOW_ORIGINLESS_REQUESTS="true"`) because the iOS app sends no `Origin` header; the per-client rate limit is what bounds direct clients.
- **Rate limiting:** Cloudflare's native rate-limit binding allows 100 requests per minute. Search/details use per-client route keys; prices share a key within each Cloudflare location because GG.deals quota belongs to one API key. This counts requests, not records; see Prices below. Adjust the `[[ratelimits]]` block in `wrangler.toml` if production traffic requires a different limit.
- **Input limits:** URLs are limited to 2,048 characters, search text to 100 characters, and unsupported query parameters are rejected.
- **Monitoring:** Blocked origins, rate-limit events, and upstream failures emit structured JSON logs containing the event, route, origin, and Cloudflare Ray ID. Queries and credentials are never logged.

CORS is not authentication. A shared API secret was deliberately not embedded in the static web client because any browser-delivered secret can be extracted. The origin check reduces browser abuse and native rate limiting limits direct clients. If stronger caller identity becomes necessary, use a server-issued short-lived signed token, Cloudflare Access, or Turnstile rather than a permanent `NEXT_PUBLIC_*` secret.

## Configuration

Set Worker secrets:

```sh
npx wrangler secret put IGDB_CLIENT_ID --config wrangler.toml
npx wrangler secret put IGDB_CLIENT_SECRET --config wrangler.toml
npx wrangler secret put GG_DEALS_API_KEY --config wrangler.toml
npx wrangler secret put TMDB_READ_ACCESS_TOKEN --config wrangler.toml
```

Configure allowed origins in `worker/wrangler.toml` or the Cloudflare dashboard:

```toml
[vars]
ALLOWED_ORIGINS = "https://tinykings.github.io,https://void.tinyk.ing,http://localhost:3000"
ALLOW_ORIGINLESS_REQUESTS = "true"
```

For Capacitor or another client with a different origin, add its exact runtime origin to `ALLOWED_ORIGINS`; do not use `*` in production.

## Verification

Run a deployment dry run:

```sh
npx wrangler deploy --dry-run --config wrangler.toml
```

Local requests must include an allowed `Origin` header unless originless requests are explicitly enabled:

```sh
curl -H 'Origin: http://localhost:3000' 'http://localhost:8787/api/games/search?q=halo'
curl -H 'Origin: http://localhost:3000' 'http://localhost:8787/api/prices/steam/620?region=us'
curl -H 'Origin: http://localhost:3000' 'http://localhost:8787/api/prices/steam?ids=620,1245620&region=us'
```

## Prices

| Route | Identity | No match |
| --- | --- | --- |
| `GET /api/prices/steam/<appId>?region=` | `steamAppId` | `null` |
| `GET /api/prices/steam?ids=1,2&region=` | `steamAppId` | omitted |

Both return the same GG.deals aggregate quote (title, GG.deals URL, currency, current/historical retail and keyshop prices, and `lowestCurrent`) with its `steamAppId`. It's an aggregate across shops: it has no shop, platform, DRM or edition, and a Steam App ID lookup doesn't mean the price is a Steam store offer. Prices are for Steam games only: GG.deals' API has no platform data, so console games can't be priced (see `docs/multiplatform-deals.md`). Batches accept up to 50 unique IDs, returned in the order asked. `region` defaults to `us` and must be a GG.deals region.

**Caching.** Each game is cached on its own, keyed by region and Steam App ID (never the API key or caller), so single and batch requests share records and a batch fetches only its misses. Matches are cached for an hour; confirmed no-matches (GG.deals returned `null`) for 10 minutes. Upstream failures, 429s, and entries GG.deals omitted or returned malformed are never cached. Responses carry `max-age=600` when any requested game has no price, `3600` otherwise. Concurrent misses for the same game share one upstream request within an isolate only.

**Quota.** GG.deals allows 100 records per minute and 1,000 per hour per API key; every ID counts, even invalid ones, and a batch larger than what's left fails whole with a 429. The Worker passes a GG.deals 429 through with `Retry-After` (from `x-ratelimit-reset` when present) and never retries. The native rate limiter counts HTTP requests per Cloudflare location, not records, and caches are per location too, so **neither enforces the GG.deals quota**; upstream 429 is the real limit. Enforcing it in the Worker would need a globally coordinated record budget (for example a Durable Object with minute and hour windows); that's deliberately deferred.

The GG.deals key remains Worker-only; never expose it through a `NEXT_PUBLIC_*` variable.
