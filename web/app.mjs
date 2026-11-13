// [void] on the web: sign in with Apple, see and change the Playlist and History, search
// to add. Storage, sign-in and sync are in site.mjs.
import { createSite, describeCloudKitError, CloudKitError, takeCallback } from "./site.mjs";
import { imageURL, rankSearchResults } from "./shared/api.mjs";
import { itemFor, listItems, MEDIA_TYPES, recordName } from "./shared/library.mjs";

const main = document.querySelector("main");
// Inside another site's frame, stay hidden, so nobody can trick clicks.
if (window.top !== window.self) throw new Error("[void] won't run inside another page.");
main.hidden = false;

const $ = selector => document.querySelector(selector);
const notice = $("#notice");
function showNotice(text) { notice.textContent = text ?? ""; notice.hidden = !text; }

let site;
try {
  localStorage.getItem("voidProbe");
  site = createSite({ storage: localStorage, pending: sessionStorage, locks: navigator.locks });
} catch {
  showNotice("[void] needs this browser to allow site data (cookies and storage) for void.tinyk.ing.");
  throw new Error("Storage unavailable.");
}

// Next-episode dates for sorting the Playlist, cached a day in this browser.
const DETAILS_KEY = "voidDetails";
const DAY = 24 * 60 * 60 * 1000;
let details = (() => { try { return JSON.parse(localStorage.getItem(DETAILS_KEY)) ?? {}; } catch { return {}; } })();
const saveDetails = () => { try { localStorage.setItem(DETAILS_KEY, JSON.stringify(details)); } catch {} };

// --- DOM helpers: everything is built as nodes with textContent; nothing is parsed as HTML.
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}
function poster(path, size = "w342") {
  const src = imageURL(path, size);
  if (!src) return element("div", "poster empty");
  const img = element("img", "poster");
  img.src = src; img.alt = ""; img.loading = "lazy"; img.decoding = "async"; img.referrerPolicy = "no-referrer";
  img.addEventListener("error", () => img.replaceWith(element("div", "poster empty")));
  return img;
}
const TYPE_NAMES = { movie: "Movie", tv: "Show", game: "Game" };
const TYPE_PLURAL = { movie: "Movies", tv: "Shows", game: "Games" };
const shortDate = value => {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value ?? "");
  if (!match) return null;
  const date = new Date(+match[1], +match[2] - 1, +match[3]);
  const sameYear = date.getFullYear() === new Date().getFullYear();
  return date.toLocaleDateString(undefined, sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" });
};
const daysUntil = value => {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value ?? "");
  if (!match) return null;
  const today = new Date(); today.setHours(0, 0, 0, 0);
  return Math.round((new Date(+match[1], +match[2] - 1, +match[3]) - today) / DAY);
};

// --- State
let current = null;       // the last view from site.mjs
let lastMessage = null;
let tab = "playlist";
let typeFilter = null;
let favoritesOnly = false;
let query = "";
let results = [];

const mediaOf = item => ({ source: item.source, mediaType: item.mediaType, id: item.mediaID, title: item.title, posterPath: item.image, releaseDate: item.releaseDate });

function badge(name, item) {
  if (tab !== "playlist" || query) return null;
  if (item.mediaType === "tv") {
    const next = details[name]?.nextAirDate;
    const days = daysUntil(next);
    if (days != null && days >= -3) return days === 0 ? "Today" : days === 1 ? "Tomorrow" : shortDate(next);
    return null;
  }
  const days = daysUntil(item.releaseDate);
  return days != null && days > 0 ? (days === 1 ? "Tomorrow" : shortDate(item.releaseDate)) : null;
}

