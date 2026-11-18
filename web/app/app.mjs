// Void on the web: sign in with Apple, see and change the Playlist and History, search
// to add. Storage, sign-in and sync are in site.mjs.
import { createSite, describeCloudKitError, CloudKitError, takeCallback } from "./site.mjs";
import { imageURL, rankSearchResults, trailerEmbedURL, trailerThumbnailURL } from "../shared/api.mjs";
import { itemFor, listItems, MEDIA_TYPES, recordName } from "../shared/library.mjs";
import { legacyItems, LegacyImportError } from "./legacy-import.mjs";

const main = document.querySelector("main");
// Inside another site's frame, stay hidden, so nobody can trick clicks.
if (window.top !== window.self) throw new Error("Void won't run inside another page.");
main.hidden = false;

const $ = selector => document.querySelector(selector);
// Served from this computer (npm run dev): Apple sign-in can only come back to
// void.tinyk.ing, so the library shows without it. Nothing syncs.
const LOCAL_PREVIEW = ["localhost", "127.0.0.1"].includes(location.hostname);
const notice = $("#notice");
function showNotice(text) { notice.textContent = text ?? ""; notice.hidden = !text; }

let site;
try {
  localStorage.getItem("voidProbe");
  site = createSite({ storage: localStorage, pending: sessionStorage, locks: navigator.locks });
} catch {
  showNotice("Void needs this browser to allow site data (cookies and storage) for void.tinyk.ing.");
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
// Popular: TMDB's trending movies and shows this week, as on the iOS Search screen.
let popular = null;       // null until loaded
let popularError = null;
let loadingPopular = false;
// Search results and Popular show titles that may not be in the library.
const browsing = () => Boolean(query) || tab === "popular";

const mediaOf = item => ({ source: item.source, mediaType: item.mediaType, id: item.mediaID, title: item.title, posterPath: item.image, releaseDate: item.releaseDate });

// "Today", "Tomorrow", "In 5 days"; "Yesterday" and "2 days ago" just after. As on iOS.
const countdown = days => days === 0 ? "Today" : days === 1 ? "Tomorrow" : days === -1 ? "Yesterday" : days < 0 ? `${-days} days ago` : `In ${days} days`;

// Only within the 30 days that also move a title to the top of the Playlist.
function badge(name, item) {
  if (tab !== "playlist" || query) return null;
  if (item.mediaType === "tv") {
    const days = daysUntil(details[name]?.nextAirDate);
    return days != null && days >= -3 && days <= 30 ? countdown(days) : null;
  }
  const days = daysUntil(item.releaseDate);
  return days != null && days > 0 && days <= 30 ? countdown(days) : null;
}

function card(media, item, name) {
  const button = element("button", "card");
  button.type = "button";
  const frame = element("span", "frame");
  frame.append(poster(media.posterPath));
  const label = badge(name, item ?? {});
  if (label) frame.append(element("span", "badge", label));
  const marks = [browsing() && item?.list === "playlist" && "+", browsing() && item?.list === "history" && "✓", item?.isFavorite && "♥"].filter(Boolean).join(" ");
  if (marks) frame.append(element("span", "marks", marks));
  button.append(frame);
  button.append(element("span", "title", media.title));
  if (browsing()) button.append(element("span", "meta", [TYPE_NAMES[media.mediaType], media.releaseDate?.slice(0, 4)].filter(Boolean).join(" · ")));
  button.setAttribute("aria-label", [media.title, item?.isFavorite && "favorite", label].filter(Boolean).join(", "));
  button.addEventListener("click", () => openDetails(media));
  return button;
}

function render() {
  if (!current) return;
  const signedIn = current.signedIn;
  const synced = current.sync?.enabled;
  const firstVisit = !(synced || signedIn || LOCAL_PREVIEW);
  // Only for people who use Void for iPhone: after sign-in, nothing shows until the
  // first sync is done, and an iCloud with no Void data at all gets sent to the app.
  const preview = LOCAL_PREVIEW && !synced;
  const loading = !firstVisit && !preview && !current.sync.lastSync;
  const needsApp = !firstVisit && !preview && !loading && Object.keys(current.state?.items ?? {}).length === 0;
  $("#account").textContent = signedIn ? "Sign out" : "Sign in again";
  $("#account").classList.toggle("secondary", signedIn);
  $("#account").hidden = firstVisit;
  $("#intro").hidden = !firstVisit;
  $("#loading").hidden = !loading;
  $("#needs-app").hidden = !needsApp;
  $("#library").hidden = firstVisit || loading || needsApp;
  if (firstVisit || loading || needsApp) {
    if (dialog.open) dialog.close();
    showNotice(lastMessage);
    $("#sync-status").textContent = "";
    return;
  }

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
  } else if (tab === "popular") {
    const shown = (popular ?? []).filter(media => !typeFilter || media.mediaType === typeFilter);
    cards = shown.map(media => card(media, state ? itemFor(state, media) : null, null));
    $("#status").textContent = popular === null ? (popularError ?? "Loading popular movies and shows…")
      : shown.length ? `Popular this week: ${shown.length}` : typeFilter === "game" ? "Popular is movies and shows only." : "Nothing popular to show.";
  } else {
    const entries = state ? listItems(state, tab, { type: typeFilter, favoritesOnly: tab === "history" && favoritesOnly, details: name => details[name] }) : [];
    cards = entries.map(({ name, item }) => card(mediaOf(item), item, name));
    $("#status").textContent = entries.length
      ? `${entries.length} on your ${tab === "playlist" ? "Playlist" : "History"}`
      : tab === "playlist" ? "Nothing on your Playlist. Search to add movies, shows and games." : "Nothing in History yet.";
  }
  grid.replaceChildren(...cards);

  const status = $("#sync-status");
  if (!synced) status.textContent = LOCAL_PREVIEW ? "Local preview: not signed in, so changes stay in this browser and nothing syncs." : "";
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
  if (media.overview) text.append(element("p", "overview", media.overview));
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

// Seasons, trailers and cast sit below the streaming line, in #details-extra. renderDetails rebuilds the top
// on every sync, so they're built once per opening and a playing trailer keeps playing.
// Each has its own slot, in this order, since cast can load before or after the rest.
const extra = $("#details-extra");
const SLOTS = ["Seasons", "Trailers", "Cast"];
function resetExtra() {
  extra.replaceChildren(...SLOTS.map(() => element("div")));
}
function section(title) {
  const node = element("section", "extra");
  node.append(element("h3", "label", title));
  extra.children[SLOTS.indexOf(title)].replaceChildren(node);
  return node;
}

function renderTrailers(videos) {
  if (!videos?.length) return;
  const row = element("div", "trailers");
  for (const video of videos) {
    const tile = element("div", "trailer");
    const thumb = () => {
      const button = element("button", "thumb");
      button.type = "button";
      button.setAttribute("aria-label", `Play ${video.name}`);
      const img = element("img");
      img.src = trailerThumbnailURL(video.key); img.alt = ""; img.loading = "lazy"; img.referrerPolicy = "no-referrer";
      button.append(img, element("span", "play", "▶"));
      button.addEventListener("click", () => {
        // One plays at a time: any other player goes back to its thumbnail.
        for (const other of row.querySelectorAll(".trailer")) other.stop?.();
        const player = element("iframe", "player");
        player.src = trailerEmbedURL(video.key);
        player.title = video.name;
        player.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
        player.allowFullscreen = true;
        // YouTube refuses embeds that don't say which site they're on.
        player.referrerPolicy = "strict-origin-when-cross-origin";
        button.replaceWith(player);
        tile.stop = () => { player.replaceWith(thumb()); tile.stop = null; };
      });
      return button;
    };
    tile.append(thumb(), element("span", "caption", video.name));
    row.append(tile);
  }
  section("Trailers").append(row);
}

function renderCast(cast) {
  if (!cast?.length) return;
  const row = element("div", "cast");
  for (const person of cast) {
    const tile = element("div", "person");
    tile.append(poster(person.profilePath, "w185"), element("span", "caption", person.name));
    if (person.character) tile.append(element("span", "hint", person.character));
    row.append(tile);
  }
  section("Cast").append(row);
}

function renderSeasons(showID, seasons) {
  if (!seasons?.length) return;
  const node = section("Seasons");
  for (const season of seasons) {
    const box = element("details", "season");
    const summary = element("summary");
    summary.append(element("span", null, season.name),
      element("span", "label", [season.episodeCount != null && `${season.episodeCount} ep`, season.airDate?.slice(0, 4)].filter(Boolean).join(" · ")));
    const list = element("ol", "episodes");
    box.append(summary, list);
    let loaded = false;
    box.addEventListener("toggle", async () => {
      if (!box.open || loaded) return;
      loaded = true;
      list.replaceChildren(element("li", "hint", "Loading…"));
      try {
        const episodes = await site.api.season(showID, season.number);
        list.replaceChildren(...(episodes.length ? episodes.map(episodeRow) : [element("li", "hint", "No episodes listed yet.")]));
      } catch {
        loaded = false;
        list.replaceChildren(element("li", "hint", "Couldn't load this season. Close and open it to try again."));
      }
    });
    node.append(box);
  }
}

// As iOS SeasonView: before an episode airs its still and summary stay hidden until
// asked for, so nothing is spoiled.
function episodeRow(episode) {
  const row = element("li", "episode");
  const days = daysUntil(episode.airDate);
  const aired = days != null && days <= 0;
  const text = element("div");
  text.append(element("span", "label", `E${episode.episodeNumber}${episode.airDate ? ` · ${shortDate(episode.airDate)}` : ""}`),
    element("p", "name", episode.name));
  if (aired) {
    row.append(episode.stillPath ? poster(episode.stillPath, "w300") : element("div", "poster empty"));
    if (episode.overview) text.append(element("p", "hint", episode.overview));
  } else {
    row.append(element("div", "poster empty"));
    if (episode.overview) {
      const reveal = element("button", "link", "Show summary");
      reveal.type = "button";
      reveal.addEventListener("click", () => reveal.replaceWith(element("p", "hint", episode.overview)));
      text.append(reveal);
    } else text.append(element("p", "hint", "No summary yet."));
  }
  row.append(text);
  return row;
}

async function openDetails(media) {
  openMedia = media;
  openExtra = null;
  resetExtra();
  renderDetails();
  if (!dialog.open) dialog.showModal();
  const opened = media;
  if (media.mediaType !== "game") {
    site.api.credits(media.mediaType, media.id).then(cast => { if (openMedia === opened) renderCast(cast); }, () => {});
  }
  try {
    const full = await site.api.details(media);
    if (openMedia !== opened) return;
    openExtra = { ...full, posterPath: full.posterPath ?? media.posterPath };
    renderTrailers(full.videos);
    if (media.mediaType === "tv") renderSeasons(media.id, full.seasons);
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
dialog.addEventListener("close", () => { openMedia = null; extra.replaceChildren(); render(); });

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
    if (tab === "popular") loadPopular();
  });
}

