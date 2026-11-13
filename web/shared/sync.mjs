// CloudKit wire format for VoidItem records, merging remote changes, and planning
// conditional writes (docs/sync-schema.md). Pure functions over the library state;
// shared/sync-runner.mjs makes the requests. iOS implements the same in
// Void/Core/SyncCodec.swift and Void/Core/SyncLibrary.swift.
import { applyRemoteItem, parseRecordName } from "./library.mjs";

export const SCHEMA_VERSION = 1;
export const RECORD_TYPE = "VoidItem";

const str = value => ({ value, type: "STRING" });
const int = value => ({ value, type: "INT64" });
const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;

export function isCalendarDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value ?? "");
  if (!match) return false;
  const [y, m, d] = match.slice(1).map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
}

// A TMDB path or an http(s) URL; anything else is dropped.
export function cleanImage(value) {
  if (typeof value !== "string" || !value || value.length > 1000) return null;
  if (/^\/[A-Za-z0-9._-]+$/.test(value)) return value;
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) && url.hostname ? value : null;
  } catch { return null; }
}

export function fieldsFor(item) {
  return {
    source: str(item.source), mediaType: str(item.mediaType), mediaID: int(item.mediaID),
    title: str(item.title), image: str(item.image ?? ""), releaseDate: str(item.releaseDate ?? ""),
    list: str(item.list), addedAt: str(item.addedAt),
    isFavorite: int(item.isFavorite ? 1 : 0),
    rating: int(item.rating ?? 0), returnedFor: str(item.returnedFor ?? ""),
    schemaVersion: int(SCHEMA_VERSION),
  };
}

const field = (record, name) => record.fields?.[name]?.value;

// A remote record as an item; null when it's not one [void] understands (including a
// newer schemaVersion, which is left untouched rather than misread).
export function decodeRecord(record) {
  if (!record || record.deleted || record.recordType !== RECORD_TYPE) return null;
  if (!(field(record, "schemaVersion") <= SCHEMA_VERSION)) return null;
  const key = parseRecordName(record.recordName);
  if (!key) return null;
  if (field(record, "source") !== key.source || field(record, "mediaType") !== key.mediaType || field(record, "mediaID") !== key.mediaID) return null;
  const title = typeof field(record, "title") === "string" ? field(record, "title").trim() : "";
  const list = field(record, "list");
  const addedAt = field(record, "addedAt");
  if (!title || title.length > 500 || !["playlist", "history", "none"].includes(list) || !ISO_TIME.test(addedAt ?? "")) return null;
  const releaseDate = field(record, "releaseDate");
  const returnedFor = field(record, "returnedFor");
  const rating = field(record, "rating");
  return {
    ...key, title, image: cleanImage(field(record, "image")),
    releaseDate: isCalendarDate(releaseDate) ? releaseDate : null,
    list, addedAt: new Date(addedAt).toISOString(),
    isFavorite: field(record, "isFavorite") === 1,
    rating: Number.isInteger(rating) && rating >= 0 && rating <= 5 ? rating : 0,
    returnedFor: isCalendarDate(returnedFor) ? returnedFor : null,
  };
}

// Applies one page of records/changes.
export function applyRemoteChanges(state, records) {
  const next = structuredClone(state);
  for (const record of records) {
    const name = record?.recordName;
    if (typeof name !== "string" || !parseRecordName(name)) continue;
    if (record.deleted) {
      // [void] never deletes; another client did. Forget the revision, and drop a
      // clean local copy.
      delete next.sync.tags[name];
      if (!next.sync.dirty[name]) delete next.items[name];
      continue;
    }
    if (typeof record.recordChangeTag === "string") next.sync.tags[name] = record.recordChangeTag;
    const item = decodeRecord(record);
    if (item) applyRemoteItem(next, name, item);
  }
  return next;
}

// The conditional writes for every pending intention: update when the record's
// revision is known, otherwise create (which fails with EXISTS if another client
// created it first).
export function planPush(state) {
  const { dirty, tags } = state.sync;
  return Object.entries(dirty)
    .filter(([name]) => state.items[name])
    .sort(([a], [b]) => (a < b ? -1 : 1))
    .map(([name, mark]) => ({
      name, rev: mark.rev,
      operation: {
        operationType: tags[name] ? "update" : "create",
        record: { recordName: name, recordType: RECORD_TYPE, fields: fieldsFor(state.items[name]), ...(tags[name] ? { recordChangeTag: tags[name] } : {}) },
      },
    }));
}

// Applies the results of a push. Returns { state, retry, failed }: retry is true when a
// conflict means remote changes must be pulled before trying again; failed counts items
// refused for another reason, which stay pending.
export function applyPushResults(state, plan, results) {
  const next = structuredClone(state);
  const { sync } = next;
  let retry = false, failed = 0;
  plan.forEach((item, i) => {
    const result = results[i] ?? {};
    if (!result.serverErrorCode && result.recordName === item.name && typeof result.recordChangeTag === "string") {
      sync.tags[item.name] = result.recordChangeTag;
      // Changed again while this push was in flight: keep it pending.
      if (sync.dirty[item.name]?.rev === item.rev) delete sync.dirty[item.name];
    } else if (["CONFLICT", "EXISTS"].includes(result.serverErrorCode)) {
      // Another client wrote first. An import yields to it; anything else is
      // reapplied once the next pull brings the newer revision.
      if (sync.dirty[item.name]?.mode === "import") delete sync.dirty[item.name];
      retry = true;
    } else failed++;
  });
  return { state: next, retry, failed };
}
