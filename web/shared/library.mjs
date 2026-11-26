// The library and its local intentions, matching iOS Void/Core/SyncLibrary.swift and
// docs/sync-schema.md. Pure functions: each takes a state and returns a new one.
//
// state = {
//   version: 1,
//   items: { [recordName]: item },          // tombstones (list "none") included
//   sync: { rev, syncToken, zoneReady, tags: { [recordName]: changeTag },
//           dirty: { [recordName]: { rev, mode: "set" | "import", fields: [...], returnFor? } },
//           lastSync },
//   checks: { [recordName]: { checkedAt, status } },   // this browser's return checks
// }
// item = { source, mediaType, mediaID, title, image, releaseDate, list, addedAt,
//          isFavorite, rating, returnedFor, pinnedAt }

export const FIELD_GROUPS = ["list", "favorite", "rating", "pin"];
export const MEDIA_TYPES = ["movie", "tv", "game"];
export const RETURN_WINDOW_DAYS = 7;
export const RETURN_CHECK_INTERVAL = 24 * 60 * 60 * 1000;

export function emptyState() {
  return { version: 1, items: {}, sync: emptySync(), checks: {} };
}

export function emptySync() {
  return { rev: 0, syncToken: null, zoneReady: false, tags: {}, dirty: {}, lastSync: null };
}

const defaultSource = mediaType => (mediaType === "game" ? "igdb" : "tmdb");

export function recordName({ source, mediaType, mediaID }) {
  return `item.${source}.${mediaType}.${mediaID}`;
}

// { source, mediaType, mediaID } from a record name, or null.
export function parseRecordName(name) {
  const match = /^item\.(tmdb|igdb|rawg|steam)\.(movie|tv|game)\.([1-9]\d{0,15})$/.exec(name ?? "");
  if (!match) return null;
  const [, source, mediaType, id] = match;
  if ((mediaType === "game") !== (source !== "tmdb")) return null;
  const mediaID = Number(id);
  return Number.isSafeInteger(mediaID) ? { source, mediaType, mediaID } : null;
}

export const isoNow = (now = Date.now()) => new Date(now).toISOString();

// media = { source?, mediaType, id, title, posterPath?, releaseDate? } (shared/api.mjs)
function itemFromMedia(media, list, now) {
  return {
    source: media.source ?? defaultSource(media.mediaType), mediaType: media.mediaType, mediaID: media.id,
    title: media.title, image: media.posterPath ?? null, releaseDate: media.releaseDate ?? null,
    list, addedAt: isoNow(now), isFavorite: false, rating: 0, returnedFor: null, pinnedAt: null,
  };
}

// Pinned since it entered its current list. Moving lists or being removed sets addedAt
// later than the pin, so the pin lapses without its own write, and a client that
// doesn't know about pins can't leave a stale one behind.
export function isPinned(item) {
  if (!item || item.list !== "playlist" || !item.pinnedAt) return false;
  return Date.parse(item.pinnedAt) >= Date.parse(item.addedAt);
}

function refreshed(item, media) {
  return {
    ...item, title: media.title || item.title,
    image: media.posterPath ?? item.image, releaseDate: media.releaseDate ?? item.releaseDate,
  };
}

function write(state, item, fields, returnFor = null) {
  const name = recordName(item);
  const rev = state.sync.rev + 1;
  const previous = state.sync.dirty[name];
  const mark = previous?.mode === "set"
    ? { ...previous, rev, fields: [...new Set([...previous.fields, ...fields])] }
    : { rev, mode: "set", fields: [...fields] };
  if (fields.includes("list")) {
    if (returnFor) mark.returnFor = returnFor; else delete mark.returnFor;
  }
  return {
    ...state,
    items: { ...state.items, [name]: item },
    sync: { ...state.sync, rev, dirty: { ...state.sync.dirty, [name]: mark } },
  };
}

function remove(state, item, now) {
  return write(state, { ...item, list: "none", addedAt: isoNow(now), isFavorite: false, rating: 0, pinnedAt: null }, FIELD_GROUPS);
}

export function itemFor(state, media) {
  return state.items[recordName({ source: media.source ?? defaultSource(media.mediaType), mediaType: media.mediaType, mediaID: media.id })] ?? null;
}

// Playlist button: adds to the Playlist (out of History), or removes from it.
export function togglePlaylist(state, media, now = Date.now()) {
  const existing = itemFor(state, media);
  if (existing?.list === "playlist") return remove(state, existing, now);
  const next = refreshed(existing ?? itemFromMedia(media, "playlist", now), media);
  return write(state, { ...next, list: "playlist", addedAt: isoNow(now) }, ["list"]);
}

// Played button: moves to History, or out of History when it's already there.
export function toggleHistory(state, media, now = Date.now()) {
  const existing = itemFor(state, media);
  if (existing?.list === "history") return remove(state, existing, now);
  const next = refreshed(existing ?? itemFromMedia(media, "history", now), media);
  return write(state, { ...next, list: "history", addedAt: isoNow(now) }, ["list"]);
}

// Favorites belong to History; on the Playlist a favorite can only be cleared.
export function toggleFavorite(state, name) {
  const item = state.items[name];
  if (!item) return state;
  if (item.list === "history") return write(state, { ...item, isFavorite: !item.isFavorite }, ["favorite"]);
  if (item.list === "playlist" && item.isFavorite) return write(state, { ...item, isFavorite: false }, ["favorite"]);
  return state;
}

