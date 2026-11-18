# [void] CloudKit sync schema (v1)

Status: in use by iOS (`Void/Core/SyncLibrary.swift`, `Void/Core/SyncCodec.swift`,
`Void/App/CloudSync.swift`) and the website (`web/shared/sync.mjs`). Every client must
read and write exactly this format. The design follows Royal's sync
(tinykings/Royal-iOS `docs/sync-schema.md`), with conflict handling per field.

Container: **`iCloud.com.tinykings.void`**. For Production, the record type below
must be created in Development (running a Debug build creates it) and deployed to
Production in CloudKit Console. Production never creates record types.

Console field types: every field is String except `mediaID`, `isFavorite`, `rating`
and `schemaVersion`, which are Int(64). No indexes are required.

## Zone

Private database, custom zone **`VoidSync`**, so clients can fetch incremental changes
with a sync token (`records/changes` on the web, `recordZoneChanges` on iOS). Only
iOS creates the zone, when it's missing; if it disappears (the user deleted iCloud
data), iOS recreates it and pushes its pending intentions again. The website never
creates it: Void on the web is only for people using Void for iPhone. With no zone it
pushes nothing, keeps its pending intentions, and shows an empty iCloud as "start with
Void on iPhone".

Times are ISO 8601 UTC strings with milliseconds (`2026-11-13T22:04:05.123Z`).
Calendar dates (`releaseDate`, `returnedFor`) are `YYYY-MM-DD`. Do not copy Swift
`JSONEncoder`'s default `Date` encoding into these fields.

Every record has `schemaVersion` (INT64, currently `1`). A client ignores records with
a higher version rather than misreading or overwriting them.

## `VoidItem`: one per movie, show or game

| Field | Type | |
|---|---|---|
| recordName | | `item.<source>.<mediaType>.<mediaID>`, e.g. `item.tmdb.tv.1399`, `item.igdb.game.1942` |
| `source` | STRING | `tmdb` (movies and shows), `igdb`, `steam` or `rawg` (games; the last two only from older libraries) |
| `mediaType` | STRING | `movie`, `tv` or `game` |
| `mediaID` | INT64 | The id at that source |
| `title` | STRING | Display title, at most 500 characters |
| `image` | STRING | Poster: a TMDB path (`/abc.jpg`) or an https URL (IGDB). Empty when none |
| `releaseDate` | STRING | `YYYY-MM-DD`, or empty |
| `list` | STRING | `playlist`, `history`, or `none` (removed: a tombstone) |
| `addedAt` | STRING | ISO time the item entered its current list |
| `isFavorite` | INT64 | `1` or `0` |
| `rating` | INT64 | The person's rating, 1 to 5, or `0` when none |
| `returnedFor` | STRING | Air date (`YYYY-MM-DD`) of the episode that last moved this show from History back to the Playlist, or empty |
| `schemaVersion` | INT64 | |

Removing an item writes `list = none`; records are never deleted, so a stale client
can't resurrect them. The Playlist is `list = playlist`, History is `list = history`.

**Retired:** `isPurchased` (INT64) marked games as owned until November 2026. Clients no
longer read or write it; older records still carry it and must be ignored. Don't reuse
the name. The field stays in the Production schema because CloudKit can't delete
deployed fields.

### Fields and intentions

A local change marks the fields it changed as pending, durably (it survives being
offline and relaunches). Fields are grouped:

- **list**: `list`, `addedAt`, `returnedFor`
- **favorite**: `isFavorite`
- **rating**: `rating`

A pending group a client no longer knows (the retired `purchased`) is ignored when the
saved library loads.

`title`, `image` and `releaseDate` describe the item; any write carries them, and a
remote copy's values are taken unless the item is new here.

### Rules shared with the website

- Adding to the Playlist: `list = playlist`, `addedAt = now`.
- Marking played: `list = history`, `addedAt = now`. Marking played again (already
  in History) moves it out: `list = none`.
- Favorite applies to History items; on the Playlist it can only be cleared.
- **Returning shows.** A History show whose status is not `Ended` or `Canceled`,
  checked at most once a day per device, moves back to the Playlist when TMDB's
  `next_episode_to_air.air_date` falls between today and 7 days from today (local
  dates), unless `returnedFor` already equals that air date. The move sets
  `list = playlist`, `addedAt = now` and `returnedFor = <air date>`. Because the rule
  only depends on the record and TMDB, two devices that both run it agree, and a
  show marked played after its return doesn't come back again for the same episode.

## Writing and conflicts

- Writes are conditional: `update` with the last known `recordChangeTag`, or `create`
  when none is known (fails with `EXISTS` if another client created it). Never
  `forceUpdate` / `.allKeys` overwrite.
- On `CONFLICT` / `EXISTS`, fetch changes, then reapply: the remote record's fields
  are taken, except the field groups with pending local intentions, which keep their
  local values and are written again over the newer revision (the last accepted
  intention wins, per field group; offline edits can win when they reconnect).
- A pending **return** (the returning-shows move) is dropped when the remote record
  is no longer in History or its `returnedFor` already equals the pending air date.
- Turning sync on with existing local data is an **import**: it creates records only
  where none exist and never overwrites a remote record or tombstone. Importing a
  library from the old [void] webapp (`void-data.json`) works the same way.
- Order competing devices by accepted writes, not by their clocks.

## Accounts

Data is per Apple Account (`userRecordName`) and per container/environment. Changing
account must hide the previous account's data and keep its pending intentions apart,
never pushing them to the new account.

## Not synced

Per-device caches: TMDB/IGDB details (status, next episode, posters), when each show
was last checked for a new episode, filters, and which media types are turned on.
