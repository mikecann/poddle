import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { PERSONAL_TABLES } from "../convex/migrations";
import { drain, MIKE, setup, type T } from "./helpers";

// The accounts migration against data shaped like prod's before accounts:
// subscription fields on the shared podcasts, and personal rows with no owner.

const NOW = Date.UTC(2026, 9, 22);

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});
afterEach(() => vi.useRealTimers());

/** Single-user era data, written straight to the tables like the old code did. */
async function seedLegacy(t: T) {
  return await t.run(async (ctx) => {
    const show = (title: string, subscribed: boolean, isPrivate = false) =>
      ctx.db.insert("podcasts", {
        feedUrl: `https://feeds.example.com/${title}.xml`,
        title,
        isPrivate,
        subscribed,
        subscribedAt: NOW - 1000,
        unsubscribedAt: subscribed ? undefined : NOW - 500,
        subscriptionUpdatedAt: NOW - 400,
        episodeCount: 1,
        createdAt: 1,
        updatedAt: 1,
      });
    const a = await show("alpha", true);
    const b = await show("bravo", false, true);
    const episode = (podcastId: Id<"podcasts">, n: number) =>
      ctx.db.insert("episodes", {
        podcastId,
        title: `Ep ${n}`,
        guid: `g${n}`,
        enclosureUrl: `https://cdn.example.com/${n}.mp3`,
        pubDate: NOW - n * 86_400_000,
        duration: 1800,
        transcripts: [],
        isGhost: false,
        firstSeenAt: 1,
        updatedAt: 1,
      });
    const e1 = await episode(a, 1);
    const e2 = await episode(b, 2);
    const state = {
      position: 0,
      positionUpdatedAt: 0,
      played: false,
      playedUpdatedAt: 0,
      starred: false,
      starredUpdatedAt: 0,
      archived: false,
      archivedUpdatedAt: 0,
      inInbox: false,
      inboxUpdatedAt: 0,
      updatedAt: 1,
    };
    await ctx.db.insert("episodeStates", { ...state, episodeId: e1, podcastId: a, inInbox: true, inboxAt: NOW });
    await ctx.db.insert("episodeStates", { ...state, episodeId: e2, podcastId: b, played: true, playedAt: NOW });
    await ctx.db.insert("queueItems", { episodeId: e2, podcastId: b, orderKey: "a0", addedAt: 1, addedBy: "manual", orderUpdatedAt: 1, updatedAt: 1 });
    await ctx.db.insert("deletions", { table: "queueItems", docId: "", episodeId: e1, deletedAt: 1, updatedAt: NOW });
    await ctx.db.insert("podcastSettings", { podcastId: a, playbackSpeed: 2, fieldTimes: { playbackSpeed: 1 }, updatedAt: 1 });
    await ctx.db.insert("globalSettings", { skipBackSeconds: 10, fieldTimes: { skipBackSeconds: 1 }, updatedAt: 1 });
    await ctx.db.insert("listeningSessions", {
      sessionId: "s1",
      episodeId: e2,
      podcastId: b,
      startedAt: NOW - 3600_000,
      endedAt: NOW - 1800_000,
      contentStart: 0,
      contentEnd: 1800,
      rate: 1,
      smartSpeed: false,
      smartRemovedContent: 0,
      voiceBoost: false,
      source: "live",
      isEstimated: false,
      utcOffsetMinutes: 480,
      updatedAt: 1,
    });
    await ctx.db.insert("libraryEvents", { eventId: "e", type: "subscribed", podcastId: a, at: 1, updatedAt: 1 });
    await ctx.db.insert("devices", { deviceId: "phone", name: "iPhone", platform: "iOS", apnsToken: "aa", lastSeenAt: 1, updatedAt: 1 });
    await ctx.db.insert("importBatches", {
      source: "overcast",
      status: "done",
      assumedSpeed: 2,
      startedAt: 1,
      counts: {
        podcasts: 0, subscribedPodcasts: 0, podcastsProcessed: 0, feedsFailed: 0, episodes: 0, episodesMatched: 0,
        ghostEpisodes: 0, playedEpisodes: 0, inProgressEpisodes: 0, starredEpisodes: 0, sessions: 0, estimatedListenSeconds: 0,
      },
      playlists: [],
      updatedAt: 1,
    });
    const rollup = { wall: 1800, content: 1800, speedSaved: 0, smartSaved: 0, sessions: 1 };
    const totals = { ...rollup, rateContent: 1800, estimatedWall: 0, episodesStarted: 1, episodesCompleted: 1 };
    await ctx.db.insert("statsDays", { day: "2026-10-21", ...totals, liveHours: new Array(24).fill(0) });
    await ctx.db.insert("statsMonths", { month: "2026-10", ...totals, heatmap: new Array(168).fill(0) });
    await ctx.db.insert("statsShowDays", { day: "2026-10-21", podcastId: b, ...rollup });
    await ctx.db.insert("statsShowMonths", { month: "2026-10", podcastId: b, ...rollup });
    await ctx.db.insert("episodeTotals", { episodeId: e2, podcastId: b, wall: 1800, content: 1800, sessions: 1 });
    return { a, b, e1, e2 };
  });
}

