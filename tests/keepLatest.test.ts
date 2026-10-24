import { describe, expect, test } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { setup, type T } from "./helpers";
import { BASE, seedShow } from "./seed";

// "Keep latest N" limits Up Next too, like Overcast's episode limit (decisions.md, 25 Oct 2026).

const DAY = 86_400_000;

/** A show with episodes "Ep 0" (oldest) … "Ep n-1", all of them in Up Next in that order. */
async function queuedShow(t: T, n: number, title = "Show") {
  const { podcastId, episodeIds } = await seedShow(t, n, { title });
  for (const [i, episodeId] of episodeIds.entries()) {
    await t.mutation(api.queue.add, { episodeId, position: "bottom", at: BASE + i });
  }
  return { podcastId, episodeIds };
}

/** The feed poller finding a new episode, published a day after the show's newest. */
async function publish(t: T, podcastId: Id<"podcasts">, n: number, title = "Show") {
  await t.raw.mutation(internal.feeds.ingestEpisodes, {
    podcastId,
    mode: "normal",
    isFirstChunk: true,
    previousLatestAt: BASE + (n - 1) * DAY,
    episodes: [
      {
        guid: `${title}-${n}`,
        enclosureUrl: `https://cdn.example.com/${title}/${n}.mp3`,
        title: `Ep ${n}`,
        pubDate: BASE + n * DAY,
        transcripts: [],
      },
    ],
  });
}

async function upNext(t: T) {
  return (await t.query(api.queue.upNext, {})).map((r) => r.row.episode.title);
}
async function upNextWithShows(t: T) {
  return (await t.query(api.queue.upNext, {})).map((r) => `${r.row.podcast.title} ${r.row.episode.title}`);
}

const keep = (t: T, podcastId: Id<"podcasts">, value: number | "all" | null, at = BASE + 100) =>
  t.mutation(api.settings.updatePodcast, { podcastId, patch: { keepLatestDownloaded: value }, at });

describe("a new episode", () => {
  test("takes the show's older episodes beyond its Keep latest out of Up Next", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await queuedShow(t, 4);
    await t.mutation(api.queue.remove, { episodeId: episodeIds[0]!, at: BASE + 50 });
    await t.mutation(api.queue.add, { episodeId: episodeIds[0]!, position: "bottom", at: BASE + 51 });
    // Up Next is Ep 1 (playing), Ep 2, Ep 3, Ep 0. Setting it trims the oldest straight away.
    await keep(t, podcastId, 2);
    expect(await upNext(t)).toEqual(["Ep 1", "Ep 2", "Ep 3"]);

    await publish(t, podcastId, 4);
    expect(await upNext(t)).toEqual(["Ep 1", "Ep 3", "Ep 4"]);

    // Removed, the normal way: not played, not archived, still on the show's page.
    const page = await t.query(api.podcasts.episodes, { podcastId, paginationOpts: { cursor: null, numItems: 10 } });
    expect(page.page.map((r) => r.episode.title)).toEqual(expect.arrayContaining(["Ep 0", "Ep 2"]));
    for (const r of page.page) expect(r.state?.played ?? false).toBe(false);
    for (const r of page.page) expect(r.state?.archived ?? false).toBe(false);
  });

  test("never takes out one that's been started, or the first in Up Next", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await queuedShow(t, 4);
    await t.mutation(api.episodes.updatePosition, { episodeId: episodeIds[1]!, position: 120, positionUpdatedAt: BASE, deviceId: "phone" });
    await t.mutation(api.settings.updateGlobal, { patch: { keepLatest: 1 }, at: BASE + 100 });
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 3"]);

    await publish(t, podcastId, 4);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 4"]);
  });

  test("never takes out a starred one", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await queuedShow(t, 4);
    await t.mutation(api.episodes.setStarredState, { episodeId: episodeIds[1]!, starred: true, at: BASE });
    await keep(t, podcastId, 1);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 3"]);
  });

  test("a priority show keeps its newest in the second slot and loses the older ones", async () => {
    const t = setup();
    const { podcastId } = await queuedShow(t, 3);
    await t.mutation(api.settings.updatePodcast, { podcastId, patch: { newEpisodes: "upNextTop", keepLatestDownloaded: 1 }, at: BASE + 100 });
    await publish(t, podcastId, 3);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 3"]);
  });

  test("only trims the show it came from", async () => {
    const t = setup();
    const a = await queuedShow(t, 3, "A");
    await queuedShow(t, 3, "B");
    await t.mutation(api.settings.updateGlobal, { patch: { keepLatest: 5 }, at: BASE + 99 });
    await keep(t, a.podcastId, 1);
    await publish(t, a.podcastId, 3, "A");
    expect(await upNextWithShows(t)).toEqual(["A Ep 0", "B Ep 0", "B Ep 1", "B Ep 2", "A Ep 3"]);
  });

  test("a retried add from before the trim doesn't bring the episode back", async () => {
    const t = setup();
    await queuedShow(t, 1, "B");
    const { podcastId, episodeIds } = await seedShow(t, 3, { title: "A" });
    await keep(t, podcastId, 1);
    // Added by hand moments ago, so its add is newer than the poller's system time.
    const addedAt = Date.now();
    await t.mutation(api.queue.add, { episodeId: episodeIds[0]!, position: "bottom", at: addedAt });
    await publish(t, podcastId, 3, "A");
    expect(await upNextWithShows(t)).toEqual(["B Ep 0", "A Ep 3"]);
    // The phone never heard back about the add and sends it again: the trim still wins.
    expect(await t.mutation(api.queue.add, { episodeId: episodeIds[0]!, position: "bottom", at: addedAt })).toBe(false);
    expect(await upNextWithShows(t)).toEqual(["B Ep 0", "A Ep 3"]);
  });
});

