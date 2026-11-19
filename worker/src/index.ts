type RateLimiter = {
  limit(options: { key: string }): Promise<{ success: boolean }>;
};

type Env = {
  IGDB_CLIENT_ID: string;
  IGDB_CLIENT_SECRET: string;
  GG_DEALS_API_KEY: string;
  TMDB_READ_ACCESS_TOKEN?: string;
  ALLOWED_ORIGINS?: string;
  ALLOW_ORIGINLESS_REQUESTS?: string;
  RATE_LIMITER: RateLimiter;
};

type ExecutionContextLike = {
  waitUntil(promise: Promise<unknown>): void;
};

type IgdbImage = {
  image_id?: string;
};

type IgdbNamedItem = {
  name?: string;
};

type IgdbWebsite = {
  url?: string;
};

type IgdbExternalGame = {
  category?: number;
  uid?: string;
};

type IgdbGame = {
  id: number;
  version_parent?: number;
  parent_game?: number;
  game_type?: number;
  hypes?: number;
  themes?: { id?: number }[];
  name?: string;
  slug?: string;
  summary?: string;
  first_release_date?: number;
  total_rating?: number;
  total_rating_count?: number;
  cover?: IgdbImage;
  screenshots?: IgdbImage[];
  platforms?: IgdbNamedItem[];
  genres?: IgdbNamedItem[];
  websites?: IgdbWebsite[];
  external_games?: IgdbExternalGame[];
  videos?: { name?: string; video_id?: string }[];
};

type HltbInitResponse = {
  token?: string;
  [key: string]: string | undefined;
};

type HltbSearchGame = {
  game_id?: number;
  game_name?: string;
  game_alias?: string;
  game_type?: string;
  release_world?: string | number;
  comp_main?: number;
  comp_plus?: number;
  comp_100?: number;
  comp_all?: number;
};

type HltbSearchResponse = {
  data?: HltbSearchGame[];
};

type HltbCompletion = {
  hltb_id: number;
  hltb_url: string;
  playtime: number;
  playtime_main?: number;
  playtime_extra?: number;
  playtime_completionist?: number;
  playtime_all_styles?: number;
};

type HltbAuth = {
  token: string;
  key?: string;
  value?: string;
};

type TokenCache = {
  value: string;
  expiresAt: number;
};

type GgDealsGamePrices = {
  title?: unknown;
  url?: unknown;
  prices?: {
    currentRetail?: unknown;
    currentKeyshops?: unknown;
    historicalRetail?: unknown;
    historicalKeyshops?: unknown;
    currency?: unknown;
  };
};

type GgDealsResponse = {
  success?: boolean;
  data?: Record<string, GgDealsGamePrices | null>;
};

class GgDealsApiError extends Error {
  constructor(public status: number, public retryAfter?: string) {
    super(`GG.deals API error: ${status}`);
  }
}

const IGDB_BASE_URL = 'https://api.igdb.com/v4';
const TWITCH_TOKEN_URL = 'https://id.twitch.tv/oauth2/token';
const HLTB_BASE_URL = 'https://howlongtobeat.com';
const HLTB_GAME_URL = `${HLTB_BASE_URL}/game`;
const HLTB_FALLBACK_SEARCH_PATH = '/api/search/site';
const HLTB_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const DEFAULT_ALLOWED_ORIGINS = ['https://tinykings.github.io', 'https://void.tinyk.ing', 'http://localhost:3000', 'http://127.0.0.1:3000'];
const TMDB_BASE_URL = 'https://api.themoviedb.org/3';
const TMDB_CACHE_SECONDS = 60 * 60;
const SEARCH_CACHE_SECONDS = 60 * 60;
const DETAILS_CACHE_SECONDS = 60 * 60 * 24;
const PRICE_CACHE_SECONDS = 60 * 60;
const PRICE_MISS_CACHE_SECONDS = 60 * 10;
const PRICE_RECORD_CACHE_VERSION = 'gg-price-record-1';
const TRENDING_CACHE_SECONDS = 60 * 60 * 6;
const CACHE_VERSION = 'gg-prices-v2-game-media-trending-5-hltb-site-search';
const MAX_URL_LENGTH = 2048;
const MAX_SEARCH_QUERY_LENGTH = 100;
const MAX_PRICE_IDS = 50;
const RATE_LIMIT_RETRY_SECONDS = 60;
const STEAM_EXTERNAL_GAME_CATEGORY = 1;
const GG_DEALS_REGIONS = new Set([
  'au', 'be', 'br', 'ca', 'ch', 'de', 'dk', 'es', 'eu', 'fi', 'fr', 'gb', 'ie', 'it', 'nl', 'no', 'pl', 'se', 'us',
]);

let tokenCache: TokenCache | null = null;
let hltbSearchPathCache: string | null = null;

const getAllowedOrigins = (env: Env) => {
  const configured = env.ALLOWED_ORIGINS?.split(',').map((origin) => origin.trim()).filter(Boolean);
  return [...new Set(configured?.length ? configured : DEFAULT_ALLOWED_ORIGINS)];
};

const allowsOriginlessRequests = (env: Env) => env.ALLOW_ORIGINLESS_REQUESTS?.toLowerCase() === 'true';

const getCorsOrigin = (request: Request, env: Env) => {
  const origin = request.headers.get('Origin');
  const allowedOrigins = getAllowedOrigins(env);

  if (allowedOrigins.includes('*')) return '*';
  if (!origin) return allowsOriginlessRequests(env) ? '*' : '';
  return allowedOrigins.includes(origin) ? origin : '';
};

const isRequestOriginAllowed = (request: Request, env: Env) => {
  const origin = request.headers.get('Origin');
  if (!origin) return allowsOriginlessRequests(env);
  return getAllowedOrigins(env).includes('*') || getAllowedOrigins(env).includes(origin);
};

const getClientKey = (request: Request) => request.headers.get('CF-Connecting-IP') || 'local';

const logSecurityEvent = (request: Request, event: string, details: Record<string, unknown> = {}) => {
  const url = new URL(request.url);
  console.warn(JSON.stringify({
    level: 'warn',
    event,
    method: request.method,
    path: url.pathname,
    origin: request.headers.get('Origin') || null,
    ray: request.headers.get('CF-Ray') || null,
    ...details,
  }));
};

const corsHeaders = (request: Request, env: Env) => {
  const origin = getCorsOrigin(request, env);
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Vary': 'Origin',
  };

  if (origin) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
};

