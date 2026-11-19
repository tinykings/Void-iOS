import assert from 'node:assert/strict';
import test from 'node:test';
import { getSteamAppId, normalizeGgDealsGamePrice } from './index';

test('getSteamAppId reads IGDB Steam external ID and website fallback', () => {
  assert.equal(getSteamAppId({ id: 1, external_games: [{ category: 1, uid: '1245620' }] }), 1245620);
  assert.equal(getSteamAppId({ id: 2, websites: [{ url: 'https://store.steampowered.com/app/620/Portal_2/' }] }), 620);
  assert.equal(getSteamAppId({ id: 3, websites: [{ url: 'https://example.com/app/620' }] }), undefined);
});

test('normalizeGgDealsGamePrice chooses lowest current price and labels keyshops', () => {
  const price = normalizeGgDealsGamePrice(620, {
    title: 'Portal 2',
    url: 'https://gg.deals/game/portal-2/',
    prices: {
      currentRetail: '9.99',
      currentKeyshops: '4.20',
      historicalRetail: '0.99',
      historicalKeyshops: '1.25',
      currency: 'USD',
    },
  });

  assert.deepEqual(price?.lowestCurrent, { amount: '4.20', source: 'keyshop' });
  assert.equal(price?.currency, 'USD');
});

test('normalizeGgDealsGamePrice handles missing games and prefers retail on ties', () => {
  assert.equal(normalizeGgDealsGamePrice(1, null), null);
  const price = normalizeGgDealsGamePrice(1, {
    title: 'Game',
    url: 'https://gg.deals/game/game/',
    prices: { currentRetail: '5.00', currentKeyshops: '5.00', currency: 'USD' },
  });
  assert.deepEqual(price?.lowestCurrent, { amount: '5.00', source: 'retail' });
});

test('tmdbProxyPath forwards only known endpoints and parameters', async () => {
  const { tmdbProxyPath } = await import('./index');
  const params = (value: string) => new URLSearchParams(value);
  assert.equal(tmdbProxyPath('/api/tmdb/search/multi', params('query=dune')), 'https://api.themoviedb.org/3/search/multi?query=dune');
  assert.equal(tmdbProxyPath('/api/tmdb/tv/1399', params('append_to_response=videos,images&include_image_language=en,null')),
    'https://api.themoviedb.org/3/tv/1399?append_to_response=videos%2Cimages&include_image_language=en%2Cnull');
  assert.equal(tmdbProxyPath('/api/tmdb/tv/1399/season/2', params('')), 'https://api.themoviedb.org/3/tv/1399/season/2');
  assert.equal(tmdbProxyPath('/api/tmdb/movie/5/watch/providers', params('')), 'https://api.themoviedb.org/3/movie/5/watch/providers');
  assert.deepEqual(tmdbProxyPath('/api/tmdb/account/1', params('')), { error: 'Unsupported TMDB endpoint' });
  assert.deepEqual(tmdbProxyPath('/api/tmdb/search/multi', params('query=a&api_key=x')), { error: 'Unsupported query parameter' });
  assert.deepEqual(tmdbProxyPath('/api/tmdb/tv/1', params('append_to_response=account_states')), { error: 'Unsupported append_to_response' });
  assert.deepEqual(tmdbProxyPath('/api/tmdb/search/multi', params('query=%20')), { error: 'Search query is required' });
  assert.deepEqual(tmdbProxyPath('/api/tmdb/tv/1/../../account', params('')), { error: 'Unsupported TMDB endpoint' });
  assert.equal(tmdbProxyPath('/api/tmdb/discover/tv', params('first_air_date.gte=2026-11-18&first_air_date.lte=2026-12-18&sort_by=popularity.desc')),
    'https://api.themoviedb.org/3/discover/tv?first_air_date.gte=2026-11-18&first_air_date.lte=2026-12-18&sort_by=popularity.desc');
  assert.equal(typeof tmdbProxyPath('/api/tmdb/discover/movie', params('primary_release_date.gte=2026-11-18&primary_release_date.lte=2026-12-18')), 'string');
  assert.deepEqual(tmdbProxyPath('/api/tmdb/discover/movie', params('sort_by=revenue.desc')), { error: 'Unsupported sort' });
  assert.deepEqual(tmdbProxyPath('/api/tmdb/discover/tv', params('first_air_date.gte=soon')), { error: 'Invalid date' });
  assert.deepEqual(tmdbProxyPath('/api/tmdb/discover/tv', params('with_genres=18')), { error: 'Unsupported query parameter' });
});

test('blendTrending rewards games that rank well across several signals', async () => {
  const { blendTrending } = await import('./index');
  const signals = [
    { name: 'visits', result: [{ game_id: 1 }, { game_id: 2 }, { game_id: 3 }] },
    { name: 'want_to_play', result: [{ game_id: 2 }, { game_id: 4 }, { game_id: 2 }, { game_id: 1 }] },
    { name: 'top_sellers', result: [{ game_id: 3 }, { game_id: -1 }, {}] },
    { name: 'empty' },
  ];
  // 1 and 3 tie (lower ID first); 4 is in only one signal, so it's left out.
  assert.deepEqual(blendTrending(signals).map(([id]) => id), [2, 1, 3]);
  assert.deepEqual(blendTrending(signals, 20, 1).map(([id]) => id), [2, 1, 3, 4]);
  assert.deepEqual(blendTrending(signals, 1).map(([id]) => id), [2]);
});

test('rankTrending favors recent games and drops editions and duplicates', async () => {
  const { rankTrending, recencyWeight } = await import('./index');
  const year = 365 * 24 * 60 * 60;
  const now = 10 * year;
  assert.equal(recencyWeight(undefined, now), 1);
  assert.equal(recencyWeight(now + year, now), 1);
  assert.equal(recencyWeight(now - 2 * year, now), 0.5);
  const games = [
    { id: 1, name: 'Minecraft', first_release_date: now - 5 * year },
    { id: 2, name: 'Minecraft: Java Edition', first_release_date: now - 5 * year },
    { id: 3, name: 'New Game', first_release_date: now - year / 2 },
    { id: 4, name: 'Deluxe', version_parent: 3 },
    { id: 5, name: 'DLC', parent_game: 3 },
    { id: 6, name: 'new game' },
    { id: 7, name: 'Expansion', game_type: 1 },
    { id: 8, name: 'Adult', themes: [{ id: 42 }] },
  ];
  const scores: [number, number][] = [[2, 0.2], [1, 0.1], [4, 0.09], [5, 0.08], [3, 0.05], [6, 0.01], [7, 1], [8, 1]];
  assert.deepEqual(rankTrending(games, scores, now).map((game) => game.id), [3, 1]);
});

test('extractHltbSearchPath finds the full multi-segment search path', async () => {
  const { extractHltbSearchPath } = await import('./index');
  // Excerpts from howlongtobeat.com's scripts, November 2026.
  const init = 'er=async()=>{try{let e=await fetch(`/api/search/site/init?t=${Date.now()}`);if(e.ok){let t=await e.json()';
  const search = 'r=await fetch("/api/search/site",{method:"POST",headers:{"Content-Type":"application/json","x-auth-token":t},body:JSON.stringify(a)})';
  const other = 'fetch("/api/error",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({message:e})})';
  assert.equal(extractHltbSearchPath(other + init + search), '/api/search/site');
  assert.equal(extractHltbSearchPath(other + search), '/api/search/site');
  assert.equal(extractHltbSearchPath(other), null);
  assert.equal(extractHltbSearchPath("fetch('/api/s/init?t=1')"), '/api/s');
});
