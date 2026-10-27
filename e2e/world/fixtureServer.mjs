// The e2e world's stand-in for the internet (docs/testing.md): fixture RSS feeds,
// their audio (with Range requests, for streaming), artwork, chapters, and a fake
// Apple Podcasts directory that the backend searches (PODDLE_DIRECTORY_URL).
// Scenarios change it through /_control.
//
//   node e2e/world/fixtureServer.mjs <port>
//
// GET  /feeds/<slug>.xml           a show's RSS
// GET  /audio/<name>.mp3           a tone, Range-aware
// GET  /art/<slug>.png             artwork
// GET  /chapters/<guid>.json       Podcasting 2.0 chapters
// GET  /itunes/search?term=…       Apple's search API, over the public shows (or their episodes,
//                                  with entity=podcastEpisode)
// GET  /itunes/lookup?id=…         Apple's lookup API
// POST /_control/reset             back to the shows in shows.mjs
// POST /_control/episodes          { show: "<title>", title, audio? } adds a newest episode
// GET  /_control/hits              which feeds and audio were fetched, for debugging
// POST /_world/<op>                the world API (worldApi.mjs), once the backend is up

import { createReadStream, statSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AUDIO_SECONDS, SHOWS, showByTitle } from "./shows.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtures = path.join(here, "..", "fixtures");