const jsonResponse = (request: Request, env: Env, data: unknown, init: ResponseInit = {}) => {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      'X-Content-Type-Options': 'nosniff',
      ...corsHeaders(request, env),
      ...init.headers,
    },
  });
};

const errorResponse = (request: Request, env: Env, status: number, error: string, headers: Record<string, string> = {}) => {
  return jsonResponse(request, env, { error }, {
    status,
    headers: {
      'Cache-Control': 'no-store',
      ...headers,
    },
  });
};

const applyRateLimit = async (request: Request, env: Env, route: string) => {
  // Price quota belongs to one shared GG.deals key, so share its limiter within
  // each Cloudflare location. Other routes remain isolated per client.
  const key = route === 'prices' ? 'gg-deals:prices' : `${getClientKey(request)}:${route}`;
  const result = await env.RATE_LIMITER.limit({ key });
  return result.success;
};

const escapeIgdbString = (value: string) => value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

const imageUrl = (imageId: string | undefined, size: string) => {
  if (!imageId) return null;
  return `https://images.igdb.com/igdb/image/upload/t_${size}/${imageId}.jpg`;
};

const dateFromUnixSeconds = (value?: number) => {
  if (!value) return undefined;
  return new Date(value * 1000).toISOString().split('T')[0];
};

const parsePositiveInteger = (value: unknown) => {
  if (typeof value !== 'string' || !/^\d+$/.test(value)) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
};

const getSteamAppIdFromUrl = (value: string | undefined) => {
  if (!value) return undefined;

  try {
    const url = new URL(value);
    if (url.hostname !== 'store.steampowered.com' && url.hostname !== 'www.store.steampowered.com') return undefined;
    return parsePositiveInteger(url.pathname.match(/^\/app\/(\d+)(?:\/|$)/)?.[1]);
  } catch {
    return undefined;
  }
};

export const getSteamAppId = (game: IgdbGame) => {
  const externalId = game.external_games
    ?.find((externalGame) => externalGame.category === STEAM_EXTERNAL_GAME_CATEGORY)
    ?.uid;
  const parsedExternalId = parsePositiveInteger(externalId);
  if (parsedExternalId) return parsedExternalId;

  for (const website of game.websites || []) {
    const websiteId = getSteamAppIdFromUrl(website.url);
    if (websiteId) return websiteId;
  }

  return undefined;
};

const normalizePrice = (value: unknown) => {
  if (typeof value !== 'string' || !/^\d+(?:\.\d+)?$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? value : null;
};

const normalizeGgDealsUrl = (value: unknown) => {
  if (typeof value !== 'string') return null;

  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || (url.hostname !== 'gg.deals' && url.hostname !== 'www.gg.deals')) return null;
    return url.href;
  } catch {
    return null;
  }
};

// The aggregate quote GG.deals returns for a Steam App ID. It has no shop,
// platform, DRM or edition, so none is inferred here. Prices are for Steam games
// only: GG.deals' API has no platform data, so console games can't be priced.
export const normalizeGgDealsAggregate = (game: GgDealsGamePrices | null | undefined) => {
  if (!game || typeof game.title !== 'string') return null;
  const url = normalizeGgDealsUrl(game.url);
  const currency = game.prices?.currency;
  if (!url || typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) return null;

  const currentRetail = normalizePrice(game.prices?.currentRetail);
  const currentKeyshops = normalizePrice(game.prices?.currentKeyshops);
  const historicalRetail = normalizePrice(game.prices?.historicalRetail);
  const historicalKeyshops = normalizePrice(game.prices?.historicalKeyshops);
  const retailAmount = currentRetail === null ? null : Number(currentRetail);
  const keyshopAmount = currentKeyshops === null ? null : Number(currentKeyshops);
  const lowestCurrent = retailAmount === null && keyshopAmount === null
    ? null
    : retailAmount !== null && (keyshopAmount === null || retailAmount <= keyshopAmount)
      ? { amount: currentRetail as string, source: 'retail' as const }
      : { amount: currentKeyshops as string, source: 'keyshop' as const };

  return {
    title: game.title,
    url,
    currency,
    currentRetail,
    currentKeyshops,
    historicalRetail,
    historicalKeyshops,
    lowestCurrent,
  };
};

export const normalizeGgDealsGamePrice = (steamAppId: number, game: GgDealsGamePrices | null | undefined) => {
  const aggregate = normalizeGgDealsAggregate(game);
  return aggregate && { steamAppId, ...aggregate };
};

const getGgDealsRetryAfter = (response: Response) => {
  const header = response.headers.get('x-ratelimit-reset');
  const reset = header ? Number(header) : NaN;
  if (Number.isFinite(reset) && reset >= 0) {
    // Accept either a Unix timestamp or a seconds-until-reset delta.
    const seconds = reset > 1_000_000_000 ? reset - Date.now() / 1000 : reset;
    return String(Math.max(1, Math.ceil(seconds)));
  }
  return response.headers.get('Retry-After') || String(RATE_LIMIT_RETRY_SECONDS);
};

type GgDealsLookupKind = 'steam-app';

const GG_DEALS_LOOKUPS: Record<GgDealsLookupKind, { url: string; param: string }> = {
  'steam-app': { url: 'https://api.gg.deals/v1/prices/by-steam-app-id/', param: 'ids' },
};

// Upstream entries (only the fields we use) are what's cached, and they're
// normalized again on every read. `null` is a confirmed "GG.deals has no
// match"; an absent record is unknown (omitted or malformed) and never cached.
type GgDealsRecord = GgDealsGamePrices | null;
type GgDealsRecords = Map<string, GgDealsRecord>;

