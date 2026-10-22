import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { parseOvercastOpml, upNextPlan } from "../convex/lib/opml";
import { upNextOrder } from "../convex/overcastImport";
import { drain, fixture, mockFetch, podcastViews, setup, type T } from "./helpers";

// overcast-real-shape.opml follows the structure of a real "All data" export
// (made-up shows): three playlists, shows with no `subscribed` attribute,
// RFC 2822 added dates, tracking-redirect enclosures, feeds that only list
// recent episodes, and almost everything played-and-deleted.

const NOW = Date.UTC(2026, 9, 22);

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
  mockFetch({
    "https://feeds.example.com/brief.xml": fixture("brief-feed.xml"),
    "https://feeds.example.com/deep.xml": fixture("deep-feed.xml"),
    "https://feeds.example.com/slow.xml": fixture("slow-feed.xml"),
    "https://feeds.example.com/dead.xml": { status: 404 },
  });
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function runImport(t: T) {
  const batchId = await t.mutation(api.overcastImport.startOvercastImport, {
    opml: fixture("overcast-real-shape.opml"),
    assumedSpeed: 2,
  });
  await drain(t);
  return (await t.query(api.overcastImport.getImport, { batchId }))!;
}

async function upNextTitles(t: T) {
  return (await t.query(api.queue.upNext, {})).map((q) => q.row.episode.title);
}

describe("parsing the real export's shape", () => {
  test("a missing subscribed attribute means unsubscribed", () => {
    const x = parseOvercastOpml(fixture("overcast-real-shape.opml"));
    expect(x.feeds.map((f) => [f.title, f.subscribed, f.notifications])).toEqual([
      ["Morning Brief", true, true],
      ["Deep Dive", true, false],
      ["Slow Show", true, true],
      ["Old Thing", false, true],
    ]);
  });

  test("RFC 2822 added dates and ISO 8601 dates with offsets", () => {
    const [brief, deep] = parseOvercastOpml(fixture("overcast-real-shape.opml")).feeds;
    expect(brief!.addedAt).toBe(Date.UTC(2016, 9, 4, 5, 24, 50));
    expect(deep!.addedAt).toBe(Date.UTC(2016, 1, 18, 10, 3, 11));
    const ep = brief!.episodes[3]!;
    expect(ep.pubDate).toBe(Date.UTC(2026, 9, 19, 10));
    expect(ep.userUpdatedAt).toBe(Date.UTC(2026, 9, 20, 20));
    expect(brief!.episodes[2]!.userRecommendedAt).toBe(Date.UTC(2026, 9, 18, 21, 5));
    // Missing played / userDeleted / progress attributes.
    expect(ep).toMatchObject({ played: false, userDeleted: false, progress: 1949 });
    expect(brief!.episodes[0]).toMatchObject({ played: true, userDeleted: true, progress: undefined });
  });

  test("every playlist and the Up Next plan", () => {
    const { playlists } = parseOvercastOpml(fixture("overcast-real-shape.opml"));
    expect(playlists.map((p) => [p.title, p.smart, p.sorting])).toEqual([
      ["All Episodes", true, "reverse-chronological"],
      ["Essentials", true, "chronological"],
      ["Queue", false, "chronological"],
    ]);
    expect(playlists[0]).toMatchObject({ priorityPodcastIds: [9100001, 9100002], sortedEpisodeIds: [7000000000000201, 7000000000000999] });
    expect(playlists[1]!.includePodcastIds).toEqual([9100001, 9100003, 9100999]);
    expect(playlists[2]!.includeEpisodeIds).toEqual([7000000000000888]);
    expect(upNextPlan(playlists)).toEqual({
      leadingEpisodeIds: [7000000000000888, 7000000000000201, 7000000000000999],
      priorityPodcastIds: [9100001, 9100002],
      newestFirst: true,
    });
  });

  test("Up Next order: hand-placed, then priority shows, then the rest, by the playlist's sort", () => {
    const row = (episodeId: string, podcastId: string, pubDate: number, overcastId?: number) => ({ episodeId, podcastId, pubDate, overcastId });
    const rows = [
      row("e1", "slow", 1),
      row("e2", "prio", 2),
      row("e3", "slow", 5),
      row("e4", "prio", 3, 42),
      row("e5", "prio", 4),
      row("e1", "slow", 1),
    ];
    const plan = { leadingEpisodeIds: [42], priorityPodcastIds: ["prio"], newestFirst: true };
    expect(upNextOrder(rows, plan).map((x) => [x.row.episodeId, x.addedBy])).toEqual([
      ["e4", "manual"],
      ["e5", "priority"],
      ["e2", "priority"],
      ["e3", "auto"],
      ["e1", "auto"],
    ]);
    expect(upNextOrder(rows, { ...plan, newestFirst: false }).map((x) => x.row.episodeId)).toEqual(["e4", "e2", "e5", "e1", "e3"]);
  });
});