function card(media, item, name) {
  const button = element("button", "card");
  button.type = "button";
  const frame = element("span", "frame");
  frame.append(poster(media.posterPath));
  const label = badge(name, item ?? {});
  if (label) frame.append(element("span", "badge", label));
  const marks = [query && item?.list === "playlist" && "+", query && item?.list === "history" && "✓", item?.isFavorite && "♥"].filter(Boolean).join(" ");
  if (marks) frame.append(element("span", "marks", marks));
  button.append(frame);
  button.append(element("span", "title", media.title));
  if (query) button.append(element("span", "meta", [TYPE_NAMES[media.mediaType], media.releaseDate?.slice(0, 4)].filter(Boolean).join(" · ")));
  button.setAttribute("aria-label", [media.title, item?.isFavorite && "favorite", label].filter(Boolean).join(", "));
  button.addEventListener("click", () => openDetails(media));
  return button;
}

function render() {
  if (!current) return;
  const signedIn = current.signedIn;
  const synced = current.sync?.enabled;
  const firstVisit = !(synced || signedIn);
  $("#account").textContent = signedIn ? "Sign out" : "Sign in again";
  $("#account").classList.toggle("secondary", signedIn);
  $("#account").hidden = firstVisit;
  $("#intro").hidden = !firstVisit;
  $("#library").hidden = firstVisit;
  if (firstVisit) { showNotice(lastMessage); return; }

  for (const button of document.querySelectorAll("[data-tab]")) button.setAttribute("aria-pressed", String(button.dataset.tab === tab));
  const chips = $("#chips");
  chips.replaceChildren();
  const chip = (text, pressed, onClick) => {
    const button = element("button", "chip", text);
    button.type = "button";
    button.setAttribute("aria-pressed", String(pressed));
    button.addEventListener("click", onClick);
    chips.append(button);
  };
  chip("All", !typeFilter, () => { typeFilter = null; render(); });
  for (const type of MEDIA_TYPES) chip(TYPE_PLURAL[type], typeFilter === type, () => { typeFilter = typeFilter === type ? null : type; render(); });
  if (tab === "history" && !query) chip("♥ Favorites", favoritesOnly, () => { favoritesOnly = !favoritesOnly; render(); });

  const state = current.state;
  const grid = $("#grid");
  let cards;
  if (query) {
    const shown = results.filter(media => !typeFilter || media.mediaType === typeFilter);
    cards = shown.map(media => card(media, state ? itemFor(state, media) : null, null));
    $("#status").textContent = searching ? "Searching…" : shown.length ? `${shown.length} results` : `Nothing found for “${query}”.`;
  } else {
    const entries = state ? listItems(state, tab, { type: typeFilter, favoritesOnly: tab === "history" && favoritesOnly, details: name => details[name] }) : [];
    cards = entries.map(({ name, item }) => card(mediaOf(item), item, name));
    $("#status").textContent = entries.length
      ? `${entries.length} on your ${tab === "playlist" ? "Playlist" : "History"}`
      : tab === "playlist" ? "Nothing on your Playlist. Search to add movies, shows and games." : "Nothing in History yet.";
  }
  grid.replaceChildren(...cards);

  const status = $("#sync-status");
  if (!synced) status.textContent = "";
  else {
    const last = current.sync.lastSync ? `Last synced ${new Date(current.sync.lastSync).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}` : "Not synced yet";
    const pending = current.sync.pending ? `, ${current.sync.pending} change${current.sync.pending === 1 ? "" : "s"} pending` : "";
    status.textContent = `${last}${pending}.`;
  }
  showNotice(lastMessage ?? (synced && !signedIn ? "Your iCloud sign-in expired. Sign in again to sync; changes made here stay pending until then." : null));
}

function apply(result, { message } = {}) {
  current = result;
  lastMessage = message !== undefined ? message : result.message ?? null;
  render();
  if (dialog.open && openMedia) renderDetails();
}

// --- Details dialog
const dialog = $("#details");
let openMedia = null;
let openExtra = null;