const fetchGgDealsRecords = async (env: Env, kind: GgDealsLookupKind, ids: string[], region: string) => {
  if (!env.GG_DEALS_API_KEY) throw new Error('GG.deals API key is not configured');

  const lookup = GG_DEALS_LOOKUPS[kind];
  const url = new URL(lookup.url);
  url.searchParams.set(lookup.param, ids.join(','));
  url.searchParams.set('key', env.GG_DEALS_API_KEY);
  url.searchParams.set('region', region);

  // One attempt only: every requested ID counts against the shared quota,
  // even on failure, so retries would spend it twice.
  const response = await fetch(url);
  if (!response.ok) {
    throw new GgDealsApiError(response.status, response.status === 429 ? getGgDealsRetryAfter(response) : undefined);
  }

  const data = await response.json() as GgDealsResponse;
  if (!data.success || !data.data || typeof data.data !== 'object') throw new Error('GG.deals response was incomplete');

  const records: GgDealsRecords = new Map();
  for (const id of ids) {
    if (!Object.hasOwn(data.data, id)) continue;
    const entry = data.data[id];
    if (entry === null) {
      records.set(id, null);
      continue;
    }
    if (normalizeGgDealsAggregate(entry)) {
      const { currentRetail, currentKeyshops, historicalRetail, historicalKeyshops, currency } = entry.prices || {};
      records.set(id, {
        title: entry.title,
        url: entry.url,
        prices: { currentRetail, currentKeyshops, historicalRetail, historicalKeyshops, currency },
      });
    }
  }
  return records;
};

const priceRecordCacheKey = (request: Request, kind: GgDealsLookupKind, region: string, id: string) => {
  // Internal key: no API key, client origin or caller query. Responses are
  // rebuilt (with CORS) for each caller, so any origin may share a record.
  const origin = new URL(request.url).origin;
  return new Request(`${origin}/__cache/${PRICE_RECORD_CACHE_VERSION}/${kind}/${region}/${encodeURIComponent(id)}`);
};

const readCachedPriceRecord = async (cache: Cache, key: Request): Promise<{ record: GgDealsRecord } | undefined> => {
  const cached = await cache.match(key);
  if (!cached) return undefined;
  try {
    const body = await cached.json() as { record?: unknown };
    if (body.record === null) return { record: null };
    const record = body.record as GgDealsGamePrices;
    return normalizeGgDealsAggregate(record) ? { record } : undefined;
  } catch {
    return undefined;
  }
};

// Upstream batches in flight in this isolate, per record key. This avoids
// duplicate spends for concurrent misses on one isolate only; other isolates
// and Cloudflare locations still fetch independently.
const inFlightPriceRecords = new Map<string, Promise<{ record: GgDealsRecord } | undefined>>();

export const getGgDealsRecords = async (
  request: Request,
  env: Env,
  ctx: ExecutionContextLike,
  kind: GgDealsLookupKind,
  ids: string[],
  region: string,
) => {
  const cache = (caches as CacheStorage & { default: Cache }).default;
  const keys = new Map(ids.map((id) => [id, priceRecordCacheKey(request, kind, region, id)]));
  const results = new Map<string, { record: GgDealsRecord } | undefined>();

  await Promise.all(ids.map(async (id) => {
    const cached = await readCachedPriceRecord(cache, keys.get(id) as Request);
    if (cached) results.set(id, cached);
  }));

  const pending = new Map<string, Promise<{ record: GgDealsRecord } | undefined>>();
  const toFetch: string[] = [];
  for (const id of ids) {
    if (results.has(id)) continue;
    const inFlight = inFlightPriceRecords.get(keys.get(id)!.url);
    if (inFlight) pending.set(id, inFlight);
    else toFetch.push(id);
  }

  if (toFetch.length > 0) {
    const batch = fetchGgDealsRecords(env, kind, toFetch, region);
    for (const id of toFetch) {
      const cacheUrl = keys.get(id)!.url;
      const promise = batch
        .then((records) => (records.has(id) ? { record: records.get(id) as GgDealsRecord } : undefined))
        .finally(() => inFlightPriceRecords.delete(cacheUrl));
      inFlightPriceRecords.set(cacheUrl, promise);
      pending.set(id, promise);
    }
    const records = await batch.catch(() => undefined);
    for (const [id, record] of records || []) {
      const seconds = record === null ? PRICE_MISS_CACHE_SECONDS : PRICE_CACHE_SECONDS;
      ctx.waitUntil(cache.put(keys.get(id) as Request, new Response(JSON.stringify({ record }), {
        headers: { 'Content-Type': 'application/json', 'Cache-Control': `public, max-age=${seconds}` },
      })));
    }
  }

  // Any upstream failure (including 429) rejects here, and nothing was cached.
  const settled = await Promise.all([...pending].map(async ([id, promise]) => [id, await promise] as const));
  for (const [id, value] of settled) results.set(id, value);

  const records: GgDealsRecords = new Map();
  for (const id of ids) {
    const value = results.get(id);
    if (value) records.set(id, value.record);
  }
  return records;
};

const parsePriceRegion = (url: URL) => {
  const region = (url.searchParams.get('region') || 'us').toLowerCase();
  return GG_DEALS_REGIONS.has(region) ? region : undefined;
};

const priceResponse = (request: Request, env: Env, ids: string[], records: Map<string, unknown>, data: unknown) => {
  // A brief max-age when any answer is a negative or unknown match, so a
  // client does not hold on to "no price" for an hour.
  const complete = ids.every((id) => records.get(id));
  const seconds = complete ? PRICE_CACHE_SECONDS : PRICE_MISS_CACHE_SECONDS;
  return jsonResponse(request, env, data, { headers: { 'Cache-Control': `public, max-age=${seconds}` } });
};

const normalizeSearchText = (value: string) =>
  value
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

const getSearchTokens = (value: string) => normalizeSearchText(value).split(' ').filter(Boolean);

const getBigrams = (value: string) => {
  const normalized = normalizeSearchText(value).replace(/\s+/g, '');
  if (normalized.length < 2) return normalized ? [normalized] : [];

  const bigrams: string[] = [];
  for (let index = 0; index < normalized.length - 1; index += 1) {
    bigrams.push(normalized.slice(index, index + 2));
  }
  return bigrams;
};

const getDiceSimilarity = (a: string, b: string) => {
  const aNormalized = normalizeSearchText(a);
  const bNormalized = normalizeSearchText(b);
  if (!aNormalized || !bNormalized) return 0;
  if (aNormalized === bNormalized) return 1;

  const aBigrams = getBigrams(aNormalized);
  const bBigrams = getBigrams(bNormalized);
  if (aBigrams.length === 0 || bBigrams.length === 0) return 0;

  const counts = new Map<string, number>();
  for (const bigram of aBigrams) counts.set(bigram, (counts.get(bigram) || 0) + 1);

  let intersections = 0;
  for (const bigram of bBigrams) {
    const count = counts.get(bigram) || 0;
    if (count > 0) {
      intersections += 1;
      counts.set(bigram, count - 1);
    }
  }

  return (2 * intersections) / (aBigrams.length + bBigrams.length);
};