async function report(t: T) {
  return await t.raw.action(internal.migrations.report, {});
}

describe("accounts migration", () => {
  test("gives Mike every personal row and moves subscriptions off the shared shows, idempotently", async () => {
    // A fresh deployment with no users yet: run as the raw test deployment.
    const t = setup();
    const { a, b, e1 } = await seedLegacy(t);

    const before = await report(t);
    expect(before.users).toEqual({ total: 0, unowned: 0, legacy: 0 });
    expect(before.podcasts).toEqual({ total: 2, unowned: 0, legacy: 2 });
    for (const table of PERSONAL_TABLES) expect(before[table]!.unowned, table).toBe(before[table]!.total);

    const ownerId = await t.raw.mutation(internal.migrations.run, {});
    await drain(t);

    const after = await report(t);
    expect(after.users!.total).toBe(1);
    expect(after.podcasts).toEqual({ total: 2, unowned: 0, legacy: 0 });
    expect(after.subscriptions).toEqual({ total: 2, unowned: 0, legacy: 0 });
    for (const table of PERSONAL_TABLES) {
      expect(after[table]!.unowned, table).toBe(0);
      expect(after[table]!.total, table).toBe(before[table]!.total);
    }

    // Running it again changes nothing.
    expect(await t.raw.mutation(internal.migrations.run, {})).toBe(ownerId);
    await drain(t);
    expect(await report(t)).toEqual(after);

    // Signed in as him (the same email), everything is where it was.
    expect(await t.userId()).toBe(ownerId);
    const mike = t;
    expect((await mike.query(api.users.me, {}))?.email).toBe(MIKE);
    expect((await mike.query(api.podcasts.list, {})).map((p) => p.title)).toEqual(["alpha"]);
    expect((await mike.query(api.podcasts.pastShows, {})).map((p) => [p.title, p.isPrivate, p.unsubscribedAt])).toEqual([
      ["bravo", true, NOW - 500],
    ]);
    expect((await mike.query(api.episodes.inbox, {})).map((r) => r.episode._id)).toEqual([e1]);
    expect((await mike.query(api.queue.upNext, {})).map((r) => r.item.podcastId)).toEqual([b]);
    expect((await mike.query(api.settings.getGlobal, {})).skipBackSeconds).toBe(10);
    expect((await mike.query(api.settings.forPodcast, { podcastId: a })).overrides).toEqual({ playbackSpeed: 2 });
    const stats = await mike.query(api.stats.summary, { period: "month", anchorDay: "2026-10-21" });
    expect(stats.totals.sessions).toBe(1);
    expect(stats.topShows.map((s) => s.podcast.title)).toEqual(["bravo"]);
    expect(await mike.query(api.devices.list, {})).toHaveLength(1);
    expect(await mike.query(api.overcastImport.latestImport, {})).not.toBeNull();
    const synced = await mike.query(api.sync.changes, { table: "podcasts", since: 0, paginationOpts: { cursor: null, numItems: 10 } });
    expect(synced.page.map((p) => (p as { subscribed: boolean }).subscribed).sort()).toEqual([false, true]);

    // Someone else signing in afterwards starts empty.
    const ana = t.as("ana@example.com");
    expect(await ana.query(api.podcasts.list, {})).toEqual([]);
    expect(await ana.query(api.queue.upNext, {})).toEqual([]);
    expect((await ana.query(api.stats.summary, { period: "all" })).totals.sessions).toBe(0);
  });
});
