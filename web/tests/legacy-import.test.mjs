import assert from "node:assert/strict";
import test from "node:test";
import { legacyItems, LegacyImportError } from "../app/legacy-import.mjs";
import { emptyState, importItems, recordName } from "../shared/library.mjs";

// The same file as iOS CodecTests.testLegacyImport.
const json = `{"version":4,
 "watchlist":[{"id":1399,"title":"Game of Thrones","media_type":"tv","source":"tmdb","date_added":"2025-01-02T03:04:05.678Z","image":"/got.jpg"},
              {"id":9,"title":"Hades","media_type":"game","date_added":"2025-01-02","isPurchased":true}],
 "watched":[{"id":5,"title":"Dune","media_type":"movie","date_added":"2024-05-06T00:00:00.000Z","release_date":"2021-10-22","rating":4},
            {"id":1399,"title":"dupe","media_type":"tv","date_added":"2024-05-06T00:00:00.000Z"},
            {"id":"bad"}],
 "favorites":[{"id":5,"title":"Dune","media_type":"movie","date_added":"2024-05-06T00:00:00.000Z"}],
 "playedEpisodes":{}}`;

test("reads the old webapp's file as iOS does", () => {
  const items = legacyItems(json);
  assert.deepEqual(items.map(recordName), ["item.tmdb.tv.1399", "item.igdb.game.9", "item.tmdb.movie.5"]);
  assert.equal(items[0].list, "playlist");
  assert.equal(items[0].image, "/got.jpg");
  assert.equal(items[0].addedAt, "2025-01-02T03:04:05.678Z");
  assert.equal(items[1].addedAt, "2025-01-02T00:00:00.000Z");
  assert.equal(items[2].list, "history");
  assert.equal(items[2].isFavorite, true);
  assert.equal(items[2].rating, 4);
  assert.equal(items[2].releaseDate, "2021-10-22");
});

test("rejects other files and unknown versions", () => {
  assert.throws(() => legacyItems("{}"), LegacyImportError);
  assert.throws(() => legacyItems("not json"), LegacyImportError);
  assert.throws(() => legacyItems(`{"version":5,"watchlist":[],"watched":[]}`), /version \(5\)/);
});

test("imported items go through importItems and leave existing ones alone", () => {
  const items = legacyItems(json);
  const s = importItems(emptyState(), items);
  assert.equal(Object.keys(s.sync.dirty).length, 3);
  assert.equal(importItems(s, items), s);
});
