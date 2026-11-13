// The [void] API Worker (worker/): TMDB through /api/tmdb, and IGDB games. Results are
// normalized to the media shape library.mjs takes:
// { source, mediaType, id, title, posterPath, releaseDate, overview, popularity,
//   status, nextAirDate, genres }
export const API_BASE = "https://void-game-api.ryan-inslee.workers.dev";

export class ApiError extends Error {
  constructor(status) {
    super(status === 429 ? "Too many requests. Try again in a minute." : `The server returned an error (${status}).`);
    this.status = status;
  }
}

export function createApi({ fetcher = (...args) => globalThis.fetch(...args), base = API_BASE } = {}) {
  async function get(path, params = {}) {
    const url = new URL(path, base);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    let response;
    try {
      response = await fetcher(url.href, { credentials: "omit", signal: AbortSignal.timeout(20000) });
    } catch {
      throw new Error("Couldn't reach the [void] API. Check your connection.");
    }
    if (!response.ok) throw new ApiError(response.status);
    return response.json();
  }

  return {
    async search(query) {
      const data = await get("/api/tmdb/search/multi", { query });
      return (data.results ?? []).map(raw => fromTMDB(raw)).filter(Boolean);
    },
    async trending() {
      const data = await get("/api/tmdb/trending/all/week");
      return (data.results ?? []).map(raw => fromTMDB(raw)).filter(Boolean);
    },
    async searchGames(query) {
      const data = await get("/api/games/search", { q: query });
      return (Array.isArray(data) ? data : []).map(fromGame).filter(Boolean);
    },
    async details({ source, mediaType, id }) {
      if (mediaType === "game") {
        if (source !== "igdb") throw new ApiError(404);
        return fromGame(await get(`/api/games/${id}`));
      }
      return fromTMDB(await get(`/api/tmdb/${mediaType}/${id}`), mediaType);
    },
    async providers(mediaType, id) {
      const data = await get(`/api/tmdb/${mediaType}/${id}/watch/providers`);
      return usStreamingProviders(data);
    },
  };
}

export function fromTMDB(raw, mediaType = raw?.media_type) {
  if (!raw || !Number.isSafeInteger(raw.id) || !["movie", "tv"].includes(mediaType)) return null;
  return {
    source: "tmdb", mediaType, id: raw.id,
    title: raw.title || raw.name || "Unknown title",
    posterPath: typeof raw.poster_path === "string" ? raw.poster_path : null,
    releaseDate: raw.release_date || raw.first_air_date || null,
    overview: raw.overview || "",
    popularity: raw.popularity || raw.vote_count || 0,
    status: raw.status ?? null,
    nextAirDate: raw.next_episode_to_air?.air_date ?? null,
    genres: (raw.genres ?? []).map(genre => genre?.name).filter(Boolean),
  };
}

export function fromGame(raw) {
  if (!raw || !Number.isSafeInteger(raw.id)) return null;
  return {
    source: raw.source ?? "igdb", mediaType: "game", id: raw.id,
    title: raw.title || raw.name || "Unknown title",
    posterPath: typeof raw.poster_path === "string" ? raw.poster_path : null,
    releaseDate: raw.release_date ?? null,
    overview: raw.overview || "",
    popularity: raw.popularity || 0,
    status: null, nextAirDate: null,
    genres: Array.isArray(raw.genres) ? raw.genres.filter(genre => typeof genre === "string") : [],
    platforms: Array.isArray(raw.platforms) ? raw.platforms.filter(p => typeof p === "string") : [],
  };
}

// As iOS LibraryRules.usStreamingProviders and the webapp's getUSStreamingProviders.
export function usStreamingProviders(data) {
  const us = data?.results?.US;
  const clean = name => String(name).replace(/\s+/g, " ").trim();
  const canonical = name => {
    const cleaned = clean(name);
    if (/ standard with ads$/i.test(cleaned)) return clean(cleaned.replace(/ standard with ads$/i, ""));
    if (/ with ads$/i.test(cleaned)) return clean(cleaned.replace(/ with ads$/i, ""));
    if (/ essential$/i.test(cleaned)) return clean(cleaned.replace(/ essential$/i, ""));
    if (/ premium plus$/i.test(cleaned)) return clean(cleaned.replace(/ plus$/i, ""));
    if (/ plus premium$/i.test(cleaned)) return clean(cleaned.replace(/ premium$/i, ""));
    return cleaned;
  };
  const ids = new Set();
  const names = new Set();
  const unique = [...(us?.free ?? []), ...(us?.flatrate ?? [])]
    .filter(p => !String(p.provider_name).toLowerCase().includes("channel"))
    .filter(p => !ids.has(p.provider_id) && ids.add(p.provider_id))
    .map(p => ({ id: p.provider_id, name: canonical(p.provider_name), logoPath: p.logo_path ?? null }))
    .filter(p => !names.has(p.name.toLowerCase()) && names.add(p.name.toLowerCase()));
  return unique.filter(p => !unique.some(c => c.id !== p.id && p.name.toLowerCase().startsWith(`${c.name.toLowerCase()} `)));
}

const normalize = value => value.toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, " ").trim();

// As the webapp's rankSearchResults.
export function rankSearchResults(results, query) {
  const search = normalize(query);
  const rank = (media, index) => {
    const title = normalize(media.title);
    const popularity = (media.popularity || 0) / 1_000_000;
    if (!title || !search) return 10_000 + index;
    if (title === search) return -popularity;
    if (title.startsWith(search)) return 100 + title.length - search.length - popularity;
    if (title.includes(search)) return 300 + title.indexOf(search) + title.length / 100 - popularity;
    const words = search.split(" ").filter(Boolean);
    const titleWords = title.split(" ").filter(Boolean);
    const matching = words.filter(word => titleWords.some(t => t.startsWith(word))).length;
    if (matching > 0) return 600 + (words.length - matching) * 50 + title.length / 100 - popularity;
    return 1_000 + index - popularity;
  };
  return results.map((media, index) => ({ media, index, rank: rank(media, index) }))
    .sort((a, b) => a.rank - b.rank || b.media.popularity - a.media.popularity || a.index - b.index)
    .map(entry => entry.media);
}

export function imageURL(path, size = "w342") {
  if (!path) return null;
  if (/^https:\/\//.test(path)) return path;
  return /^\/[A-Za-z0-9._-]+$/.test(path) ? `https://image.tmdb.org/t/p/${size}${path}` : null;
}
