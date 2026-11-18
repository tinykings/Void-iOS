// [void] on the web: storage, Apple sign-in, sync and the returning-shows check, without
// the page. Adapted from Royal Saved's site.mjs. The CloudKit client, library and sync
// rules are in shared/ and follow docs/sync-schema.md, as iOS does.
import { CloudKitClient, CloudKitError, VOID_CONTAINER, appleSignInURL, callbackToken, describeCloudKitError } from "../shared/cloudkit.mjs";
import { createApi } from "../shared/api.mjs";
import { isInLocalDayWindow, needsReturnCheck, RETURN_WINDOW_DAYS, returnToPlaylist, togglePlaylist, toggleHistory, toggleFavorite } from "../shared/library.mjs";
import { accountLibraryKey, createLibrary, LIBRARY_KEY, SYNC_SETTINGS_KEY } from "../shared/store.mjs";
import { runSync, SyncPausedError } from "../shared/sync-runner.mjs";
import { RECORD_TYPE } from "../shared/sync.mjs";

// [void]'s container in Production, with the website's own web API token. In CloudKit
// Console the token's sign-in callback is a URL Redirect to https://void.tinyk.ing/app/ and
// its allowed origin is void.tinyk.ing only. A web API token identifies the app, not a
// user, and is meant to be public. Until it's set, sign-in explains what's missing.
export const SITE_CLOUDKIT = Object.freeze({
  container: VOID_CONTAINER,
  environment: "production",
  apiToken: "1b5f4263a2afc561e356d554122cede72a448790d5336aec5c262e7297d3e3c3",
});

export const TOKEN_KEY = "voidCloudKitToken";
// Set in sessionStorage when this tab sends someone to Apple's sign-in, so a token in
// the address is only accepted on the way back from a sign-in started here.
export const SIGN_IN_STARTED_KEY = "voidSignInStarted";
const SIGN_IN_WINDOW = 15 * 60 * 1000;
const SIGN_IN_CODES = ["AUTHENTICATION_REQUIRED", "AUTHENTICATION_FAILED"];

export function webStore(storage) {
  return {
    async get(key) {
      const raw = storage.getItem(key);
      if (raw == null) return { [key]: undefined };
      try { return { [key]: JSON.parse(raw) }; } catch { return { [key]: undefined }; }
    },
    async set(entries) { for (const [key, value] of Object.entries(entries)) storage.setItem(key, JSON.stringify(value)); },
    async remove(key) { storage.removeItem(key); },
  };
}

// The CloudKit client as the sync runner uses it, seeing only VoidItem records.
export function itemsOnly(api) {
  return {
    config: api.config,
    currentUser: () => api.currentUser(),
    ensureSyncZone: () => api.ensureSyncZone(),
    async zoneChanges(syncToken) {
      const changes = await api.zoneChanges(syncToken);
      return { ...changes, records: changes.records.filter(record => record?.deleted || record?.recordType === RECORD_TYPE) };
    },
    modifySyncRecords: operations => api.modifySyncRecords(operations),
  };
}

// Reads the CloudKit token Apple appended to this page's address (see Royal Saved).
export function takeCallback(href, { pending, now = Date.now() }) {
  const url = new URL(href);
  const names = [...url.searchParams.keys()].filter(name => name.startsWith("ck"));
  if (names.length === 0) return null;
  for (const name of names) url.searchParams.delete(name);
  const started = Number(pending.getItem(SIGN_IN_STARTED_KEY));
  pending.removeItem(SIGN_IN_STARTED_KEY);
  const cleanURL = url.href;
  if (!(started > 0 && now - started >= 0 && now - started < SIGN_IN_WINDOW)) return { cleanURL, token: null, refused: true };
  try {
    return { cleanURL, token: callbackToken(href, new URL("./", href).href), refused: false };
  } catch {
    return { cleanURL, token: null, refused: true };
  }
}

export function syncMessage(error) {
  if (error instanceof SyncPausedError) return `Sync paused: ${error.message}`;
  if (error instanceof CloudKitError && SIGN_IN_CODES.includes(error.code)) return "Sign in again to keep syncing. Changes stay pending.";
  if (error instanceof CloudKitError) return `Sync failed: ${describeCloudKitError(error)} Changes stay pending.`;
  return "Sync failed. Changes stay pending.";
}