function renderDetails() {
  const media = { ...openMedia, ...(openExtra ?? {}) };
  const item = current?.state ? itemFor(current.state, media) : null;
  const name = recordName({ source: media.source, mediaType: media.mediaType, mediaID: media.id });
  const body = $("#details-body");
  body.replaceChildren();
  const head = element("div", "details-head");
  head.append(poster(media.posterPath));
  const text = element("div");
  text.append(element("h2", null, media.title));
  text.append(element("p", "label", [TYPE_NAMES[media.mediaType], media.releaseDate?.slice(0, 4), media.mediaType === "tv" && media.status].filter(Boolean).join(" · ")));
  if (media.genres?.length) text.append(element("p", "hint", media.genres.slice(0, 3).join(", ")));
  if (media.nextAirDate) text.append(element("p", "hint", `Next episode ${shortDate(media.nextAirDate)}`));
  head.append(text);
  body.append(head);

  const actions = element("div", "actions");
  const action = (label, pressed, onClick) => {
    const button = element("button", pressed ? "on" : "secondary", label);
    button.type = "button";
    button.setAttribute("aria-pressed", String(pressed));
    button.addEventListener("click", async () => { button.disabled = true; apply(await onClick(), { message: null }); });
    actions.append(button);
  };
  action(item?.list === "playlist" ? "✓ On Playlist" : "+ Playlist", item?.list === "playlist", () => site.togglePlaylist(media));
  action(item?.list === "history" ? "✓ Played" : "Mark Played", item?.list === "history", () => site.toggleHistory(media));
  if (item?.list === "history" || item?.isFavorite) action(item?.isFavorite ? "♥ Favorite" : "♡ Favorite", Boolean(item?.isFavorite), () => site.toggleFavorite(name));
  body.append(actions);

  if (media.overview) body.append(element("p", "overview", media.overview));
  if (media.mediaType !== "game") {
    const providers = openExtra?.providers;
    const line = element("p", "hint");
    line.textContent = providers === undefined ? "Checking where it streams…"
      : providers.length ? `Streams on ${providers.map(p => p.name).join(", ")} (US, from JustWatch).` : "Not on a US subscription service.";
    body.append(line);
  } else if (media.platforms?.length) {
    body.append(element("p", "hint", media.platforms.join(", ")));
  }
}

async function openDetails(media) {
  openMedia = media;
  openExtra = null;
  renderDetails();
  if (!dialog.open) dialog.showModal();
  const opened = media;
  try {
    const full = await site.api.details(media);
    if (openMedia !== opened) return;
    openExtra = { ...full, posterPath: full.posterPath ?? media.posterPath };
    if (media.mediaType === "tv") {
      details[recordName({ source: "tmdb", mediaType: "tv", mediaID: media.id })] = { nextAirDate: full.nextAirDate, at: Date.now() };
      saveDetails();
    }
    renderDetails();
    if (media.mediaType !== "game") {
      const providers = await site.api.providers(media.mediaType, media.id);
      if (openMedia !== opened) return;
      openExtra = { ...openExtra, providers };
      renderDetails();
    }
  } catch {
    if (openMedia === opened && media.mediaType !== "game") { openExtra = { ...(openExtra ?? {}), providers: [] }; renderDetails(); }
  }
}
$("#details-close").addEventListener("click", () => dialog.close());
dialog.addEventListener("click", event => { if (event.target === dialog) dialog.close(); });
dialog.addEventListener("close", () => { openMedia = null; render(); });

// --- Search
let searching = false, searchTimer, searchToken = 0;
$("#search").addEventListener("input", event => {
  query = event.target.value.trim();
  clearTimeout(searchTimer);
  if (!query) { results = []; searching = false; render(); return; }
  searching = true;
  render();
  searchTimer = setTimeout(async () => {
    const token = ++searchToken;
    const q = query;
    const [video, games] = await Promise.allSettled([site.api.search(q), q.length >= 2 ? site.api.searchGames(q) : Promise.resolve([])]);
    if (token !== searchToken) return;
    const found = [...(video.value ?? []), ...(games.value ?? [])];
    results = rankSearchResults(found, q);
    searching = false;
    lastMessage = !found.length && video.status === "rejected" ? video.reason?.message ?? null : null;
    render();
  }, 350);
});
$("#search-form").addEventListener("submit", event => event.preventDefault());

