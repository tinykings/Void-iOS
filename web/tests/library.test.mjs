import assert from "node:assert/strict";
import test from "node:test";
import { emptyState, importItems, isInLocalDayWindow, listItems, parseRecordName, recordName, returnToPlaylist, toggleFavorite, toggleHistory, togglePlaylist, togglePurchased } from "../shared/library.mjs";

const show = { source: "tmdb", mediaType: "tv", id: 1399, title: "Game of Thrones", posterPath: "/got.jpg", releaseDate: "2011-04-17" };
const game = { source: "igdb", mediaType: "game", id: 1942, title: "The Witcher 3", posterPath: "https://images.igdb.com/w3.jpg" };
const showName = "item.tmdb.tv.1399";
const gameName = "item.igdb.game.1942";
const T = Date.UTC(2026, 10, 13, 12);

test("record names", () => {
  assert.equal(recordName({ source: "tmdb", mediaType: "tv", mediaID: 1399 }), showName);
  assert.deepEqual(parseRecordName(gameName), { source: "igdb", mediaType: "game", mediaID: 1942 });
  for (const bad of ["item.tmdb.game.1", "item.igdb.movie.1", "item.tmdb.tv.01", "item.tmdb.tv", "saved.x"]) assert.equal(parseRecordName(bad), null, bad);
});

test("playlist and history toggle like the webapp, removals are tombstones", () => {
  let s = togglePlaylist(emptyState(), show, T);
  assert.equal(s.items[showName].list, "playlist");
  assert.deepEqual(s.sync.dirty[showName].fields, ["list"]);
  s = toggleHistory(s, show, T);
  s = toggleFavorite(s, showName);
  assert.equal(s.items[showName].isFavorite, true);
  s = toggleHistory(s, show, T);
  assert.equal(s.items[showName].list, "none");
  assert.equal(s.items[showName].isFavorite, false);
  assert.deepEqual(s.sync.dirty[showName].fields.sort(), ["favorite", "list", "purchased", "rating"]);
});

test("favorites on the Playlist can only be cleared; games from History are purchased", () => {
  let s = togglePlaylist(emptyState(), show, T);
  assert.equal(toggleFavorite(s, showName), s);
  s = toggleHistory(emptyState(), game, T);
  s = togglePlaylist(s, game, T);
  assert.equal(s.items[gameName].isPurchased, true);
  s = togglePurchased(s, gameName);
  assert.equal(s.items[gameName].isPurchased, false);
});

test("returns once per episode", () => {
  let s = toggleHistory(emptyState(), show, T);
  s = returnToPlaylist(s, showName, "2026-11-15", T);
  assert.equal(s.items[showName].list, "playlist");
  assert.equal(s.sync.dirty[showName].returnFor, "2026-11-15");
  s = toggleHistory(s, show, T);
  assert.equal(s.sync.dirty[showName].returnFor, undefined, "a person's change cancels the pending return");
  assert.equal(returnToPlaylist(s, showName, "2026-11-15", T), s);
});

test("imports only fill gaps", () => {
  const item = { source: "tmdb", mediaType: "tv", mediaID: 1399, title: "x", image: null, releaseDate: null, list: "history", addedAt: new Date(T).toISOString(), isFavorite: false, isPurchased: false, rating: 0, returnedFor: null };
  let s = importItems(emptyState(), [item]);
  assert.equal(s.sync.dirty[showName].mode, "import");
  s = togglePlaylist(s, show, T);
  assert.equal(importItems(s, [item]), s);
});

test("local day window and playlist order", () => {
  const now = new Date(2026, 10, 13, 23).getTime();
  assert.equal(isInLocalDayWindow("2026-11-13", now, 7), true);
  assert.equal(isInLocalDayWindow("2026-11-20", now, 7), true);
  assert.equal(isInLocalDayWindow("2026-11-21", now, 7), false);
  assert.equal(isInLocalDayWindow("2026-11-12", now, 7), false);

  let s = emptyState();
  s = togglePlaylist(s, { source: "tmdb", mediaType: "movie", id: 1, title: "Old", releaseDate: "1999-01-01" }, now - 1000);
  s = togglePlaylist(s, { source: "tmdb", mediaType: "movie", id: 2, title: "Newer add", releaseDate: "1990-01-01" }, now);
  s = togglePlaylist(s, { source: "igdb", mediaType: "game", id: 3, title: "Soon", releaseDate: "2026-11-15" }, now - 5000);
  s = togglePlaylist(s, show, now - 9000);
  const order = listItems(s, "playlist", { now, details: name => (name === showName ? { nextAirDate: "2026-11-18" } : null) }).map(e => e.item.title);
  assert.deepEqual(order, ["Soon", "Game of Thrones", "Newer add", "Old"]);
  assert.deepEqual(listItems(s, "playlist", { now, type: "game" }).map(e => e.item.title), ["Soon"]);
});
