import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { drain, fixture, mockFetch, setup, type T } from "./helpers";

// Two people with overlapping subscriptions never see each other's state,
// queue, sessions, stats or settings, through any query or sync:changes.

const FEED = "https://feeds.example.com/odd.xml";
const NOW = Date.UTC(2025, 9, 15, 0, 0);
const newItem = (n: number, date: string) => `
    <item>
      <title>Episode ${n}: Fresh</title>
      <guid>odd-ep-${n}</guid>
      <pubDate>${date}</pubDate>
      <enclosure url="https://cdn.example.com/odd/ep${n}.mp3" type="audio/mpeg"/>
      <itunes:duration>600</itunes:duration>
    </item>`;
const withNewItems = (...items: string[]) => fixture("odd-feed.xml").replace("<item>", items.join("") + "\n    <item>");

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function syncAll(t: T, table: string) {
  const out: Record<string, unknown>[] = [];
  let cursor: string | null = null;
  for (;;) {
    const r: { page: unknown[]; isDone: boolean; continueCursor: string } = await t.query(api.sync.changes, {
      table: table as "podcasts",
      since: 0,
      paginationOpts: { cursor, numItems: 50 },
    });
    out.push(...(r.page as Record<string, unknown>[]));
    if (r.isDone) return out;
    cursor = r.continueCursor;
  }
}

const PERSONAL = [
  "episodeStates",
  "queueItems",
  "podcastSettings",
  "globalSettings",
  "listeningSessions",
  "libraryEvents",
  "devices",
  "importBatches",
  "deletions",
];

/** Mike and Ana both subscribe to the same feed; Ana also has a show of her own. */
async function twoListeners() {
  const mike = setup();
  const ana = mike.as("ana@example.com");
  mockFetch({ [FEED]: fixture("odd-feed.xml") });
  const podcastId = await mike.mutation(api.podcasts.subscribe, { feedUrl: FEED, at: NOW });
  await drain(mike);
  expect(await ana.mutation(api.podcasts.subscribe, { feedUrl: FEED, at: NOW })).toBe(podcastId);
  await drain(mike);
  const page = await mike.query(api.podcasts.episodes, { podcastId, paginationOpts: { cursor: null, numItems: 50 } });
  const episodeIds = page.page.map((r) => r.episode._id);
  return { mike, ana, podcastId, episodeIds };
}

