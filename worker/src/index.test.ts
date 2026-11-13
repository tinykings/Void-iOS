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
});
