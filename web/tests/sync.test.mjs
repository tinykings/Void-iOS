import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { CloudKitClient } from "../shared/cloudkit.mjs";
import { toggleFavorite, toggleHistory, togglePlaylist, returnToPlaylist } from "../shared/library.mjs";
import { accountLibraryKey, createLibrary } from "../shared/store.mjs";
import { runSync } from "../shared/sync-runner.mjs";
import { applyRemoteChanges, decodeRecord, fieldsFor } from "../shared/sync.mjs";
import { fakeCloudKit } from "./fake-cloudkit.mjs";

const fixture = JSON.parse(readFileSync(new URL("../../Tests/fixtures/void-item-record.json", import.meta.url)));
const show = { source: "tmdb", mediaType: "tv", id: 1399, title: "Game of Thrones", posterPath: "/got.jpg" };
const showName = "item.tmdb.tv.1399";
const config = { container: "iCloud.com.tinykings.void", environment: "production", apiToken: "t" };

test("decodes the fixture iOS decodes, and writes the same fields back", () => {
  const item = decodeRecord(fixture);
  assert.deepEqual(item, {
    source: "tmdb", mediaType: "tv", mediaID: 1399, title: "Game of Thrones", image: "/u3bZgnGQ9T01sWNhyveQz0wH0Hl.jpg",
    releaseDate: "2011-04-17", list: "history", addedAt: "2026-11-13T22:04:05.123Z", isFavorite: true,
    rating: 5, returnedFor: "2026-11-10",
  });
  assert.deepEqual(fieldsFor(item), fixture.fields);
  assert.equal(decodeRecord({ ...fixture, fields: { ...fixture.fields, schemaVersion: { value: 2, type: "INT64" } } }), null);
  assert.equal(decodeRecord({ ...fixture, recordName: "item.tmdb.tv.1400" }), null);
  assert.equal(decodeRecord({ ...fixture, fields: { ...fixture.fields, image: { value: "javascript:x", type: "STRING" } } }).image, null);
});

function memoryStorage() {
  const map = new Map();
  return {
    async get(key) { return { [key]: map.has(key) ? structuredClone(map.get(key)) : undefined }; },
    async set(entries) { for (const [k, v] of Object.entries(entries)) map.set(k, structuredClone(v)); },
    async remove(key) { map.delete(key); },
  };
}

async function device(server, token) {
  const tokens = { value: token };
  const api = new CloudKitClient(config, { fetcher: server.fetch, getToken: async () => tokens.value, setToken: async t => { tokens.value = t; } });
  const library = createLibrary({ storage: memoryStorage() });
  const account = await api.currentUser();
  const settings = { account, container: config.container, environment: config.environment };
  await library.useAccount(settings);
  return { api, library, key: accountLibraryKey(settings), sync: options => runSync({ api, library, ...options }) };
}

test("the website never creates the zone; it waits for the iPhone app's", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_user");
  server.signIn("b", "_user");
  const web = await device(server, "b");
  await web.library.change(s => togglePlaylist(s, show));
  const first = await web.sync({ createZone: false });
  assert.equal(first.noZone, true);
  assert.equal(first.pending, 1);
  assert.equal(server.hasZone("_user"), false);
  assert.ok((await web.library.read(web.key)).sync.lastSync);

  const phone = await device(server, "a");
  await phone.library.change(s => toggleHistory(s, show));
  await phone.sync();
  const second = await web.sync({ createZone: false });
  assert.equal(second.noZone, undefined);
  assert.equal(second.pending, 0);
  const remote = server.records("_user");
  assert.equal(remote.length, 1);
  assert.equal(remote[0].fields.list.value, "playlist", "the web's pending change went up once the zone existed");
});

test("two devices converge, keeping each one's pending field", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_user");
  server.signIn("b", "_user");
  const phone = await device(server, "a");
  const web = await device(server, "b");

  await phone.library.change(s => toggleHistory(s, show));
  await phone.sync();
  await web.sync();
  assert.equal((await web.library.read(web.key)).items[showName].list, "history");

  // Offline at the same time: the phone favorites it, the web moves it back to the Playlist.
  await phone.library.change(s => toggleFavorite(s, showName));
  await web.library.change(s => togglePlaylist(s, show));
  await web.sync();
  const result = await phone.sync();
  assert.equal(result.pending, 0);
  await web.sync();
  for (const d of [phone, web]) {
    const item = (await d.library.read(d.key)).items[showName];
    assert.equal(item.list, "playlist");
    assert.equal(item.isFavorite, true);
  }
  assert.equal(server.records("_user", "VoidSync").length, 1);
});

test("a stale return yields to a newer History record for the same episode", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_user");
  server.signIn("b", "_user");
  const phone = await device(server, "a");
  const web = await device(server, "b");
  await phone.library.change(s => toggleHistory(s, show));
  await phone.sync();
  await web.sync();

  // The phone returns it, the person marks it played again there; the web, offline,
  // returns it for the same episode.
  await phone.library.change(s => returnToPlaylist(s, showName, "2026-11-15"));
  await phone.library.change(s => toggleHistory(s, show));
  await phone.library.change(s => returnToPlaylist(s, showName, "2026-11-15"));
  await phone.sync();
  await web.library.change(s => returnToPlaylist(s, showName, "2026-11-15"));
  await web.sync();
  // The phone's toggleHistory was a person's change, so its record kept returnedFor
  // from the return before it.
  const remote = server.records("_user", "VoidSync")[0];
  assert.equal(remote.fields.list.value, "history");
  assert.equal((await web.library.read(web.key)).items[showName].list, "history");
});

test("deleted records are dropped unless pending", () => {
  const state = { version: 1, items: { [showName]: decodeRecord(fixture) }, sync: { rev: 0, syncToken: null, zoneReady: true, tags: { [showName]: "x" }, dirty: {}, lastSync: null }, checks: {} };
  const next = applyRemoteChanges(state, [{ recordName: showName, deleted: true }]);
  assert.equal(next.items[showName], undefined);
  assert.equal(next.sync.tags[showName], undefined);
});