describe("importing the real export's shape", () => {
  test("subscriptions, matching, ghosts, sessions, failed feeds and Up Next", async () => {
    const t = setup();
    const batch = await runImport(t);
    expect(batch.status).toBe("done");
    expect(batch.counts).toMatchObject({
      podcasts: 4,
      subscribedPodcasts: 3,
      podcastsProcessed: 4,
      feedsFailed: 1,
      episodes: 12,
      episodesMatched: 7,
      ghostEpisodes: 5,
      ghostsOlderThanFeed: 3,
      ghostsMissingFromFeed: 0,
      ghostsFeedFailed: 2,
      playedEpisodes: 8,
      inProgressEpisodes: 4,
      starredEpisodes: 1,
      sessions: 11,
      estimatedDurationSessions: 5,
      upNextEpisodes: 5,
    });
    // Brief 1 + 2 at Brief's median (1500), Brief 3, Brief 4 (progress), the two
    // Deep crossovers at Deep's median (4500), Deep 1, Deep 2 (progress), Slow 1,
    // Old 1 at the overall median (2200), Old 2 (progress).
    expect(batch.counts.estimatedListenSeconds).toBeCloseTo(
      (1500 + 1500 + 1200 + 1949 + 4500 + 4500 + 3000 + 3445 + 2200 + 2200 + 600) / 2,
      6,
    );
    expect(batch.medianDuration).toBe(2200);
    expect(batch.failedFeeds).toEqual([
      expect.objectContaining({ title: "Old Thing", feedUrl: "https://feeds.example.com/dead.xml", status: 404 }),
    ]);
    expect(batch.playlists.map((p) => [p.title, p.podcastIds.length, p.priorityPodcastIds?.length, p.episodeCount])).toEqual([
      ["All Episodes", 0, 2, 2],
      ["Essentials", 2, 0, 0],
      ["Queue", 0, 0, 1],
    ]);

    const podcasts = await podcastViews(t);
    const db = await t.run(async (ctx) => ({
      podcasts,
      episodes: await ctx.db.query("episodes").collect(),
      states: await ctx.db.query("episodeStates").collect(),
      sessions: await ctx.db.query("listeningSessions").collect(),
      settings: await ctx.db.query("podcastSettings").collect(),
    }));
    const show = (title: string) => db.podcasts.find((p) => p.title === title)!;
    expect(db.podcasts.filter((p) => p.subscribed).map((p) => p.title).sort()).toEqual(["Deep Dive", "Morning Brief", "Slow Show"]);
    const settings = (title: string) => db.settings.find((s) => s.podcastId === show(title)._id);
    expect(settings("Morning Brief")).toMatchObject({ newEpisodes: "upNextTop", notifications: true });
    expect(settings("Deep Dive")).toMatchObject({ newEpisodes: "upNextTop" });
    expect(settings("Slow Show")?.newEpisodes).toBeUndefined();

    const ep = (title: string) => db.episodes.find((e) => e.title === title)!;
    const st = (id: Id<"episodes">) => db.states.find((s) => s.episodeId === id);
    // http vs https, with and without a podtrac redirect: the same file.
    expect(ep("Brief 3: Tracked")).toMatchObject({ isGhost: false, guid: "brief-3" });
    expect(st(ep("Brief 3: Tracked")._id)).toMatchObject({ played: true, starred: true, archived: true });
    expect(ep("Brief 4: Halfway").isGhost).toBe(false);
    expect(ep("Slow 1").isGhost).toBe(false);
    // Matched by its link after a CDN move and a retitle.
    const brief2 = db.episodes.find((e) => e.guid === "brief-2")!;
    expect(st(brief2._id)).toMatchObject({ played: true });
    expect(db.sessions.find((s) => s.episodeId === brief2._id)).toMatchObject({ contentEnd: 1500, isEstimated: true });
    // Re-published with a new date and file: matched by its (unique) title.
    expect(db.episodes.filter((e) => e.title === "Deep 1: Origins")).toHaveLength(1);
    expect(ep("Deep 1: Origins").isGhost).toBe(false);
    // Older than anything the feed lists: a ghost, its session at the show's median.
    expect(ep("Brief 1: Long gone").isGhost).toBe(true);
    expect(db.sessions.find((s) => s.sessionId === "overcast:7000000000000101")).toMatchObject({ contentEnd: 1500 });
    // Two ghosts sharing the show's homepage link and a reused enclosure URL stay separate.
    expect(ep("Presenting: Another Show")._id).not.toBe(ep("Deep x Friends")._id);
    expect(ep("Deep x Friends")).toMatchObject({ isGhost: true });
    // Unsubscribed show: its unplayed episode is archived, not queued.
    expect(st(ep("Old 2")._id)).toMatchObject({ archived: true, position: 600 });
    expect(st(ep("Deep 1.5: Skipped")._id)).toMatchObject({ archived: true, played: false });
    expect(st(ep("Brief 4: Halfway")._id)).toMatchObject({ archived: false, position: 1949 });

    // Nothing in the Inbox; Up Next in "All Episodes" order: its pinned episode,
    // then priority shows newest first, then the rest.
    expect(await t.query(api.episodes.inbox, {})).toEqual([]);
    expect(await upNextTitles(t)).toEqual([
      "Deep 2: In progress",
      "Deep 3: Untouched",
      "Brief 5: Untouched",
      "Brief 4: Halfway",
      "Slow 2: Untouched",
    ]);
  });

  test("re-running doesn't duplicate Up Next or undo his changes", async () => {
    const t = setup();
    await runImport(t);
    const queue = await t.query(api.queue.upNext, {});
    const slow2 = queue.find((q) => q.row.episode.title === "Slow 2: Untouched")!.row.episode;
    const brief5 = queue.find((q) => q.row.episode.title === "Brief 5: Untouched")!.row.episode;
    await t.mutation(api.queue.remove, { episodeId: slow2._id, at: NOW });
    await t.mutation(api.queue.move, { episodeId: brief5._id, afterEpisodeId: null, at: NOW });

    const again = await runImport(t);
    expect(again.counts.upNextEpisodes).toBe(4);
    expect(await upNextTitles(t)).toEqual(["Brief 5: Untouched", "Deep 2: In progress", "Deep 3: Untouched", "Brief 4: Halfway"]);
    const counts = await t.run(async (ctx) => ({
      queue: (await ctx.db.query("queueItems").collect()).length,
      sessions: (await ctx.db.query("listeningSessions").collect()).length,
      episodes: (await ctx.db.query("episodes").collect()).length,
    }));
    expect(counts).toEqual({ queue: 4, sessions: 11, episodes: 15 });
  });

  test("re-running fixes shows an earlier import wrongly subscribed", async () => {
    const t = setup();
    const addedAt = Date.UTC(2016, 9, 4, 5, 30);
    const userId = await t.userId();
    const podcastId = await t.run(async (ctx) => {
      const id = await ctx.db.insert("podcasts", {
        feedUrl: "https://feeds.example.com/dead.xml",
        title: "Old Thing",
        overcastId: 9100004,
        isPrivate: false,
        episodeCount: 0,
        createdAt: 1,
        updatedAt: 1,
      });
      await ctx.db.insert("subscriptions", {
        userId,
        podcastId: id,
        subscribed: true,
        subscribedAt: addedAt,
        subscriptionUpdatedAt: addedAt,
        addedAt: 1,
        updatedAt: 1,
      });
      await ctx.db.insert("libraryEvents", { userId, eventId: `subscribed:${id}:${addedAt}`, type: "subscribed", podcastId: id, at: addedAt, updatedAt: 1 });
      return id;
    });
    const batch = await runImport(t);
    expect(batch.counts.subscribedPodcasts).toBe(3);
    const views = await podcastViews(t);
    const after = await t.run(async (ctx) => ({
      podcast: views.find((p) => p._id === podcastId)!,
      events: await ctx.db.query("libraryEvents").collect(),
      feedState: await ctx.db
        .query("feedStates")
        .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
        .unique(),
    }));
    expect(after.podcast).toMatchObject({ subscribed: false, subscribedAt: addedAt });
    expect(after.events.filter((e) => e.podcastId === podcastId && e.type === "subscribed")).toEqual([]);
    expect(after.feedState?.active).toBe(false);
  });

  test("a show he's re-subscribed to in Poddle stays subscribed", async () => {
    const t = setup();
    const userId = await t.userId();
    await t.run(async (ctx) => {
      const podcastId = await ctx.db.insert("podcasts", {
        feedUrl: "https://feeds.example.com/dead.xml",
        title: "Old Thing",
        overcastId: 9100004,
        isPrivate: false,
        episodeCount: 0,
        createdAt: 1,
        updatedAt: 1,
      });
      await ctx.db.insert("subscriptions", { userId, podcastId, subscribed: true, subscriptionUpdatedAt: NOW - 1000, addedAt: 1, updatedAt: 1 });
    });
    const batch = await runImport(t);
    expect(batch.counts.subscribedPodcasts).toBe(3);
    const old = (await podcastViews(t)).find((p) => p.overcastId === 9100004);
    expect(old?.subscribed).toBe(true);
  });
});