// `storage`: Web Storage for the library and token (localStorage).
// `pending`: Web Storage for the sign-in marker (sessionStorage).
// `locks`: navigator.locks, so tabs take turns with the library and CloudKit.
export function createSite({ storage, pending, locks, fetcher, apiFetcher, config = SITE_CLOUDKIT, now = () => Date.now() }) {
  const store = webStore(storage);
  let onLocalChange = () => {};
  const library = createLibrary({ storage: store, onChange: () => onLocalChange() });
  const api = createApi(apiFetcher ? { fetcher: apiFetcher } : {});
  const getToken = async () => (await store.get(TOKEN_KEY))[TOKEN_KEY] ?? null;
  const setToken = token => (token ? store.set({ [TOKEN_KEY]: token }) : store.remove(TOKEN_KEY));
  const client = () => new CloudKitClient(config, { fetcher, getToken, setToken });
  const exclusive = task => (locks ? locks.request("void-library", () => task()) : task());

  const view = async () => ({ ...(await library.view()), signedIn: Boolean(await getToken()) });

  async function useAccount(ck) {
    const account = await ck.currentUser();
    await library.useAccount({ account, container: ck.config.container, environment: ck.config.environment });
  }

  async function syncNow() {
    let message, ok = false;
    try {
      const ck = itemsOnly(client());
      if (!(await getToken())) throw new CloudKitError("AUTHENTICATION_REQUIRED");
      if (!(await library.settings())) await useAccount(ck);
      const result = await runSync({ api: ck, library, now });
      ok = true;
      message = result.failed ? `${result.failed} change${result.failed === 1 ? " was" : "s were"} refused; ${result.pending} pending.` : null;
    } catch (error) {
      message = syncMessage(error);
    }
    return { ...(await view()), ok, message };
  }

  // docs/sync-schema.md, "Returning shows": History shows with an episode airing within
  // a week go back to the Playlist, once per episode. Checked once a day per show here.
  // TMDB is asked outside the lock; each result is applied under it.
  async function checkReturningShows() {
    const settings = await exclusive(() => library.settings());
    if (!settings) return 0;
    const key = accountLibraryKey(settings);
    const state = await exclusive(() => library.read(key));
    if (!state) return 0;
    let returned = 0;
    for (const [name, item] of Object.entries(state.items)) {
      if (item.list !== "history" || item.mediaType !== "tv" || !needsReturnCheck(state.checks?.[name], now())) continue;
      let details;
      try { details = await api.details({ source: item.source, mediaType: item.mediaType, id: item.mediaID }); }
      catch (error) { if (error.status === 429) break; continue; }
      const airDate = details?.nextAirDate;
      const due = airDate && isInLocalDayWindow(airDate, now(), RETURN_WINDOW_DAYS);
      await exclusive(() => library.apply(key, current => {
        let next = { ...current, checks: { ...current.checks, [name]: { checkedAt: now(), status: details?.status ?? null, nextAirDate: airDate ?? null } } };
        if (due) {
          const moved = returnToPlaylist(next, name, airDate, now());
          if (moved !== next) returned++;
          next = moved;
        }
        return next;
      }));
    }
    if (returned) onLocalChange();
    return returned;
  }

  const change = fn => exclusive(async () => { await library.change(fn); return view(); });

  return {
    api,
    set onLocalChange(callback) { onLocalChange = callback; },
    view: () => exclusive(view),
    sync: () => exclusive(syncNow),
    checkReturningShows,
    togglePlaylist: media => change(state => togglePlaylist(state, media, now())),
    toggleHistory: media => change(state => toggleHistory(state, media, now())),
    toggleFavorite: name => change(state => toggleFavorite(state, name)),

    // Returns Apple's sign-in address to go to.
    beginSignIn: () => exclusive(async () => {
      if (/^SET_ME/.test(config.apiToken)) throw new Error("[void] on the web isn't set up yet: it needs its CloudKit web API token (site.mjs).");
      await setToken(null);
      try {
        await client().currentUser();
      } catch (error) {
        if (!(error instanceof CloudKitError) || error.code !== "AUTHENTICATION_REQUIRED" || !error.redirectURL) throw error;
        const url = appleSignInURL(error.redirectURL);
        pending.setItem(SIGN_IN_STARTED_KEY, String(now()));
        return url;
      }
      throw new Error("CloudKit didn't ask for a sign-in.");
    }),

    finishSignIn: token => exclusive(async () => {
      await setToken(token);
      return syncNow();
    }),

    // Forgets the token and this browser's copy of the library; it stays in iCloud.
    signOut: () => exclusive(async () => {
      const settings = await library.settings();
      await setToken(null);
      await library.useAccount(null);
      if (settings) await store.remove(accountLibraryKey(settings));
      await store.remove(LIBRARY_KEY);
      await store.remove(SYNC_SETTINGS_KEY);
      return view();
    }),
  };
}

export { CloudKitError, describeCloudKitError };
