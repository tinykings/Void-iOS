// TEMPORARY: reads the old [void] webapp's library file (void-data.json from its Gist,
// versions 1–4) into items for library.mjs importItems. A port of iOS
// Void/Core/LegacyImport.swift. To remove: delete this file, its test, the import
// button in index.html and the "Import" block in app.mjs, and importLegacy in site.mjs.
import { parseRecordName, recordName } from "../shared/library.mjs";
import { cleanImage, isCalendarDate } from "../shared/sync.mjs";

export const MAX_BYTES = 2 * 1024 * 1024;
const SOURCES = ["tmdb", "igdb", "rawg", "steam"];

export class LegacyImportError extends Error {}

// The webapp wrote toISOString() times, and older versions plain dates.
function parseDate(value) {
  if (typeof value !== "string") return null;
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/.test(value)) {
    const time = Date.parse(value);
    if (Number.isFinite(time)) return new Date(time).toISOString();
  }
  const day = value.slice(0, 10);
  return isCalendarDate(day) ? `${day}T00:00:00.000Z` : null;
}

function keyOf(raw) {
  if (!raw || typeof raw !== "object" || !Number.isSafeInteger(raw.id) || raw.id <= 0) return null;
  if (!["movie", "tv", "game"].includes(raw.media_type)) return null;
  const source = raw.source ?? (raw.media_type === "game" ? "igdb" : "tmdb");
  if (!SOURCES.includes(source)) return null;
  // parseRecordName holds source and type together, as LegacyImport's MediaKey check.
  return parseRecordName(recordName({ source, mediaType: raw.media_type, mediaID: raw.id }));
}

export function legacyItems(text, now = Date.now()) {
  if (text.length > MAX_BYTES) throw new LegacyImportError("The file is larger than 2 MB.");
  let payload;
  try { payload = JSON.parse(text); } catch { payload = null; }
  if (!payload || !Number.isInteger(payload.version) || !Array.isArray(payload.watchlist) || !Array.isArray(payload.watched)) {
    throw new LegacyImportError("This isn't a [void] library file (void-data.json).");
  }
  if (payload.version < 1 || payload.version > 4) {
    throw new LegacyImportError(`This library file's version (${payload.version}) isn't supported.`);
  }
  const favorites = new Set((Array.isArray(payload.favorites) ? payload.favorites : [])
    .map(keyOf).filter(Boolean).map(recordName));
  const seen = new Set();
  const result = [];
  const add = (items, list) => {
    for (const raw of items) {
      const key = keyOf(raw);
      if (!key || typeof raw.title !== "string") continue;
      const name = recordName(key);
      const title = raw.title.trim();
      if (!title || seen.has(name)) continue;
      seen.add(name);
      const release = typeof raw.release_date === "string" ? raw.release_date.slice(0, 10) : null;
      result.push({
        ...key, title: title.slice(0, 500), image: cleanImage(raw.image),
        releaseDate: isCalendarDate(release) ? release : null,
        list, addedAt: parseDate(raw.date_added) ?? new Date(now).toISOString(),
        isFavorite: favorites.has(name),
        rating: Number.isInteger(raw.rating) && raw.rating >= 1 && raw.rating <= 5 ? raw.rating : 0,
        returnedFor: null,
      });
    }
  };
  add(payload.watchlist, "playlist");
  add(payload.watched, "history");
  return result;
}
