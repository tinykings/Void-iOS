import assert from 'node:assert/strict';
import test, { beforeEach } from 'node:test';
import worker, { normalizeGgDealsAggregate } from './index';

const game = (title: string, retail: string | null = '9.99', keyshop: string | null = '4.20') => ({
  title,
  url: `https://gg.deals/game/${title.toLowerCase().replace(/\s+/g, '-')}/`,
  prices: { currentRetail: retail, currentKeyshops: keyshop, historicalRetail: '0.99', historicalKeyshops: null, currency: 'USD' },
});

// In-memory stand-ins for the Workers Cache API and GG.deals.
let cacheStore: Map<string, { body: string; cacheControl: string | null }>;
let upstreamCalls: URL[];
let upstream: (url: URL) => Response;

const installMocks = () => {
  cacheStore = new Map();
  upstreamCalls = [];
  upstream = () => Response.json({ success: true, data: {} });
  (globalThis as any).caches = {
    default: {
      async match(request: Request) {
        const entry = cacheStore.get(request.url);
        return entry ? new Response(entry.body) : undefined;
      },
      async put(request: Request, response: Response) {
        cacheStore.set(request.url, { body: await response.text(), cacheControl: response.headers.get('Cache-Control') });
      },
    },
  };
  (globalThis as any).fetch = async (input: URL | string) => {
    const url = new URL(String(input));
    upstreamCalls.push(url);
    return upstream(url);
  };
};

beforeEach(installMocks);

const env = {
  IGDB_CLIENT_ID: '',
  IGDB_CLIENT_SECRET: '',
  GG_DEALS_API_KEY: 'secret-key',
  ALLOW_ORIGINLESS_REQUESTS: 'true',
  RATE_LIMITER: { limit: async () => ({ success: true }) },
};

const call = async (path: string, headers: Record<string, string> = {}) => {
  const pending: Promise<unknown>[] = [];
  const response = await worker.fetch(new Request(`https://api.example${path}`, { headers }), env, {
    waitUntil: (promise) => pending.push(promise),
  });
  await Promise.all(pending);
  return response;
};

const requestedIds = (url: URL) => url.searchParams.get('ids')!.split(',');

test('aggregate normalizer handles free, keyshop-only, missing and malformed prices', () => {
  assert.deepEqual(normalizeGgDealsAggregate(game('Free', '0', '1.00'))?.lowestCurrent, { amount: '0', source: 'retail' });
  assert.deepEqual(normalizeGgDealsAggregate(game('Keys', null, '3.50'))?.lowestCurrent, { amount: '3.50', source: 'keyshop' });
  assert.equal(normalizeGgDealsAggregate(game('None', null, null))?.lowestCurrent, null);
  assert.equal(normalizeGgDealsAggregate(game('Bad', '-1', 'x'))?.lowestCurrent, null);
  assert.equal(normalizeGgDealsAggregate({ ...game('Off site'), url: 'https://evil.example/game/' }), null);
  assert.equal(normalizeGgDealsAggregate({ ...game('No currency'), prices: { currentRetail: '1.00', currency: 'usd' } }), null);
  assert.equal(normalizeGgDealsAggregate({ title: 7 } as any), null);
});

test('steam batch route validates input before spending quota', async () => {
  for (const path of [
    '/api/prices/steam',
    '/api/prices/steam?ids=',
    '/api/prices/steam?ids=1,,2',
    '/api/prices/steam?ids=abc',
    '/api/prices/steam?ids=1&key=x',
    '/api/prices/steam?ids=1&region=xx',
    `/api/prices/steam?ids=${Array.from({ length: 51 }, (_, i) => i + 1).join(',')}`,
    '/api/prices/slug?slugs=portal-2',
  ]) {
    assert.ok([400, 404].includes((await call(path)).status), path);
  }
  assert.equal(upstreamCalls.length, 0);
});

test('steam batch dedupes, keeps caller order and omits unmatched IDs', async () => {
  upstream = () => Response.json({ success: true, data: { 20: game('B Game'), 10: game('A Game'), 30: null } });
  const response = await call('/api/prices/steam?ids=20,10,20,30&region=GB', { Origin: 'http://localhost:3000' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), 'http://localhost:3000');
  assert.deepEqual((await response.json()).map((price: any) => price.steamAppId), [20, 10]);
  assert.equal(upstreamCalls.length, 1);
  assert.equal(upstreamCalls[0].pathname, '/v1/prices/by-steam-app-id/');
  assert.deepEqual(requestedIds(upstreamCalls[0]), ['20', '10', '30']);
  assert.equal(upstreamCalls[0].searchParams.get('region'), 'gb');
});