// Pins a Playlist item to the top, or unpins it.
export function togglePin(state, name, now = Date.now()) {
  const item = state.items[name];
  if (!item || item.list !== "playlist") return state;
  return write(state, { ...item, pinnedAt: isPinned(item) ? null : isoNow(now) }, ["pin"]);
}

// A History show with an episode airing soon goes back to the Playlist, once per episode.
export function returnToPlaylist(state, name, airDate, now = Date.now()) {
  const item = state.items[name];
  if (!item || item.mediaType !== "tv" || item.list !== "history" || item.returnedFor === airDate) return state;
  return write(state, { ...item, list: "playlist", addedAt: isoNow(now), returnedFor: airDate }, ["list"], airDate);
}

// Items the library has no record of at all; a remote copy found later wins.
export function importItems(state, items) {
  const fresh = items.filter(item => item.list !== "none" && !state.items[recordName(item)]);
  if (!fresh.length) return state;
  const rev = state.sync.rev + 1;
  const next = { ...state, items: { ...state.items }, sync: { ...state.sync, rev, dirty: { ...state.sync.dirty } } };
  for (const item of fresh) {
    next.items[recordName(item)] = item;
    next.sync.dirty[recordName(item)] = { rev, mode: "import", fields: [...FIELD_GROUPS] };
  }
  return next;
}

function copyGroup(target, source, group) {
  if (group === "list") Object.assign(target, { list: source.list, addedAt: source.addedAt, returnedFor: source.returnedFor });
  if (group === "favorite") target.isFavorite = source.isFavorite;
  if (group === "rating") target.rating = source.rating;
  if (group === "pin") target.pinnedAt = source.pinnedAt ?? null;
}

// A remote record (already decoded) into a cloned state: pending field groups keep
// their local values; an import yields; a pending return yields when the remote left
// History or was already returned for that episode.
export function applyRemoteItem(next, name, remote) {
  const mark = next.sync.dirty[name];
  if (!mark || mark.mode === "import") {
    if (mark) delete next.sync.dirty[name];
    next.items[name] = remote;
    return;
  }
  let fields = mark.fields;
  if (mark.returnFor && (remote.list !== "history" || remote.returnedFor === mark.returnFor)) {
    fields = fields.filter(field => field !== "list");
  }
  const merged = { ...remote };
  const local = next.items[name];
  if (local) for (const group of fields) copyGroup(merged, local, group);
  next.items[name] = merged;
  if (fields.length === 0) delete next.sync.dirty[name];
  else next.sync.dirty[name] = { rev: mark.rev, mode: "set", fields, ...(fields.includes("list") && mark.returnFor ? { returnFor: mark.returnFor } : {}) };
}

// --- Lists ---------------------------------------------------------------------

export function localDay(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value ?? "").slice(0, 10));
  if (!match) return null;
  const [y, m, d] = match.slice(1).map(Number);
  const date = new Date(y, m - 1, d);
  return date.getFullYear() === y && date.getMonth() === m - 1 && date.getDate() === d ? date : null;
}

export function isInLocalDayWindow(value, now, windowDays) {
  const day = localDay(value);
  if (!day) return false;
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  const end = new Date(start);
  end.setDate(start.getDate() + windowDays);
  return day >= start && day <= end;
}

export function needsReturnCheck(check, now) {
  if (check?.status === "Ended" || check?.status === "Canceled") return false;
  return !check?.checkedAt || now - check.checkedAt > RETURN_CHECK_INTERVAL;
}

// Shown items of a list, filtered by type, sorted as on iOS: the Playlist puts shows with
// an episode within 30 days (or aired in the last 3) and releases within 30 days first
// (soonest first), then newest added; History
// is newest first. Pinned items go before all of that, the most recently pinned first.
// `details(name)` gives cached { nextAirDate } when known.
export function listItems(state, list, options = {}) {
  const sorted = sortedListItems(state, list, options);
  const pinned = sorted.filter(entry => isPinned(entry.item)).sort((a, b) => b.item.pinnedAt.localeCompare(a.item.pinnedAt));
  return [...pinned, ...sorted.filter(entry => !isPinned(entry.item))];
}

function sortedListItems(state, list, { type = null, favoritesOnly = false, enabled = MEDIA_TYPES, details = () => null, now = Date.now() } = {}) {
  const items = Object.entries(state.items)
    .filter(([, item]) => item.list === list && enabled.includes(item.mediaType) && (!type || item.mediaType === type) && (!favoritesOnly || item.isFavorite))
    .map(([name, item]) => ({ name, item }));
  if (list !== "playlist") return items.sort((a, b) => b.item.addedAt.localeCompare(a.item.addedAt));
  const today = new Date(now);
  today.setHours(0, 0, 0, 0);
  const upcoming = [], rest = [];
  for (const entry of items) {
    const next = entry.item.mediaType === "tv" ? details(entry.name)?.nextAirDate ?? null : null;
    const value = next ?? entry.item.releaseDate;
    const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value ?? "");
    const date = match ? Date.UTC(+match[1], +match[2] - 1, +match[3]) : null;
    if (date !== null) {
      const diff = Math.ceil((date - today.getTime()) / 86400000);
      if ((entry.item.mediaType === "tv" && next && diff >= -3 && diff <= 30) || (entry.item.mediaType !== "tv" && Math.abs(diff) <= 30)) {
        upcoming.push({ ...entry, date });
        continue;
      }
    }
    rest.push(entry);
  }
  upcoming.sort((a, b) => a.date - b.date);
  rest.sort((a, b) => b.item.addedAt.localeCompare(a.item.addedAt));
  return [...upcoming, ...rest];
}

export function pendingCount(state) {
  return Object.keys(state.sync?.dirty ?? {}).length;
}