for (const button of document.querySelectorAll("[data-tab]")) {
  button.addEventListener("click", () => {
    tab = button.dataset.tab;
    favoritesOnly = false;
    query = ""; $("#search").value = ""; results = [];
    render();
  });
}

// --- Sync
let syncing = null, syncTimer, lastSyncAt = 0;
function syncNow() {
  clearTimeout(syncTimer);
  syncing ??= (async () => {
    try {
      const view = await site.view();
      if (!view.signedIn) { apply(view, { message: null }); return; }
      apply(await site.sync());
      lastSyncAt = Date.now();
      if (await site.checkReturningShows()) apply(await site.view());
      refreshPlaylistDetails();
    } finally { syncing = null; }
  })();
  return syncing;
}
function scheduleSync(delay = 1500) {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(syncNow, delay);
}
site.onLocalChange = () => scheduleSync();

// Next-episode dates for Playlist shows, at most once a day each, a few at a time.
let refreshingDetails = false;
async function refreshPlaylistDetails() {
  if (refreshingDetails || !current?.state) return;
  refreshingDetails = true;
  try {
    const stale = listItems(current.state, "playlist", { type: "tv" })
      .filter(({ name }) => !details[name] || Date.now() - details[name].at > DAY).slice(0, 15);
    for (const { name, item } of stale) {
      try {
        const full = await site.api.details({ source: "tmdb", mediaType: "tv", id: item.mediaID });
        details[name] = { nextAirDate: full.nextAirDate, at: Date.now() };
      } catch (error) { if (error.status === 429) break; }
    }
    if (stale.length) { saveDetails(); render(); }
  } finally { refreshingDetails = false; }
}

async function onAccount(event) {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    if (current?.signedIn) {
      const pending = current.sync?.pending ?? 0;
      if (pending && !confirm(`${pending} change${pending === 1 ? " hasn't" : "s haven't"} synced to iCloud yet and will be lost. Sign out anyway?`)) return;
      apply(await site.signOut(), { message: "Signed out. Your library is still in iCloud." });
      return;
    }
    $("#sync-status").textContent = "Opening Apple sign-in…";
    location.assign(await site.beginSignIn());
  } catch (error) {
    showNotice(error instanceof CloudKitError ? describeCloudKitError(error)
      : /set up/.test(error?.message ?? "") ? error.message
        : "Couldn't start Apple sign-in. Check your connection and try again.");
  } finally { button.disabled = false; }
}
$("#account").addEventListener("click", onAccount);
$("#sign-in").addEventListener("click", onAccount);

addEventListener("storage", event => {
  if (event.key === null || event.key.startsWith("voidLibrary") || event.key === "voidSyncSettings") site.view().then(view => apply(view, { message: lastMessage }));
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && Date.now() - lastSyncAt > 15000) syncNow();
});
setInterval(() => { if (document.visibilityState === "visible") syncNow(); }, 120000);

// Coming back from Apple's sign-in: take the token out of the address bar first.
const callback = takeCallback(location.href, { pending: sessionStorage });
if (callback) history.replaceState(null, "", callback.cleanURL);
apply(await site.view(), { message: null });
if (callback?.token) {
  $("#sync-status").textContent = "Signing in…";
  apply(await site.finishSignIn(callback.token));
  lastSyncAt = Date.now();
  if (await site.checkReturningShows()) apply(await site.view());
  refreshPlaylistDetails();
} else {
  await syncNow();
  if (callback?.refused) { lastMessage = "That sign-in didn't start on this page, so it was ignored. Sign in again."; render(); }
}