async function loadPopular() {
  if (popular !== null || loadingPopular) return;
  loadingPopular = true;
  popularError = null;
  try {
    popular = await site.api.trending();
  } catch (error) {
    popularError = `Couldn't load popular titles. ${error?.message ?? ""} Press Popular to try again.`.trim();
  } finally {
    loadingPopular = false;
    render();
  }
}

// --- Import (TEMPORARY; see legacy-import.mjs)
$("#import").addEventListener("click", () => $("#import-file").click());
$("#import-file").addEventListener("change", async event => {
  const input = event.currentTarget;
  const file = input.files?.[0];
  input.value = "";
  if (!file || !current?.state) return;
  try {
    const items = legacyItems(await file.text());
    const fresh = items.filter(item => !current.state.items[recordName(item)]);
    if (!fresh.length) { lastMessage = `Nothing to import: all ${items.length} items are already in your library.`; render(); return; }
    if (!confirm(`Import ${fresh.length} item${fresh.length === 1 ? "" : "s"} into your library? ${items.length - fresh.length} already there will be left as they are.`)) return;
    apply(await site.importLegacy(fresh), { message: `Imported ${fresh.length} item${fresh.length === 1 ? "" : "s"}. They'll sync to iCloud in a moment.` });
  } catch (error) {
    lastMessage = error instanceof LegacyImportError ? error.message : "Couldn't read that file.";
    render();
  }
});

$("#check-again").addEventListener("click", async event => {
  const button = event.currentTarget;
  button.disabled = true;
  try { await syncNow(); } finally { button.disabled = false; }
});

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
