import assert from "node:assert/strict";
import test from "node:test";
import { createApi, fromGame, fromTMDB, trailerEmbedURL, trailers } from "../shared/api.mjs";

const fakeApi = responses => {
  const asked = [];
  const api = createApi({
    base: "https://api.test",
    fetcher: async url => {
      asked.push(url);
      const { pathname } = new URL(url);
      return { ok: true, json: async () => responses[pathname] };
    },
  });
  return { api, asked };
};

test("trailers: YouTube trailers and teasers only, at most three, safe keys", () => {
  const videos = [
    { site: "YouTube", key: "abc_DEF-123", type: "Trailer", name: "Official Trailer" },
    { site: "Vimeo", key: "vimeo1", type: "Trailer" },
    { site: "YouTube", key: "featurette", type: "Featurette" },
    { site: "YouTube", key: "bad\"><script>", type: "Trailer" },
    { site: "YouTube", key: "t2", type: "Teaser" },
    { site: "YouTube", key: "t3", type: "Trailer" },
    { site: "YouTube", key: "t4", type: "Trailer" },
  ];
  assert.deepEqual(trailers(videos), [
    { key: "abc_DEF-123", name: "Official Trailer" },
    { key: "t2", name: "Trailer" },
    { key: "t3", name: "Trailer" },
  ]);
  assert.deepEqual(trailers(undefined), []);
  assert.equal(trailerEmbedURL("t2"), "https://www.youtube-nocookie.com/embed/t2?autoplay=1&playsinline=1&rel=0");
});

test("fromTMDB reads appended videos and seasons, specials only when alone", () => {
  const show = fromTMDB({
    id: 1399, name: "Game of Thrones",
    videos: { results: [{ site: "YouTube", key: "k1", type: "Trailer", name: "S1" }] },
    seasons: [
      { season_number: 0, name: "Specials", episode_count: 3 },
      { season_number: 1, name: "Season 1", episode_count: 10, air_date: "2011-04-17" },
    ],
  }, "tv");
  assert.deepEqual(show.videos, [{ key: "k1", name: "S1" }]);
  assert.deepEqual(show.seasons, [{ number: 1, name: "Season 1", episodeCount: 10, airDate: "2011-04-17" }]);
  const onlySpecials = fromTMDB({ id: 1, name: "x", seasons: [{ season_number: 0, name: "Specials" }] }, "tv");
  assert.equal(onlySpecials.seasons.length, 1);
  assert.deepEqual(fromTMDB({ id: 2, title: "Movie" }, "movie").seasons, []);
});

test("fromGame takes the Worker's videos", () => {
  const game = fromGame({ id: 1942, name: "The Witcher 3", videos: [{ key: "w3", name: "Launch", site: "YouTube", type: "Trailer" }] });
  assert.deepEqual(game.videos, [{ key: "w3", name: "Launch" }]);
});

test("details asks for videos with the same parameters as iOS", async () => {
  const { api, asked } = fakeApi({ "/api/tmdb/movie/5": { id: 5, title: "Five" } });
  await api.details({ source: "tmdb", mediaType: "movie", id: 5 });
  assert.equal(asked[0], "https://api.test/api/tmdb/movie/5?append_to_response=videos%2Cimages&include_image_language=en%2Cnull");
});

test("credits and season", async () => {
  const { api } = fakeApi({
    "/api/tmdb/tv/7/credits": { cast: [{ id: 1, name: "A", character: "Hero", profile_path: "/a.jpg" }, { id: 2 }, { id: 3, name: "C" }] },
    "/api/tmdb/tv/7/season/2": { episodes: [{ id: 10, episode_number: 1, name: "Pilot", air_date: "2020-01-01", still_path: "/s.jpg", overview: "Begins." }, { id: 11 }] },
  });
  assert.deepEqual(await api.credits("tv", 7), [
    { id: 1, name: "A", character: "Hero", profilePath: "/a.jpg" },
    { id: 3, name: "C", character: null, profilePath: null },
  ]);
  assert.deepEqual(await api.season(7, 2), [
    { id: 10, name: "Pilot", overview: "Begins.", airDate: "2020-01-01", episodeNumber: 1, stillPath: "/s.jpg" },
  ]);
});