describe("All", () => {
  test("is the default, and never takes anything out", async () => {
    const t = setup();
    const { podcastId } = await queuedShow(t, 4);
    expect((await t.query(api.settings.getGlobal, {})).keepLatest).toBe("all");
    expect((await t.query(api.settings.resolved, { podcastId })).keepLatestDownloaded).toBe("all");
    await publish(t, podcastId, 4);
    await publish(t, podcastId, 5);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 2", "Ep 3", "Ep 4", "Ep 5"]);
  });

  test("on a show beats a numeric default", async () => {
    const t = setup();
    const { podcastId } = await queuedShow(t, 3);
    await keep(t, podcastId, "all", BASE + 99);
    await t.mutation(api.settings.updateGlobal, { patch: { keepLatest: 1 }, at: BASE + 100 });
    await publish(t, podcastId, 3);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 2", "Ep 3"]);
    const r = await t.query(api.settings.forPodcast, { podcastId });
    expect(r.overrides.keepLatestDownloaded).toBe("all");
    expect(r.resolved.inherited).not.toContain("keepLatestDownloaded");
  });
});

describe("changing the setting", () => {
  test("trims the show's Up Next straight away", async () => {
    const t = setup();
    const { podcastId } = await queuedShow(t, 4);
    expect(await keep(t, podcastId, 1)).toEqual(["keepLatestDownloaded"]);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 3"]);

    // Back to "use default" (All): nothing more goes, and nothing comes back.
    await keep(t, podcastId, null, BASE + 200);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 3"]);
  });

  test("a number from an old app, which only knew it as downloads, limits Up Next too", async () => {
    const t = setup();
    const { podcastId } = await queuedShow(t, 4);
    // Exactly what 1.0.0 sends from its show settings stepper.
    await t.mutation(api.settings.updatePodcast, { podcastId, patch: { keepLatestDownloaded: 2 }, at: BASE + 100 });
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 2", "Ep 3"]);
  });

  test("a stale change replayed from an offline phone leaves what was queued after it", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await queuedShow(t, 4);
    await t.mutation(api.queue.move, { episodeId: episodeIds[1]!, afterEpisodeId: episodeIds[3]!, at: BASE + 300 });
    await keep(t, podcastId, 1, BASE + 200);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 3", "Ep 1"]);
  });

  test("a new default trims every show that follows it, and not the ones with their own", async () => {
    const t = setup();
    await queuedShow(t, 3, "A");
    const b = await queuedShow(t, 3, "B");
    await keep(t, b.podcastId, 3, BASE + 99);
    await t.mutation(api.settings.updateGlobal, { patch: { keepLatest: 1 }, at: BASE + 100 });
    expect(await upNextWithShows(t)).toEqual(["A Ep 0", "A Ep 2", "B Ep 0", "B Ep 1", "B Ep 2"]);
  });
});

describe("existing people", () => {
  test("a stored global 3 from before (download count only) doesn't trim anything", async () => {
    const t = setup();
    const userId = await t.userId();
    // What an old app's Settings stepper left: the global row's own keepLatestDownloaded.
    await t.run(async (ctx) => {
      await ctx.db.insert("globalSettings", { userId, keepLatestDownloaded: 3, fieldTimes: { keepLatestDownloaded: 1 }, updatedAt: 1 });
    });
    const { podcastId } = await queuedShow(t, 5);
    await publish(t, podcastId, 5);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 2", "Ep 3", "Ep 4", "Ep 5"]);

    // Old apps still read their number; the default for shows is All.
    const g = await t.query(api.settings.getGlobal, {});
    expect(g).toMatchObject({ keepLatestDownloaded: 3, keepLatest: "all" });
    expect((await t.query(api.settings.resolved, { podcastId })).keepLatestDownloaded).toBe("all");
  });

  test("an old app changing its global Keep latest only changes its own download count", async () => {
    const t = setup();
    const { podcastId } = await queuedShow(t, 4);
    await t.mutation(api.settings.updateGlobal, { patch: { keepLatestDownloaded: 1 }, at: BASE + 100 });
    await publish(t, podcastId, 4);
    expect(await upNext(t)).toEqual(["Ep 0", "Ep 1", "Ep 2", "Ep 3", "Ep 4"]);
    expect(await t.query(api.settings.getGlobal, {})).toMatchObject({ keepLatestDownloaded: 1, keepLatest: "all" });
  });
});
