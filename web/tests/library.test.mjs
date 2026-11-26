import assert from "node:assert/strict";
import test from "node:test";
import { applyRemoteItem, emptyState, importItems, isInLocalDayWindow, isPinned, listItems, parseRecordName, recordName, returnToPlaylist, toggleFavorite, toggleHistory, togglePin, togglePlaylist } from "../shared/library.mjs";

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
  assert.deepEqual(s.sync.dirty[showName].fields.sort(), ["favorite", "list", "pin", "rating"]);
});

test("favorites on the Playlist can only be cleared", () => {
  const s = togglePlaylist(emptyState(), show, T);
  assert.equal(toggleFavorite(s, showName), s);
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
  const item = { source: "tmdb", mediaType: "tv", mediaID: 1399, title: "x", image: null, releaseDate: null, list: "history", addedAt: new Date(T).toISOString(), isFavorite: false, rating: 0, returnedFor: null };
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

test("the Playlist puts shows airing within 30 days first, not ones far off", () => {
  const far = { source: "tmdb", mediaType: "tv", id: 1, title: "Far", posterPath: null };
  const soon = { source: "tmdb", mediaType: "tv", id: 2, title: "Soon", posterPath: null };
  let s = togglePlaylist(emptyState(), soon, T);
  s = togglePlaylist(s, far, T + 1000);
  const day = offset => new Date(T + offset * 86400000).toISOString().slice(0, 10);
  const nextAirDate = { "item.tmdb.tv.1": day(238), "item.tmdb.tv.2": day(5) };
  const names = listItems(s, "playlist", { details: name => ({ nextAirDate: nextAirDate[name] }), now: T }).map(entry => entry.name);
  assert.deepEqual(names, ["item.tmdb.tv.2", "item.tmdb.tv.1"]);
});

test("a pin belongs to the list it was pinned in, as on iOS", () => {
  let state = togglePin(emptyState(), showName, T);
  assert.equal(state.items[showName], undefined, "nothing to pin outside the library");

  state = togglePlaylist(state, show, T);
  state = togglePin(state, showName, T + 1000);
  assert.equal(isPinned(state.items[showName]), true);
  assert.deepEqual(state.sync.dirty[showName].fields, ["list", "pin"]);

  // Moving to History lapses the pin without writing it.
  state = toggleHistory(state, show, T + 2000);
  assert.equal(isPinned(state.items[showName]), false);
  assert.ok(state.items[showName].pinnedAt);

  assert.equal(togglePin(state, showName, T + 3000), state);
  assert.equal(isPinned({ ...state.items[showName], pinnedAt: new Date(T + 4000).toISOString() }), false);

  // Removing clears it, and a removed item can't be pinned.
  state = togglePin(state, showName, T + 5000);
  state = toggleHistory(state, show, T + 6000);
  assert.equal(state.items[showName].pinnedAt, null);
  assert.equal(togglePin(state, showName, T + 7000), state);

  // A return lapses a History pin too.
  state = toggleHistory(state, show, T + 8000);
  state = togglePin(state, showName, T + 9000);
  state = returnToPlaylist(state, showName, "2027-01-01", T + 10000);
  assert.equal(isPinned(state.items[showName]), false);
});

test("pinned items come first, most recently pinned on top, and a pending pin survives a newer remote", () => {
  let state = emptyState();
  state = togglePlaylist(state, show, T);
  state = togglePlaylist(state, game, T + 1000);
  const other = { source: "tmdb", mediaType: "movie", id: 5, title: "Five" };
  state = togglePlaylist(state, other, T + 2000);
  assert.deepEqual(listItems(state, "playlist", { now: T }).map(e => e.item.mediaID), [5, 1942, 1399]);
  state = togglePin(state, showName, T + 3000);
  state = togglePin(state, gameName, T + 4000);
  assert.deepEqual(listItems(state, "playlist", { now: T }).map(e => e.item.mediaID), [1942, 1399, 5]);

  const next = structuredClone(state);
  applyRemoteItem(next, showName, { ...state.items[showName], pinnedAt: null, rating: 4 });
  assert.equal(isPinned(next.items[showName]), true);
  assert.equal(next.items[showName].rating, 4);
});