test('steam batch and single routes share per-game records and keep old shapes', async () => {
  upstream = () => Response.json({ success: true, data: { 620: game('Portal 2'), 400: game('Portal'), 1: null } });
  const batch = await (await call('/api/prices/steam?ids=620,400,1')).json();
  assert.deepEqual(batch.map((price: any) => price.steamAppId), [620, 400]);
  assert.equal(batch[0].slug, undefined);

  // Each now comes from cache, whichever route or origin asks.
  const single = await call('/api/prices/steam/620', { Origin: 'https://void.tinyk.ing' });
  assert.equal((await single.json()).steamAppId, 620);
  assert.equal(single.headers.get('Access-Control-Allow-Origin'), 'https://void.tinyk.ing');
  assert.equal(await (await call('/api/prices/steam/1')).json(), null);
  assert.equal(upstreamCalls.length, 1);

  // Cache keys never contain the API key or client details.
  for (const key of cacheStore.keys()) assert.doesNotMatch(key, /secret-key|origin|localhost/i);
});

test('overlapping batches fetch only misses and rebuild caller order', async () => {
  upstream = (url) => Response.json({
    success: true,
    data: Object.fromEntries(requestedIds(url).map((id) => [id, game(`Game ${id}`)])),
  });
  await call('/api/prices/steam?ids=1,2');
  const response = await call('/api/prices/steam?ids=3,2,1,4');
  assert.deepEqual((await response.json()).map((price: any) => price.steamAppId), [3, 2, 1, 4]);
  assert.deepEqual(upstreamCalls.map(requestedIds), [['1', '2'], ['3', '4']]);
  assert.equal(response.headers.get('Cache-Control'), 'public, max-age=3600');
});

test('regions are cached separately', async () => {
  upstream = (url) => Response.json({ success: true, data: { [requestedIds(url)[0]]: game('Same') } });
  await call('/api/prices/steam/5?region=us');
  await call('/api/prices/steam/5?region=de');
  await call('/api/prices/steam/5?region=us');
  assert.equal(upstreamCalls.length, 2);
});

test('confirmed misses are cached briefly; omitted or malformed entries are not cached', async () => {
  upstream = () => Response.json({ success: true, data: { 1: null, 2: { title: 'Broken', url: 'nope' } } });
  const response = await call('/api/prices/steam?ids=1,2,3');
  assert.deepEqual(await response.json(), []);
  assert.equal(response.headers.get('Cache-Control'), 'public, max-age=600');
  assert.deepEqual([...cacheStore.values()].map((entry) => entry.cacheControl), ['public, max-age=600']);

  await call('/api/prices/steam?ids=1,2,3');
  assert.deepEqual(requestedIds(upstreamCalls[1]), ['2', '3']);
});

test('upstream 429 passes Retry-After through and caches nothing', async () => {
  upstream = () => new Response('{}', { status: 429, headers: { 'x-ratelimit-reset': '42' } });
  const response = await call('/api/prices/steam?ids=1,2');
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('Retry-After'), '42');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(cacheStore.size, 0);

  upstream = () => new Response('{}', { status: 429, headers: { 'Retry-After': '17' } });
  assert.equal((await call('/api/prices/steam/9')).headers.get('Retry-After'), '17');

  // A later success is fetched fresh, not served as a cached failure.
  upstream = () => Response.json({ success: true, data: { 1: game('A'), 2: game('B') } });
  assert.equal((await (await call('/api/prices/steam?ids=1,2')).json()).length, 2);
});

test('an incomplete upstream response is a 502 and caches nothing', async () => {
  upstream = () => Response.json({ success: false });
  assert.equal((await call('/api/prices/steam?ids=1,2')).status, 502);
  assert.equal(cacheStore.size, 0);
});

test('concurrent identical misses in one isolate share a single upstream batch', async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  (globalThis as any).fetch = async (input: URL) => {
    upstreamCalls.push(new URL(String(input)));
    await gate;
    return Response.json({ success: true, data: { 77: game('Shared') } });
  };
  const first = call('/api/prices/steam/77');
  const second = call('/api/prices/steam?ids=77');
  await new Promise((resolve) => setTimeout(resolve, 10));
  release();
  const [a, b] = await Promise.all([first, second]);
  assert.equal((await a.json()).steamAppId, 77);
  assert.equal((await b.json())[0].steamAppId, 77);
  assert.equal(upstreamCalls.length, 1);
});