const getTokenCoverage = (queryTokens: string[], candidateTokens: string[]) => {
  if (queryTokens.length === 0 || candidateTokens.length === 0) return 0;
  const candidateSet = new Set(candidateTokens);
  const matches = queryTokens.filter((token) => candidateSet.has(token)).length;
  return matches / queryTokens.length;
};

const secondsToHours = (seconds: number | undefined) => {
  if (!seconds || seconds <= 0) return undefined;
  return Number((seconds / 3600).toFixed(1));
};

const getReleaseYear = (game: IgdbGame) => {
  const releaseDate = dateFromUnixSeconds(game.first_release_date);
  return releaseDate ? releaseDate.split('-')[0] : undefined;
};

const scoreHltbMatch = (candidate: HltbSearchGame, title: string, releaseYear?: string) => {
  const query = normalizeSearchText(title);
  const queryTokens = getSearchTokens(title);
  const candidateTitle = normalizeSearchText(candidate.game_name || '');
  const candidateAlias = normalizeSearchText(candidate.game_alias || '');
  const candidateTokens = getSearchTokens(candidate.game_name || '');
  const aliasTokens = getSearchTokens(candidate.game_alias || '');
  const candidateYear = candidate.release_world ? String(candidate.release_world) : '';

  if (!candidate.game_id || !candidateTitle) return Number.NEGATIVE_INFINITY;

  const similarity = Math.max(
    getDiceSimilarity(query, candidateTitle),
    getDiceSimilarity(query, candidateAlias),
    getTokenCoverage(queryTokens, candidateTokens),
    getTokenCoverage(queryTokens, aliasTokens),
  );
  let score = similarity * 100;

  if (candidateTitle === query) score += 30;
  else if (candidateAlias === query) score += 25;
  else if (candidateTitle.includes(query) || query.includes(candidateTitle)) score += 12;
  else if (candidateAlias && (candidateAlias.includes(query) || query.includes(candidateAlias))) score += 10;

  if (candidate.game_type && !['game', 'multi'].includes(candidate.game_type)) score -= 20;

  if (releaseYear && candidateYear === releaseYear) score += 10;
  if (candidate.comp_main || candidate.comp_all || candidate.comp_plus || candidate.comp_100) score += 5;

  return score;
};

const getBestHltbMatch = (items: HltbSearchGame[], title: string, releaseYear?: string) => {
  const [best] = [...items]
    .map((item) => ({ item, score: scoreHltbMatch(item, title, releaseYear) }))
    .filter(({ score }) => score >= 45)
    .sort((a, b) => b.score - a.score);

  return best?.item || null;
};

const buildHltbCompletion = (match: HltbSearchGame): HltbCompletion | null => {
  const hltbId = match.game_id;
  const mainStory = secondsToHours(match.comp_main);
  const mainExtra = secondsToHours(match.comp_plus);
  const completionist = secondsToHours(match.comp_100);
  const allStyles = secondsToHours(match.comp_all);
  const playtime = mainStory || allStyles || mainExtra || completionist;
  if (!hltbId || !playtime) return null;

  return {
    hltb_id: hltbId,
    hltb_url: `${HLTB_GAME_URL}/${hltbId}`,
    playtime,
    ...(mainStory ? { playtime_main: mainStory } : {}),
    ...(mainExtra ? { playtime_extra: mainExtra } : {}),
    ...(completionist ? { playtime_completionist: completionist } : {}),
    ...(allStyles ? { playtime_all_styles: allStyles } : {}),
  };
};

const fetchWithTimeout = async (url: string, init: RequestInit = {}, timeoutMs = 5000) => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return await fetch(url, {
      ...init,
      signal: init.signal || controller.signal,
    });
  } finally {
    clearTimeout(timeout);
  }
};

const getHltbHeaders = (auth?: HltbAuth) => {
  const headers: Record<string, string> = {
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': HLTB_BASE_URL,
    'Referer': `${HLTB_BASE_URL}/`,
    'User-Agent': HLTB_USER_AGENT,
  };

  if (auth) {
    headers['x-auth-token'] = auth.token;
    if (auth.key) headers['x-hp-key'] = auth.key;
    if (auth.value) headers['x-hp-val'] = auth.value;
  }

  return headers;
};

const getHltbScriptSources = (html: string, parseAllScripts: boolean) => {
  const scripts = [...html.matchAll(/<script[^>]+src=["']([^"']+)["'][^>]*>/gi)]
    .map((match) => match[1])
    .filter(Boolean);
  return parseAllScripts ? scripts : scripts.filter((src) => src.includes('_app-'));
};