export function startFixtureServer({ port, host = "127.0.0.1" }) {
  const base = `http://${host}:${port}`;
  const startedAt = Date.now();
  let extra = {};
  let hits = [];
  let world = null;

  const episodesOf = (slug) => [...SHOWS[slug].episodes, ...(extra[slug] ?? [])];

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", base);
    hits.push(`${req.method} ${url.pathname}`);
    if (hits.length > 500) hits = hits.slice(-250);
    try {
      if (url.pathname.startsWith("/_control/")) return await control(req, res, url);
      if (url.pathname.startsWith("/_world/")) {
        if (!world) return send(res, 503, "text/plain", "the backend isn't up yet");
        const result = await world(url.pathname.slice("/_world/".length), await readJson(req));
        return send(res, 200, "application/json", JSON.stringify(result ?? {}));
      }
      if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "text/plain", "method not allowed");
      let m;
      if ((m = /^\/feeds\/([a-z]+)\.xml$/.exec(url.pathname)) && SHOWS[m[1]]) {
        const show = SHOWS[m[1]];
        if (show.private && !url.search.includes("token=fixture-secret-token")) return send(res, 401, "text/plain", "token required");
        return send(res, 200, "application/rss+xml; charset=utf-8", rss(m[1]));
      }
      if ((m = /^\/audio\/([a-z0-9-]+)\.mp3$/.exec(url.pathname)) && AUDIO_SECONDS[m[1]]) {
        return sendFile(req, res, path.join(fixtures, "audio", `${m[1]}.mp3`), "audio/mpeg");
      }
      if ((m = /^\/art\/([a-z]+)\.png$/.exec(url.pathname)) && SHOWS[m[1]]) {
        return sendFile(req, res, path.join(fixtures, "art", `${m[1]}.png`), "image/png");
      }
      if ((m = /^\/chapters\/([a-z0-9-]+)\.json$/.exec(url.pathname))) {
        const episode = Object.keys(SHOWS).flatMap(episodesOf).find((e) => e.guid === m[1]);
        if (!episode?.chapters) return send(res, 404, "text/plain", "no chapters");
        return send(res, 200, "application/json+chapters", JSON.stringify({ version: "1.2.0", chapters: episode.chapters }));
      }
      if (url.pathname === "/itunes/search") return send(res, 200, "application/json", JSON.stringify(search(url)));
      if (url.pathname === "/itunes/lookup") return send(res, 200, "application/json", JSON.stringify(lookup(url)));
      return send(res, 404, "text/plain", "not found");
    } catch (error) {
      const detail = error?.data ? ` ${JSON.stringify(error.data)}` : "";
      return send(res, 500, "text/plain", `${error?.message ?? error}${detail}`);
    }
  });

  async function control(req, res, url) {
    if (url.pathname === "/_control/hits") return send(res, 200, "application/json", JSON.stringify(hits));
    if (req.method !== "POST") return send(res, 405, "text/plain", "POST only");
    const body = await readJson(req);
    if (url.pathname === "/_control/reset") {
      reset();
      return send(res, 200, "application/json", "{}");
    }
    if (url.pathname === "/_control/episodes") {
      return send(res, 200, "application/json", JSON.stringify(addEpisode(showByTitle(body.show).slug, body)));
    }
    return send(res, 404, "text/plain", "unknown control");
  }

  function reset() {
    extra = {};
    hits = [];
  }

  function addEpisode(slug, { title, audio }) {
    const list = (extra[slug] ??= []);
    const episode = {
      guid: `${slug}-new-${list.length + 1}-${Date.now()}`,
      title,
      audio: audio ?? "tone-30s",
      // Newer than anything else in the feed.
      pubDate: Date.now(),
    };
    list.push(episode);
    return episode;
  }

  function feedUrl(slug) {
    return `${base}${SHOWS[slug].path}`;
  }

  function rss(slug) {
    const show = SHOWS[slug];
    const items = episodesOf(slug)
      .map((e) => {
        const pubDate = new Date(e.pubDate ?? startedAt - e.ago).toUTCString();
        const audioUrl = `${base}/audio/${e.audio}.mp3${show.private ? "?token=fixture-secret-token" : ""}`;
        const bytes = statSync(path.join(fixtures, "audio", `${e.audio}.mp3`)).size;
        return `
    <item>
      <title>${esc(e.title)}</title>
      <guid isPermaLink="false">${esc(e.guid)}</guid>
      <pubDate>${pubDate}</pubDate>
      <enclosure url="${esc(audioUrl)}" type="audio/mpeg" length="${bytes}"/>
      <itunes:duration>${AUDIO_SECONDS[e.audio]}</itunes:duration>
      <description><![CDATA[${e.notes ?? `<p>${esc(e.title)}, a ${AUDIO_SECONDS[e.audio]} second tone.</p>`}]]></description>${
        e.chapters ? `\n      <podcast:chapters url="${base}/chapters/${e.guid}.json" type="application/json+chapters"/>` : ""
      }
    </item>`;
      })
      .join("");
    return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
  <channel>
    <title>${esc(show.title)}</title>
    <link>${base}/shows/${slug}</link>
    <description>${esc(show.description)}</description>
    <itunes:author>${esc(show.author)}</itunes:author>
    <itunes:image href="${base}/art/${slug}.png"/>
    <itunes:category text="${esc(show.genre)}"/>
    <language>en</language>${items}
  </channel>
</rss>`;
  }

  function directoryEntry(slug) {
    const show = SHOWS[slug];
    return {
      collectionId: show.appleId,
      collectionName: show.title,
      artistName: show.author,
      artworkUrl600: `${base}/art/${slug}.png`,
      feedUrl: feedUrl(slug),
      primaryGenreName: show.genre,
      trackCount: episodesOf(slug).length,
    };
  }

  function search(url) {
    const term = (url.searchParams.get("term") ?? "").toLowerCase();
    if (url.searchParams.get("entity") === "podcastEpisode") return searchEpisodes(term);
    const results = Object.entries(SHOWS)
      .filter(([, s]) => !s.private && s.appleId)
      .filter(([, s]) => `${s.title} ${s.author} ${s.genre}`.toLowerCase().includes(term))
      .map(([slug]) => directoryEntry(slug));
    return { resultCount: results.length, results };
  }

  // Apple's episode results: the show's fields plus the item's own, matched on the episode title.
  function searchEpisodes(term) {
    const results = Object.entries(SHOWS)
      .filter(([, s]) => !s.private && s.appleId)
      .flatMap(([slug]) =>
        episodesOf(slug)
          .filter((e) => e.title.toLowerCase().includes(term))
          .map((e, i) => ({
            ...directoryEntry(slug),
            trackId: SHOWS[slug].appleId * 100 + i,
            trackName: e.title,
            episodeGuid: e.guid,
            episodeUrl: `${base}/audio/${e.audio}.mp3`,
            releaseDate: new Date(e.pubDate ?? startedAt - e.ago).toISOString(),
            trackTimeMillis: AUDIO_SECONDS[e.audio] * 1000,
          })),
      );
    return { resultCount: results.length, results };
  }

  function lookup(url) {
    const id = Number(url.searchParams.get("id"));
    const results = Object.entries(SHOWS)
      .filter(([, s]) => s.appleId === id)
      .map(([slug]) => directoryEntry(slug));
    return { resultCount: results.length, results };
  }

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () =>
      resolve({
        url: base,
        startedAt,
        feedUrl,
        reset,
        addEpisode,
        setWorld: (handler) => {
          world = handler;
        },
        close: () =>
          new Promise((done) => {
            server.closeAllConnections?.();
            server.close(() => done());
          }),
      }),
    );
  });
}

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function send(res, status, type, body) {
  res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store", "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}

function sendFile(req, res, file, type) {
  const size = statSync(file).size;
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
  if (range) {
    const start = range[1] === "" ? size - Number(range[2]) : Number(range[1]);
    const end = range[1] !== "" && range[2] !== "" ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start > end || start >= size) {
      res.writeHead(416, { "Content-Range": `bytes */${size}` });
      return res.end();
    }
    res.writeHead(206, {
      "Content-Type": type,
      "Accept-Ranges": "bytes",
      "Content-Range": `bytes ${start}-${end}/${size}`,
      "Content-Length": end - start + 1,
    });
    if (req.method === "HEAD") return res.end();
    return createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(200, { "Content-Type": type, "Accept-Ranges": "bytes", "Content-Length": size });
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}

async function readJson(req) {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  return raw ? JSON.parse(raw) : {};
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const port = Number(process.argv[2] ?? 3412);
  const server = await startFixtureServer({ port });
  console.log(`fixture server on ${server.url}`);
}