describe("isolation", () => {
  test("one show row, a subscription each, and the newest episode for both", async () => {
    const { mike, ana, podcastId } = await twoListeners();
    const shows = await mike.run(async (ctx) => await ctx.db.query("podcasts").collect());
    expect(shows).toHaveLength(1);
    for (const who of [mike, ana]) {
      expect((await who.query(api.podcasts.list, {})).map((p) => p._id)).toEqual([podcastId]);
      expect((await who.query(api.episodes.inbox, {})).map((r) => r.episode.title)).toEqual(["Episode 4: Chapters & Transcripts"]);
    }
    // Ana unsubscribing doesn't touch Mike, and polling carries on for him.
    await ana.mutation(api.podcasts.unsubscribe, { podcastId, at: NOW + 1 });
    expect(await ana.query(api.podcasts.list, {})).toEqual([]);
    expect(await mike.query(api.podcasts.list, {})).toHaveLength(1);
    const feed = await mike.run(async (ctx) =>
      ctx.db
        .query("feedStates")
        .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
        .unique(),
    );
    expect(feed?.active).toBe(true);
    await mike.mutation(api.podcasts.unsubscribe, { podcastId, at: NOW + 2 });
    const after = await mike.run(async (ctx) =>
      ctx.db
        .query("feedStates")
        .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
        .unique(),
    );
    expect(after?.active).toBe(false);
  });

  test("state, queue, sessions, stats, settings and devices stay with their owner", async () => {
    const { mike, ana, podcastId, episodeIds } = await twoListeners();
    const [e1, e2, e3] = episodeIds as [Id<"episodes">, Id<"episodes">, Id<"episodes">];

    // Mike does a lot.
    await mike.mutation(api.queue.add, { episodeId: e1, position: "bottom", at: NOW });
    await mike.mutation(api.queue.add, { episodeId: e2, position: "bottom", at: NOW });
    await mike.mutation(api.queue.remove, { episodeId: e2, at: NOW + 1 });
    await mike.mutation(api.episodes.setStarredState, { episodeId: e3, starred: true, at: NOW });
    await mike.mutation(api.episodes.updatePosition, { episodeId: e1, position: 120, positionUpdatedAt: NOW, deviceId: "mike-phone" });
    await mike.mutation(api.settings.updateGlobal, { patch: { skipBackSeconds: 5 }, at: NOW });
    await mike.mutation(api.settings.updatePodcast, { podcastId, patch: { playbackSpeed: 2 }, at: NOW });
    await mike.mutation(api.podcasts.setPrivate, { podcastId, isPrivate: true });
    await mike.mutation(api.sessions.record, {
      sessions: [
        {
          sessionId: "mike-1",
          episodeId: e1,
          startedAt: NOW - 3600_000,
          endedAt: NOW - 1800_000,
          contentStart: 0,
          contentEnd: 2700,
          rate: 1.5,
          smartSpeed: true,
          smartRemovedContent: 0,
          voiceBoost: false,
          utcOffsetMinutes: 660,
        },
      ],
    });
    await mike.mutation(api.devices.register, { deviceId: "mike-phone", name: "Mike's iPhone", platform: "iOS", apnsToken: "aa11" });

    // Ana sees none of it.
    expect(await ana.query(api.queue.upNext, {})).toEqual([]);
    expect(await ana.query(api.episodes.starred, {})).toEqual([]);
    // e1 is the newest episode, in Ana's own Inbox: her state, not Mike's position.
    const anaE1 = await ana.query(api.episodes.get, { episodeId: e1 });
    expect(anaE1?.row.state).toMatchObject({ userId: await ana.userId(), position: 0, inInbox: true });
    expect((await ana.query(api.episodes.get, { episodeId: e3 }))?.row.state).toBeNull();
    expect(anaE1?.inQueue).toBe(false);
    expect((await ana.query(api.settings.getGlobal, {})).skipBackSeconds).toBe(15);
    expect((await ana.query(api.settings.forPodcast, { podcastId })).overrides).toEqual({});
    expect((await ana.query(api.podcasts.get, { podcastId }))?.podcast.isPrivate).toBe(false);
    expect((await mike.query(api.podcasts.get, { podcastId }))?.podcast.isPrivate).toBe(true);
    const anaStats = await ana.query(api.stats.summary, { period: "all" });
    expect(anaStats.totals.sessions).toBe(0);
    expect(anaStats.topShows).toEqual([]);
    expect((await ana.query(api.stats.forPodcast, { podcastId })).sessions).toBe(0);
    expect(await ana.query(api.devices.list, {})).toEqual([]);

    // Mike sees his.
    expect((await mike.query(api.queue.upNext, {})).map((r) => r.item.episodeId)).toEqual([e1]);
    expect((await mike.query(api.stats.summary, { period: "all" })).totals.sessions).toBe(1);
    expect(await mike.query(api.devices.list, {})).toHaveLength(1);

    // sync:changes: Ana's personal tables hold only her own rows (her Inbox entry,
    // her subscribe event and settings), never Mike's.
    const anaId = await ana.userId();
    const mikeId = await mike.userId();
    for (const table of PERSONAL) {
      const rows = await syncAll(ana, table);
      for (const row of rows) expect(row.userId).toBe(anaId);
      const mine = await syncAll(mike, table);
      for (const row of mine) expect(row.userId).toBe(mikeId);
    }
    expect(await syncAll(ana, "queueItems")).toEqual([]);
    expect(await syncAll(ana, "listeningSessions")).toEqual([]);
    expect(await syncAll(ana, "deletions")).toEqual([]);
    expect(await syncAll(mike, "queueItems")).toHaveLength(1);
    expect(await syncAll(mike, "deletions")).toHaveLength(1);
    // Both get the shared show and its episodes, with their own subscription merged in.
    const anaShows = await syncAll(ana, "podcasts");
    expect(anaShows).toHaveLength(1);
    expect(anaShows[0]).toMatchObject({ _id: podcastId, subscribed: true, isPrivate: false });
    expect(await syncAll(ana, "episodes")).toHaveLength(4);
  });

  test("a show only one of them has stays out of the other's sync", async () => {
    const { mike, ana } = await twoListeners();
    const other = "https://feeds.example.com/other.xml";
    mockFetch({ [other]: fixture("odd-feed.xml").replaceAll("odd-ep-", "other-ep-").replaceAll("/odd/", "/other/") });
    const otherId = await ana.mutation(api.podcasts.subscribe, { feedUrl: other, at: NOW });
    await drain(ana);
    expect((await syncAll(ana, "podcasts")).map((p) => p._id)).toContain(otherId);
    expect((await syncAll(mike, "podcasts")).map((p) => p._id)).not.toContain(otherId);
    expect(await syncAll(mike, "episodes")).toHaveLength(4);
    expect(await syncAll(ana, "episodes")).toHaveLength(8);
    // Search results only call it "in your library" for the person who has it.
    const matches = await mike.run(async (ctx) =>
      ctx.runQuery(internal.directoryCache.libraryMatches, { userId: await mike.userId(), feedUrls: [other] }),
    );
    expect(matches).toEqual([]);
  });

  test("a show joining the library later sends its whole back catalogue on the next catch-up", async () => {
    const { mike } = await twoListeners();
    const cursor = (await mike.query(api.sync.changes, { table: "episodes", since: 0, paginationOpts: { cursor: null, numItems: 100 } }))
      .maxUpdatedAt!;
    vi.setSystemTime(NOW + 3600_000);
    const other = "https://feeds.example.com/other.xml";
    mockFetch({ [other]: fixture("odd-feed.xml").replaceAll("odd-ep-", "other-ep-").replaceAll("/odd/", "/other/") });
    // Ana adds the show first, so its episodes are old by the time Mike gets it.
    const ana = mike.as("ana@example.com");
    await ana.mutation(api.podcasts.subscribe, { feedUrl: other, at: NOW });
    await drain(mike);
    vi.setSystemTime(NOW + 7200_000);
    await mike.mutation(api.podcasts.subscribe, { feedUrl: other, at: NOW + 7200_000 });
    const later = await mike.query(api.sync.changes, {
      table: "episodes",
      since: cursor + 3600_000 + 60_000,
      paginationOpts: { cursor: null, numItems: 100 },
    });
    expect(later.page).toHaveLength(4);
  });

  test("new episodes follow each subscriber's own rule and alert only their devices", async () => {
    const { mike, ana, podcastId } = await twoListeners();
    await mike.mutation(api.settings.updatePodcast, { podcastId, patch: { newEpisodes: "upNextBottom", notifications: true }, at: NOW });
    await mike.mutation(api.devices.register, { deviceId: "mike-phone", name: "iPhone", platform: "iOS", apnsToken: "aa11" });
    await ana.mutation(api.devices.register, { deviceId: "ana-phone", name: "iPhone", platform: "iOS", apnsToken: "bb22" });

    mockFetch({ [FEED]: withNewItems(newItem(5, "Wed, 15 Oct 2025 00:00:00 GMT")) });
    const r = await mike.action(api.feedActions.refreshNow, { podcastId });
    expect(r.result).toMatchObject({ status: "updated", newEpisodes: 1 });

    expect((await mike.query(api.queue.upNext, {})).map((x) => x.row.episode.title)).toEqual(["Episode 5: Fresh"]);
    expect((await mike.query(api.episodes.inbox, {})).map((x) => x.episode.title)).not.toContain("Episode 5: Fresh");
    expect((await ana.query(api.episodes.inbox, {})).map((x) => x.episode.title)).toContain("Episode 5: Fresh");
    expect(await ana.query(api.queue.upNext, {})).toEqual([]);

    // Only Mike asked for alerts, so only his devices are targeted.
    const scheduled = await mike.run(async (ctx) => await ctx.db.system.query("_scheduled_functions").collect());
    const alerts = scheduled.filter((s) => s.name.includes("sendNewEpisodeAlert"));
    expect(alerts).toHaveLength(1);
    expect((alerts[0]!.args[0] as { userId: string }).userId).toBe(await mike.userId());
    const targets = await mike.run(async (ctx) => ctx.runQuery(internal.devices.pushTargets, { userId: await mike.userId() }));
    expect(targets.map((x) => x.token)).toEqual(["aa11"]);
  });

  test("a phone moves to whoever signs in on it, push token and all", async () => {
    const { mike, ana } = await twoListeners();
    await mike.mutation(api.devices.register, { deviceId: "shared-ipad", name: "iPad", platform: "iOS", apnsToken: "cc33" });
    await ana.mutation(api.devices.register, { deviceId: "shared-ipad", name: "iPad", platform: "iOS", apnsToken: "cc33" });
    const mikeTargets = await mike.run(async (ctx) => ctx.runQuery(internal.devices.pushTargets, { userId: await mike.userId() }));
    const anaTargets = await mike.run(async (ctx) => ctx.runQuery(internal.devices.pushTargets, { userId: await ana.userId() }));
    expect(mikeTargets).toEqual([]);
    expect(anaTargets.map((x) => x.token)).toEqual(["cc33"]);
  });

  test("an import goes into the library of whoever started it", async () => {
    const { mike, ana } = await twoListeners();
    const batchId = await ana.mutation(api.overcastImport.startOvercastImport, { opml: "<opml/>", assumedSpeed: 2 });
    expect(await mike.query(api.overcastImport.getImport, { batchId })).toBeNull();
    expect(await mike.query(api.overcastImport.latestImport, {})).toBeNull();
    expect((await ana.query(api.overcastImport.getImport, { batchId }))?._id).toBe(batchId);
  });
});