// The site fetches a search token from `<search path>/init?t=…` and then POSTs the
// search to `<search path>` (in November 2026, `/api/search/site`). The path has
// changed before and can have more than one segment, so keep all of it.
export const extractHltbSearchPath = (scriptContent: string) => {
  const init = scriptContent.match(/["'`](\/api\/[a-zA-Z0-9_/]+?)\/init\?t=/);
  if (init?.[1]) return init[1];

  const post = scriptContent.match(/fetch\s*\(\s*["'`](\/api\/[a-zA-Z0-9_/]+)["'`]\s*,\s*{[^}]*method:\s*["']POST["'][^}]*["']x-auth-token["']/is);
  return post?.[1] || null;
};

const discoverHltbSearchPath = async (parseAllScripts: boolean) => {
  const homeResponse = await fetchWithTimeout(`${HLTB_BASE_URL}/`, { headers: getHltbHeaders() });
  if (!homeResponse.ok) return null;

  const homeHtml = await homeResponse.text();
  for (const scriptSrc of getHltbScriptSources(homeHtml, parseAllScripts)) {
    const scriptUrl = new URL(scriptSrc, `${HLTB_BASE_URL}/`).href;
    const scriptResponse = await fetchWithTimeout(scriptUrl, { headers: getHltbHeaders() });
    if (!scriptResponse.ok) continue;

    const searchPath = extractHltbSearchPath(await scriptResponse.text());
    if (searchPath) return searchPath;
  }

  return null;
};

const getHltbSearchPath = async () => {
  if (hltbSearchPathCache) return hltbSearchPathCache;

  hltbSearchPathCache = (await discoverHltbSearchPath(false)) || (await discoverHltbSearchPath(true)) || HLTB_FALLBACK_SEARCH_PATH;
  return hltbSearchPathCache;
};

const extractHltbAuth = (initData: HltbInitResponse): HltbAuth | null => {
  if (!initData.token) return null;

  let key: string | undefined;
  let value: string | undefined;
  for (const [fieldName, fieldValue] of Object.entries(initData)) {
    const lower = fieldName.toLowerCase();
    if (lower.includes('key')) key = fieldValue;
    if (lower.includes('val')) value = fieldValue;
  }

  return {
    token: initData.token,
    key,
    value,
  };
};

const getHltbAuth = async (searchPath: string) => {
  const initUrl = new URL(`${searchPath.replace(/\/$/, '')}/init`, `${HLTB_BASE_URL}/`);
  initUrl.searchParams.set('t', String(Date.now()));

  const initResponse = await fetchWithTimeout(initUrl.href, { headers: getHltbHeaders() });
  if (!initResponse.ok) return null;

  return extractHltbAuth(await initResponse.json() as HltbInitResponse);
};

const fetchHowLongToBeat = async (game: IgdbGame): Promise<HltbCompletion | null> => {
  const title = game.name?.trim();
  if (!title) return null;

  try {
    const searchPath = await getHltbSearchPath();
    const auth = await getHltbAuth(searchPath);
    if (!auth) return null;

    const payload: Record<string, unknown> = {
      searchType: 'games',
      searchTerms: title.split(/\s+/).filter(Boolean),
      searchPage: 1,
      size: 20,
      searchOptions: {
        games: {
          userId: 0,
          platform: '',
          sortCategory: 'popular',
          rangeCategory: 'main',
          rangeTime: { min: 0, max: 0 },
          gameplay: {
            perspective: '',
            flow: '',
            genre: '',
          },
          year: '',
          modifier: 'hide_dlc',
        },
        users: { sortCategory: 'postcount' },
        lists: { sortCategory: 'follows' },
        filter: '',
        sort: 0,
        randomizer: 0,
      },
      useCache: true,
    };

    if (auth.key && auth.value) {
      payload[auth.key] = auth.value;
    }

    const searchUrl = new URL(searchPath, `${HLTB_BASE_URL}/`).href;
    const searchResponse = await fetchWithTimeout(searchUrl, {
      method: 'POST',
      headers: {
        ...getHltbHeaders(auth),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!searchResponse.ok) return null;

    const searchData = await searchResponse.json() as HltbSearchResponse;
    const match = getBestHltbMatch(searchData.data || [], title, getReleaseYear(game));
    return match ? buildHltbCompletion(match) : null;
  } catch (error) {
    console.error('HowLongToBeat request failed:', error);
    return null;
  }
};

const normalizeGame = (game: IgdbGame, hltbCompletion?: HltbCompletion | null, hltbChecked = false) => {
  const screenshots = (game.screenshots || [])
    .map((image) => imageUrl(image.image_id, 'screenshot_big_2x'))
    .filter((url): url is string => !!url);
  const poster = imageUrl(game.cover?.image_id, 'cover_big_2x') || screenshots[0] || null;
  const slug = game.slug || '';
  const videos = (game.videos || [])
    .filter((video) => video.video_id)
    .slice(0, 3)
    .map((video) => ({
      id: video.video_id || '',
      key: video.video_id || '',
      name: video.name || 'Trailer',
      site: 'YouTube',
      type: 'Trailer',
      official: true,
      published_at: '',
    }));

  return {
    id: game.id,
    title: game.name || 'Unknown',
    name: game.name || 'Unknown',
    poster_path: poster,
    backdrop_path: screenshots[0] || poster,
    overview: game.summary || '',
    release_date: dateFromUnixSeconds(game.first_release_date),
    vote_average: game.total_rating ? game.total_rating / 10 : 0,
    vote_count: game.total_rating_count || 0,
    popularity: game.total_rating_count || 0,
    media_type: 'game',
    source: 'igdb',
    poster_source: 'igdb',
    platforms: (game.platforms || []).map((platform) => platform.name).filter(Boolean),
    genres: (game.genres || []).map((genre) => genre.name).filter(Boolean),
    website: game.websites?.find((site) => site.url)?.url || null,
    steam_app_id: getSteamAppId(game),
    screenshots: screenshots.slice(0, 3),
    videos,
    source_url: slug ? `https://www.igdb.com/games/${slug}` : undefined,
    ...(hltbChecked ? { hltb_checked_at: Date.now() } : {}),
    ...(hltbCompletion || {}),
  };
};

const getAccessToken = async (env: Env) => {
  if (!env.IGDB_CLIENT_ID || !env.IGDB_CLIENT_SECRET) {
    throw new Error('IGDB credentials are not configured');
  }

  if (tokenCache && tokenCache.expiresAt > Date.now() + 60_000) {
    return tokenCache.value;
  }

  const url = new URL(TWITCH_TOKEN_URL);
  url.searchParams.set('client_id', env.IGDB_CLIENT_ID);
  url.searchParams.set('client_secret', env.IGDB_CLIENT_SECRET);
  url.searchParams.set('grant_type', 'client_credentials');

  const response = await fetch(url, { method: 'POST' });
  if (!response.ok) {
    throw new Error(`Twitch token error: ${response.status}`);
  }

  const data = await response.json() as { access_token?: string; expires_in?: number };
  if (!data.access_token || !data.expires_in) {
    throw new Error('Twitch token response was incomplete');
  }

  tokenCache = {
    value: data.access_token,
    expiresAt: Date.now() + Math.max(data.expires_in - 300, 60) * 1000,
  };

  return tokenCache.value;
};

const fetchIgdb = async <T = IgdbGame[]>(env: Env, body: string, endpoint = 'games', retry = true): Promise<T> => {
  const token = await getAccessToken(env);
  const response = await fetch(`${IGDB_BASE_URL}/${endpoint}`, {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Authorization': `Bearer ${token}`,
      'Client-ID': env.IGDB_CLIENT_ID,
    },
    body,
  });

  if (response.status === 401 && retry) {
    tokenCache = null;
    return fetchIgdb<T>(env, body, endpoint, false);
  }

  if (!response.ok) {
    throw new Error(`IGDB API error: ${response.status}`);
  }

  return response.json();
};

const gameFields = [
  'id',
  'name',
  'slug',
  'summary',
  'first_release_date',
  'total_rating',
  'total_rating_count',
  'cover.image_id',
  'screenshots.image_id',
  'platforms.name',
  'genres.name',
  'websites.url',
  'external_games.category',
  'external_games.uid',
  'videos.name',
  'videos.video_id',
].join(',');

const searchGames = async (env: Env, query: string) => {
  const body = [
    `search "${escapeIgdbString(query)}";`,
    `fields ${gameFields};`,
    'where version_parent = null;',
    'limit 20;',
  ].join(' ');

  const games = await fetchIgdb(env, body);
  return games.map((game) => normalizeGame(game));
};

const getGameDetails = async (env: Env, id: number) => {
  const body = [
    `fields ${gameFields};`,
    `where id = ${id};`,
    'limit 1;',
  ].join(' ');

  const [game] = await fetchIgdb(env, body);
  if (!game) return null;

  const hltbCompletion = await fetchHowLongToBeat(game);
  return normalizeGame(game, hltbCompletion, true);
};

// Trending games: IGDB's popularity primitives, several signals blended so no one
// platform or audience dominates. Each signal's top games are ranked, and a game's
// score is the sum of 1 / (k + rank) over the signals it appears in (reciprocal rank
// fusion), since the raw values aren't on comparable scales. Signals that measure
// steady player or viewer counts (IGDB "Playing", Steam peak players, Twitch hours
// watched) are left out: they keep the same evergreen games on top every week.
// IDs from IGDB's /popularity_types.
export const TRENDING_SIGNALS: { name: string; type: number }[] = [
  { name: 'visits', type: 1 },       // IGDB page visits
  { name: 'want_to_play', type: 2 }, // IGDB "Want to Play" lists
  { name: 'top_sellers', type: 9 },  // Steam global top sellers
];
// Deep enough that the signals overlap: a game must be in two of them to count.
const TRENDING_PER_SIGNAL = 150;
const TRENDING_MIN_SIGNALS = 2;
const TRENDING_LIMIT = 20;
const TRENDING_RRF_K = 20;
const YEAR_SECONDS = 365 * 24 * 60 * 60;

type IgdbMultiqueryResult = { name: string; result?: { game_id?: number; value?: number }[] }[];

// Only games in at least `minSignals` of the signals count, so a one-day spike in
// visits or a cheap game that briefly sells well on Steam doesn't make the list.
export const blendTrending = (results: IgdbMultiqueryResult, limit = TRENDING_LIMIT, minSignals = TRENDING_MIN_SIGNALS): [number, number][] => {
  const scores = new Map<number, number>();
  const counts = new Map<number, number>();
  for (const signal of results) {
    const seen = new Set<number>();
    for (const entry of signal.result || []) {
      const id = entry.game_id;
      if (!Number.isSafeInteger(id) || !id || id <= 0 || seen.has(id)) continue;
      seen.add(id);
      scores.set(id, (scores.get(id) || 0) + 1 / (TRENDING_RRF_K + seen.size));
      counts.set(id, (counts.get(id) || 0) + 1);
    }
  }
  return [...scores.entries()]
    .filter(([id]) => (counts.get(id) || 0) >= minSignals)
    .sort((a, b) => b[1] - a[1] || a[0] - b[0]).slice(0, limit);
};

// Games out for more than a year count for less the older they are: half at two
// years, a third at three. Upcoming and undated games count in full.
export const recencyWeight = (releaseSeconds: number | undefined, nowSeconds: number) => {
  if (!releaseSeconds) return 1;
  const years = (nowSeconds - releaseSeconds) / YEAR_SECONDS;
  return years <= 1 ? 1 : 1 / years;
};

// IGDB game types that are a game in their own right: main game, standalone
// expansion, remake, remaster, expanded game. Not DLC, bundles, mods, episodes or packs.
const TRENDING_GAME_TYPES = new Set([0, 4, 8, 9, 10]);
const EROTIC_THEME = 42;

// "Minecraft: Java Edition" when "Minecraft" is already listed.
const isEditionOf = (name: string, others: Set<string>) => {
  const match = name.toLowerCase().match(/^(.+?):\s.*\bedition$/);
  return !!match && others.has(match[1].trim());
};

export const rankTrending = (games: IgdbGame[], scores: [number, number][], nowSeconds: number, limit = TRENDING_LIMIT) => {
  const byId = new Map(games.map((game) => [game.id, game]));
  const listedIds = new Set(byId.keys());
  const ranked = scores
    .map(([id, score]) => ({ game: byId.get(id), score }))
    .filter((entry): entry is { game: IgdbGame; score: number } => !!entry.game)
    .filter(({ game }) => !game.version_parent && !(game.parent_game && listedIds.has(game.parent_game)))
    .filter(({ game }) => game.game_type === undefined || TRENDING_GAME_TYPES.has(game.game_type))
    .filter(({ game }) => !(game.themes || []).some((theme) => theme.id === EROTIC_THEME))
    .map(({ game, score }) => ({ game, score: score * recencyWeight(game.first_release_date, nowSeconds) }))
    .sort((a, b) => b.score - a.score || a.game.id - b.game.id);
  const names = new Set<string>();
  const picked: IgdbGame[] = [];
  for (const { game } of ranked) {
    const name = (game.name || '').toLowerCase().trim();
    if (names.has(name) || isEditionOf(name, names)) continue;
    names.add(name);
    picked.push(game);
    if (picked.length === limit) break;
  }
  // An edition can come before its base game; drop it once the base is in.
  return picked.filter((game) => !isEditionOf((game.name || '').toLowerCase().trim(), names));
};

// Upcoming: the games most followed before release (IGDB hypes) coming out in the
// next 30 days.
const UPCOMING_LIMIT = 6;
const UPCOMING_DAYS = 30;

const getUpcomingGames = async (env: Env, nowSeconds: number) => {
  const from = Math.floor(nowSeconds);
  const to = from + UPCOMING_DAYS * 24 * 60 * 60;
  const games = await fetchIgdb(env, [
    `fields ${gameFields},version_parent,parent_game,game_type,themes.id,hypes;`,
    `where first_release_date > ${from} & first_release_date < ${to} & version_parent = null & hypes > 0;`,
    'sort hypes desc;',
    `limit ${UPCOMING_LIMIT * 4};`,
  ].join(' '));
  const scores = games.map((game, index): [number, number] => [game.id, games.length - index]);
  // The same filters as trending; every game here is new, so recency changes nothing.
  return rankTrending(games, scores, nowSeconds, UPCOMING_LIMIT).map((game) => normalizeGame(game));
};

const getTrendingGames = async (env: Env) => {
  const body = TRENDING_SIGNALS.map(({ name, type }) =>
    `query popularity_primitives "${name}" { fields game_id,value; where popularity_type = ${type}; sort value desc; limit ${TRENDING_PER_SIGNAL}; };`,
  ).join('\n');
  const signals = await fetchIgdb<IgdbMultiqueryResult>(env, body, 'multiquery');
  // Extra candidates, since the recency weighting reorders them and editions drop out.
  const scores = blendTrending(signals, TRENDING_LIMIT * 4);
  if (scores.length === 0) return [];
  const games = await fetchIgdb(env, [
    `fields ${gameFields},version_parent,parent_game,game_type,themes.id;`,
    `where id = (${scores.map(([id]) => id).join(',')});`,
    `limit ${scores.length};`,
  ].join(' '));
  return rankTrending(games, scores, Date.now() / 1000).map((game) => normalizeGame(game));
};

const withCache = async (
  request: Request,
  env: Env,
  ctx: ExecutionContextLike,
  seconds: number,
  resolver: () => Promise<Response>,
) => {
  const cache = (caches as CacheStorage & { default: Cache }).default;
  const cacheUrl = new URL(request.url);
  cacheUrl.searchParams.set('__origin', getCorsOrigin(request, env) || 'blocked');
  cacheUrl.searchParams.set('__version', CACHE_VERSION);
  const cacheKey = new Request(cacheUrl.toString(), request);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const response = await resolver();
  if (response.ok) {
    const cachedResponse = new Response(response.body, response);
    cachedResponse.headers.set('Cache-Control', `public, max-age=${seconds}`);
    ctx.waitUntil(cache.put(cacheKey, cachedResponse.clone()));
    return cachedResponse;
  }

  return response;
};

// TMDB read-only proxy, so apps never ship the TMDB token. Only the endpoints
// the clients use are forwarded, each with its own allowed query parameters.
const TMDB_ROUTES: { pattern: RegExp; params: string[] }[] = [
  { pattern: /^\/search\/multi$/, params: ['query', 'page'] },
  { pattern: /^\/trending\/(all|movie|tv)\/week$/, params: ['page'] },
  // Upcoming: the clients send a date window and popularity order.
  { pattern: /^\/discover\/movie$/, params: ['primary_release_date.gte', 'primary_release_date.lte', 'sort_by'] },
  { pattern: /^\/discover\/tv$/, params: ['first_air_date.gte', 'first_air_date.lte', 'sort_by'] },
  { pattern: /^\/(movie|tv)\/\d{1,10}$/, params: ['append_to_response', 'include_image_language'] },
  { pattern: /^\/(movie|tv)\/\d{1,10}\/(credits|watch\/providers)$/, params: [] },
  { pattern: /^\/movie\/\d{1,10}\/release_dates$/, params: [] },
  { pattern: /^\/tv\/\d{1,10}\/content_ratings$/, params: [] },
  { pattern: /^\/tv\/\d{1,10}\/season\/\d{1,4}$/, params: [] },
  { pattern: /^\/person\/\d{1,10}(\/combined_credits)?$/, params: [] },
];
const TMDB_APPEND_VALUES = new Set(['videos', 'images']);

export const tmdbProxyPath = (pathname: string, searchParams: URLSearchParams): string | { error: string } => {
  const path = pathname.slice('/api/tmdb'.length);
  const route = TMDB_ROUTES.find((candidate) => candidate.pattern.test(path));
  if (!route) return { error: 'Unsupported TMDB endpoint' };
  const params = new URLSearchParams();
  for (const [key, value] of searchParams) {
    if (!route.params.includes(key) || params.has(key)) return { error: 'Unsupported query parameter' };
    if (value.length > MAX_SEARCH_QUERY_LENGTH) return { error: 'Query parameter is too long' };
    if (key === 'page' && !/^\d{1,3}$/.test(value)) return { error: 'Invalid page' };
    if (key === 'append_to_response' && !value.split(',').every((part) => TMDB_APPEND_VALUES.has(part))) {
      return { error: 'Unsupported append_to_response' };
    }
    if (key === 'include_image_language' && !/^[a-z,]{1,20}$/.test(value)) return { error: 'Invalid image language' };
    if (/_date\.(gte|lte)$/.test(key) && !/^\d{4}-\d{2}-\d{2}$/.test(value)) return { error: 'Invalid date' };
    if (key === 'sort_by' && value !== 'popularity.desc') return { error: 'Unsupported sort' };
    params.set(key, value);
  }
  if (route.params.includes('query') && !(params.get('query') || '').trim()) return { error: 'Search query is required' };
  const query = params.toString();
  return `${TMDB_BASE_URL}${path}${query ? `?${query}` : ''}`;
};

const fetchFromTmdb = async (request: Request, env: Env, upstreamUrl: string) => {
  if (!env.TMDB_READ_ACCESS_TOKEN) throw new Error('TMDB token is not configured');
  const response = await fetch(upstreamUrl, {
    headers: { Accept: 'application/json', Authorization: `Bearer ${env.TMDB_READ_ACCESS_TOKEN}` },
  });
  if (response.status === 404) return errorResponse(request, env, 404, 'Not found');
  if (response.status === 429) {
    return errorResponse(request, env, 429, 'TMDB rate limit reached', {
      'Retry-After': response.headers.get('Retry-After') || String(RATE_LIMIT_RETRY_SECONDS),
    });
  }
  if (!response.ok) throw new Error(`TMDB error: ${response.status}`);
  return jsonResponse(request, env, await response.json());
};

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContextLike): Promise<Response> {
    if (!isRequestOriginAllowed(request, env)) {
      logSecurityEvent(request, 'request_origin_blocked');
      return errorResponse(request, env, 403, 'Origin not allowed');
    }

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(request, env),
      });
    }

    if (request.method !== 'GET') {
      return errorResponse(request, env, 405, 'Method not allowed', { Allow: 'GET, OPTIONS' });
    }

    if (request.url.length > MAX_URL_LENGTH) {
      logSecurityEvent(request, 'request_url_too_long', { length: request.url.length });
      return errorResponse(request, env, 414, 'Request URL is too long');
    }

    const url = new URL(request.url);
    const route = url.pathname.startsWith('/api/tmdb/')
      ? 'tmdb'
      : url.pathname === '/api/games/search'
      ? 'search'
      : url.pathname === '/api/games/trending' || url.pathname === '/api/games/upcoming'
      ? 'trending'
      : url.pathname.startsWith('/api/games/')
        ? 'details'
        : (url.pathname === '/api/prices/steam' || url.pathname.startsWith('/api/prices/steam/'))
          ? 'prices'
          : 'other';

    try {
      if (!await applyRateLimit(request, env, route)) {
        logSecurityEvent(request, 'request_rate_limited', { route });
        return errorResponse(request, env, 429, 'Too many requests', {
          'Retry-After': String(RATE_LIMIT_RETRY_SECONDS),
        });
      }

      if (route === 'tmdb') {
        const upstream = tmdbProxyPath(url.pathname, url.searchParams);
        if (typeof upstream !== 'string') return errorResponse(request, env, 400, upstream.error);
        return withCache(request, env, ctx, TMDB_CACHE_SECONDS, () => fetchFromTmdb(request, env, upstream));
      }

      if (url.pathname === '/api/games/search') {
        const unexpectedParameters = [...url.searchParams.keys()].filter((key) => key !== 'q');
        if (unexpectedParameters.length > 0) {
          return errorResponse(request, env, 400, 'Unsupported query parameter');
        }

        const query = (url.searchParams.get('q') || '').trim();
        if (query.length < 2) {
          return errorResponse(request, env, 400, 'Search query must be at least 2 characters');
        }
        if (query.length > MAX_SEARCH_QUERY_LENGTH) {
          return errorResponse(request, env, 400, `Search query must not exceed ${MAX_SEARCH_QUERY_LENGTH} characters`);
        }

        return withCache(request, env, ctx, SEARCH_CACHE_SECONDS, async () => {
          const results = await searchGames(env, query);
          return jsonResponse(request, env, results);
        });
      }

      if (url.pathname === '/api/games/trending') {
        if ([...url.searchParams.keys()].length > 0) {
          return errorResponse(request, env, 400, 'Query parameters are not supported for trending games');
        }
        return withCache(request, env, ctx, TRENDING_CACHE_SECONDS, async () => {
          return jsonResponse(request, env, await getTrendingGames(env));
        });
      }

      if (url.pathname === '/api/games/upcoming') {
        if ([...url.searchParams.keys()].length > 0) {
          return errorResponse(request, env, 400, 'Query parameters are not supported for upcoming games');
        }
        return withCache(request, env, ctx, TRENDING_CACHE_SECONDS, async () => {
          return jsonResponse(request, env, await getUpcomingGames(env, Date.now() / 1000));
        });
      }

      if (url.pathname === '/api/prices/steam') {
        const unexpectedParameters = [...url.searchParams.keys()].filter((key) => key !== 'ids' && key !== 'region');
        if (unexpectedParameters.length > 0) {
          return errorResponse(request, env, 400, 'Unsupported query parameter');
        }

        const rawIds = url.searchParams.get('ids') || '';
        const idParts = rawIds.split(',');
        if (!rawIds || idParts.some((id) => !/^\d+$/.test(id))) {
          return errorResponse(request, env, 400, 'Invalid Steam App IDs');
        }
        const steamAppIds = [...new Set(idParts.map(parsePositiveInteger))];
        if (steamAppIds.some((id) => !id) || steamAppIds.length > MAX_PRICE_IDS) {
          return errorResponse(request, env, 400, `Provide between 1 and ${MAX_PRICE_IDS} Steam App IDs`);
        }
        const region = parsePriceRegion(url);
        if (!region) return errorResponse(request, env, 400, 'Unsupported GG.deals region');

        const ids = (steamAppIds as number[]).map(String);
        const records = await getGgDealsRecords(request, env, ctx, 'steam-app', ids, region);
        // Unmatched IDs are omitted, as before.
        const prices = (steamAppIds as number[])
          .map((steamAppId) => normalizeGgDealsGamePrice(steamAppId, records.get(String(steamAppId))))
          .filter((price) => price !== null);
        return priceResponse(request, env, ids, records, prices);
      }

      const priceMatch = url.pathname.match(/^\/api\/prices\/steam\/(\d+)$/);
      if (priceMatch) {
        const unexpectedParameters = [...url.searchParams.keys()].filter((key) => key !== 'region');
        if (unexpectedParameters.length > 0) {
          return errorResponse(request, env, 400, 'Unsupported query parameter');
        }

        const steamAppId = parsePositiveInteger(priceMatch[1]);
        if (!steamAppId) return errorResponse(request, env, 400, 'Invalid Steam App ID');
        const region = parsePriceRegion(url);
        if (!region) return errorResponse(request, env, 400, 'Unsupported GG.deals region');

        const records = await getGgDealsRecords(request, env, ctx, 'steam-app', [String(steamAppId)], region);
        // No match is `null`, as before.
        const price = normalizeGgDealsGamePrice(steamAppId, records.get(String(steamAppId)));
        return priceResponse(request, env, [String(steamAppId)], records, price);
      }

      const detailsMatch = url.pathname.match(/^\/api\/games\/(\d+)$/);
      if (detailsMatch) {
        if ([...url.searchParams.keys()].length > 0) {
          return errorResponse(request, env, 400, 'Query parameters are not supported for game details');
        }

        const id = Number(detailsMatch[1]);
        if (!Number.isSafeInteger(id) || id <= 0) {
          return errorResponse(request, env, 400, 'Invalid game ID');
        }

        return withCache(request, env, ctx, DETAILS_CACHE_SECONDS, async () => {
          const game = await getGameDetails(env, id);
          if (!game) return errorResponse(request, env, 404, 'Game not found');
          return jsonResponse(request, env, game);
        });
      }

      return errorResponse(request, env, 404, 'Not found');
    } catch (error) {
      if (error instanceof GgDealsApiError && error.status === 429) {
        logSecurityEvent(request, 'gg_deals_rate_limited', { route });
        return errorResponse(request, env, 429, 'Price service rate limit reached', {
          'Retry-After': error.retryAfter || String(RATE_LIMIT_RETRY_SECONDS),
        });
      }

      console.error(JSON.stringify({
        level: 'error',
        event: 'game_api_request_failed',
        path: url.pathname,
        ray: request.headers.get('CF-Ray') || null,
        message: error instanceof Error ? error.message : 'Game API request failed',
      }));
      return errorResponse(request, env, 502, 'Game API request failed');
    }
  },
};

export default worker;
