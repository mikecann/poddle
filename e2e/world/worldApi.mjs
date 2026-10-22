// The world API: how scenarios arrange and inspect the backend, for both
// harnesses (the Swift steps can't run the Convex client, so everything goes
// over plain HTTP JSON). It's served by the fixture server under /_world/<op>
// and acts through the public functions with the admin path, like the scripts,
// plus convex/testing.ts for what no public function does.
//
// Shows and episodes are named by their fixture titles (shows.mjs), people by
// email. Every op returns JSON; errors come back as 500 with the message.

import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ConvexHttpClient } from "convex/browser";
import { SHOWS, showByTitle } from "./shows.mjs";

export function worldApi({ convexUrl, adminToken, fixtures }) {
  const client = new ConvexHttpClient(convexUrl);
  const admin = (email) => ({ token: adminToken, email });
  const now = () => Date.now();

  async function podcastIdOf(email, title) {
    const shows = await client.query("podcasts:list", { admin: admin(email) });
    const show = shows.find((p) => p.title === title);
    if (show) return show._id;
    // Not in their library: look it up through the directory-style preview.
    const preview = await client.action("feedActions:previewFeed", { admin: admin(email), url: fixtures.feedUrl(showByTitle(title).slug) });
    if (!preview.podcastId) throw new Error(`"${title}" isn't in the catalogue yet`);
    return preview.podcastId;
  }

  async function episodesOf(email, podcastId) {
    const page = await client.query("podcasts:episodes", {
      admin: admin(email),
      podcastId,
      order: "oldestFirst",
      paginationOpts: { numItems: 100, cursor: null },
    });
    return page.page;
  }

  async function episodeByTitle(email, title) {
    const shows = await client.query("podcasts:list", { admin: admin(email) });
    for (const show of shows) {
      const row = (await episodesOf(email, show._id)).find((r) => r.episode.title === title);
      if (row) return row;
    }
    throw new Error(`No episode "${title}" in ${email}'s shows`);
  }

  async function waitFor(what, check, timeoutMs = 20_000) {
    const until = Date.now() + timeoutMs;
    let last;
    while (Date.now() < until) {
      last = await check();
      if (last) return last;
      await new Promise((r) => setTimeout(r, 250));
    }
    throw new Error(`Timed out waiting for ${what}`);
  }

  const upNext = async (email) => (await client.query("queue:upNext", { admin: admin(email) })).map((q) => q.row.episode.title);

  const ops = {
    /** Everything back to nothing: the fixture feeds and every app table. */
    async reset() {
      fixtures.reset();
      for (let i = 0; i < 50; i++) {
        const r = await client.mutation("testing:reset", { token: adminToken });
        if (!r.more) return {};
      }
      throw new Error("reset never finished");
    },

    /** Makes the account (through test sign-in) and returns its session, for the website. */
    async signUp({ email }) {
      const result = await client.mutation("auth:signInForTesting", { email });
      return { tokens: result.tokens };
    },

    /**
     * Subscribes them to a fixture show and waits for its episodes. `upNext`
     * lists which of its episodes end up queued, in order (default: none, so
     * scenarios say exactly what they want queued).
     */
    async follow({ email, show, upNext: queued = [] }) {
      const s = showByTitle(show);
      const podcastId = await client.mutation("podcasts:subscribe", {
        admin: admin(email),
        feedUrl: fixtures.feedUrl(s.slug),
        at: now(),
        title: s.title,
        author: s.author,
        artworkUrl: `${fixtures.url}/art/${s.slug}.png`,
        ...(s.appleId ? { appleId: s.appleId } : {}),
      });
      const rows = await waitFor(`${show}'s episodes`, async () => {
        const r = await episodesOf(email, podcastId);
        return r.length >= s.episodes.length ? r : null;
      });
      // The first fetch queues the newest episode; start from exactly what was asked for.
      await waitFor(`${show}'s first fetch`, async () => (await client.query("podcasts:get", { admin: admin(email), podcastId }))?.feed.lastSuccessAt);
      // It can land a moment after the fetch is recorded, so keep at it until it's been quiet a while.
      for (let quiet = 0, tries = 0; quiet < 4 && tries < 40; tries++) {
        const stray = (await client.query("queue:upNext", { admin: admin(email) })).filter(({ row }) => row.podcast._id === podcastId);
        for (const { row } of stray) await client.mutation("queue:remove", { admin: admin(email), episodeId: row.episode._id, at: now() });
        quiet = stray.length ? 0 : quiet + 1;
        await new Promise((r) => setTimeout(r, 150));
      }
      for (const title of queued) {
        const row = rows.find((r) => r.episode.title === title);
        if (!row) throw new Error(`${show} has no episode "${title}"`);
        await client.mutation("queue:add", { admin: admin(email), episodeId: row.episode._id, position: "bottom", at: now() });
      }
      return { podcastId, episodes: rows.map((r) => ({ id: r.episode._id, title: r.episode.title })) };
    },

    /** Queues episodes (by title) at the bottom, in order. */
    async queue({ email, episodes }) {
      for (const title of episodes) {
        const row = await episodeByTitle(email, title);
        await client.mutation("queue:add", { admin: admin(email), episodeId: row.episode._id, position: "bottom", at: now() });
      }
      return { upNext: await upNext(email) };
    },

    async upNext({ email }) {
      return { upNext: await upNext(email) };
    },

    /** One episode's row: `{ id, podcastId, played, archived, position, inQueue }`. */
    async episode({ email, title }) {
      const row = await episodeByTitle(email, title);
      const queue = await upNext(email);
      return {
        id: row.episode._id,
        podcastId: row.podcast._id,
        played: row.state?.played ?? false,
        archived: row.state?.archived ?? false,
        position: row.state?.position ?? 0,
        inQueue: queue.includes(title),
      };
    },

    /** Every episode of every show in their library: `{ episodes: [{ id, title, show }] }`. */
    async catalog({ email }) {
      const shows = await client.query("podcasts:list", { admin: admin(email) });
      const episodes = [];
      for (const show of shows) {
        for (const row of await episodesOf(email, show._id)) episodes.push({ id: row.episode._id, title: row.episode.title, show: show.title });
      }
      return { episodes };
    },

    /** Their library, by title. */
    async library({ email }) {
      const shows = await client.query("podcasts:list", { admin: admin(email) });
      return { shows: shows.map((p) => p.title) };
    },

    async podcast({ email, show }) {
      const podcastId = await podcastIdOf(email, show);
      const got = await client.query("podcasts:get", { admin: admin(email), podcastId });
      return { id: podcastId, subscribed: got?.podcast.subscribed ?? false, overrides: got?.overrides ?? {}, resolved: got?.resolved ?? {} };
    },

    /** The new-episode rule: "upNextBottom", "upNextTop" or "none". */
    async setNewEpisodes({ email, show, rule }) {
      const podcastId = await podcastIdOf(email, show);
      await client.mutation("settings:updatePodcast", { admin: admin(email), podcastId, patch: { newEpisodes: rule }, at: now() });
      return {};
    },

    async setGlobal({ email, patch }) {
      await client.mutation("settings:updateGlobal", { admin: admin(email), patch, at: now() });
      return {};
    },

    async globalSettings({ email }) {
      return await client.query("settings:getGlobal", { admin: admin(email) });
    },

    /** Saves a listening position, as if they'd stopped there on another device. */
    async setPosition({ email, title, position }) {
      const row = await episodeByTitle(email, title);
      await client.mutation("episodes:updatePosition", {
        admin: admin(email),
        episodeId: row.episode._id,
        position,
        positionUpdatedAt: now(),
        deviceId: "e2e-world",
      });
      return {};
    },

    /** A new episode in a fixture feed, fetched straight away (no 15-minute wait). */
    async publish({ show, title, audio }) {
      const s = showByTitle(show);
      fixtures.addEpisode(s.slug, { title, audio });
      const result = await client.action("testing:refreshFeed", { token: adminToken, feedUrl: fixtures.feedUrl(s.slug) });
      if (result.status !== "updated") throw new Error(`Refreshing ${show} gave ${result.status} ${result.error ?? ""}`);
      return result;
    },

    /** Listening this week and this year, for the stats scenarios. */
    async stats({ email }) {
      return await client.query("stats:summary", { admin: admin(email), period: "week" });
    },

    /** Whether that email still has an account. */
    async user({ email }) {
      try {
        await client.query("podcasts:list", { admin: admin(email) });
        return { exists: true };
      } catch (e) {
        if (String(e?.data?.code ?? e?.message).includes("unknownUser")) return { exists: false };
        throw e;
      }
    },

    /**
     * The made-up Overcast export (e2e/fixtures/overcast-all-data.opml) with this world's
     * addresses and dates filled in, written to e2e/.runtime. Returns its path.
     */
    async overcastExport() {
      const here = path.dirname(fileURLToPath(import.meta.url));
      const day = 86_400_000;
      let text = await readFile(path.join(here, "..", "fixtures", "overcast-all-data.opml"), "utf8");
      text = text.replaceAll("{{FIXTURES}}", fixtures.url);
      // Same publish times as the fixture feeds (shows.mjs), so episodes match up.
      for (const d of [1, 2, 3, 4, 5, 6]) text = text.replaceAll(`{{AGO_${d}D}}`, new Date(fixtures.startedAt - d * day).toISOString());
      const file = path.join(here, "..", ".runtime", "overcast-all-data.opml");
      await writeFile(file, text);
      return { path: file };
    },

    /** Their past shows (unsubscribed, with history), by title. */
    async pastShows({ email }) {
      const shows = await client.query("podcasts:pastShows", { admin: admin(email) });
      return { shows: shows.map((p) => p.title) };
    },

    shows() {
      return { shows: Object.values(SHOWS).map((s) => ({ title: s.title, feedUrl: `${fixtures.url}${s.path}`, private: !!s.private })) };
    },
  };

  return async function handle(op, body) {
    const fn = ops[op];
    if (!fn) throw new Error(`Unknown world op "${op}"`);
    return await fn(body ?? {});
  };
}
