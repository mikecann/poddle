import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { countsAsListened, parseOvercastOpml } from "../convex/lib/opml";
import { drain, fixture, mockFetch, podcastViews, setup, type T } from "./helpers";

const NOW = Date.UTC(2025, 9, 15);

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
  mockFetch({
    "https://feeds.example.com/techtalk.xml": fixture("techtalk-feed.xml"),
    "https://feeds.example.com/oldfav.xml": fixture("oldfav-feed.xml"),
    "https://feeds.example.com/dead.xml": { status: 404 },
  });
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("parseOvercastOpml", () => {
  test("feeds, episodes and playlists from the extended export", () => {
    const x = parseOvercastOpml(fixture("overcast-all-data.opml"));
    expect(x.hasEpisodeData).toBe(true);
    expect(x.feeds.map((f) => [f.overcastId, f.subscribed, f.notifications, f.episodes.length])).toEqual([
      [101, true, true, 6],
      [202, false, false, 1],
      [303, true, false, 1],
    ]);
    expect(x.feeds[0]!.addedAt).toBe(Date.parse("2023-03-04T09:15:00-05:00"));
    const ep = x.feeds[0]!.episodes[0]!;
    expect(ep).toMatchObject({ overcastId: 1001, played: true, userDeleted: true, enclosureUrl: "https://cdn.example.com/ttw/1.mp3" });
    expect(x.feeds[0]!.episodes[2]!.userRecommendedAt).toBe(Date.parse("2025-09-16T21:50:00+10:00"));
    expect(x.feeds[0]!.episodes[2]!.pubDate).toBe(Date.UTC(2025, 8, 15, 14));
    expect(x.playlists).toEqual([
      {
        title: "All Episodes",
        smart: true,
        sorting: "chronological",
        includePodcastIds: [101, 303],
        priorityPodcastIds: [],
        includeEpisodeIds: [],
        sortedEpisodeIds: [],
      },
      { title: "Empty", smart: false, sorting: "manual", includePodcastIds: [], priorityPodcastIds: [], includeEpisodeIds: [], sortedEpisodeIds: [] },
    ]);
  });

  test("plain subscription OPML parses with no episode data", () => {
    const x = parseOvercastOpml(`<?xml version="1.0"?><opml version="1.0"><body><outline text="feeds">
      <outline type="rss" text="A" title="A" xmlUrl="https://a.example.com/rss" overcastId="1"/></outline></body></opml>`);
    expect(x.hasEpisodeData).toBe(false);
    expect(x.feeds[0]).toMatchObject({ feedUrl: "https://a.example.com/rss", subscribed: true });
  });

  test("listened rule: played or more than 5 minutes in", () => {
    expect(countsAsListened({ played: true })).toBe(true);
    expect(countsAsListened({ played: false, progress: 301 })).toBe(true);
    expect(countsAsListened({ played: false, progress: 120 })).toBe(false);
  });
});

async function runImport(t: T, assumedSpeed = 1.5) {
  const batchId = await t.mutation(api.overcastImport.startOvercastImport, {
    opml: fixture("overcast-all-data.opml"),
    assumedSpeed,
  });
  await drain(t);
  return (await t.query(api.overcastImport.getImport, { batchId }))!;
}

async function snapshot(t: T) {
  const podcasts = await podcastViews(t);
  return await t.run(async (ctx) => ({
    podcasts,
    episodes: await ctx.db.query("episodes").collect(),
    states: await ctx.db.query("episodeStates").collect(),
    sessions: await ctx.db.query("listeningSessions").collect(),
    events: await ctx.db.query("libraryEvents").collect(),
    settings: await ctx.db.query("podcastSettings").collect(),
  }));
}

describe("Overcast import", () => {
  test("maps shows, episodes, state and estimated sessions", async () => {
    const t = setup();
    const batch = await runImport(t);
    expect(batch.status).toBe("done");
    expect(batch.counts).toMatchObject({
      podcasts: 3,
      subscribedPodcasts: 2,
      podcastsProcessed: 3,
      feedsFailed: 1,
      episodes: 8,
      episodesMatched: 6,
      ghostEpisodes: 2,
      playedEpisodes: 5,
      inProgressEpisodes: 2,
      starredEpisodes: 1,
      sessions: 6,
      estimatedDurationSessions: 2,
      earliestListenAt: Date.parse("2022-02-03T20:00:00Z") - 1200_000,
      upNextEpisodes: 3,
    });
    // TTW 1, TTW 2 (progress), TTW 3, TTW 0 (ghost: show median 3400), OF 1, DF 1 (dead feed: overall median 3200)
    expect(batch.counts.estimatedListenSeconds).toBeCloseTo((3600 + 1834 + 4000 + 3400 + 1800 + 3200) / 1.5, 6);
    expect(batch.medianDuration).toBe(3200);
    expect(batch.playlists).toHaveLength(2);
    expect(batch.playlists[0]!.podcastIds).toHaveLength(2);
    expect(batch.failedFeeds).toEqual([
      expect.objectContaining({ title: "Dead Feed", feedUrl: "https://feeds.example.com/dead.xml", status: 404, error: "HTTP 404" }),
    ]);

    const db = await snapshot(t);
    const show = (title: string) => db.podcasts.find((p) => p.title === title)!;
    expect(show("Tech Talk Weekly")).toMatchObject({ subscribed: true, overcastId: 101, subscribedAt: Date.parse("2023-03-04T09:15:00-05:00") });
    expect(show("Old Favourite")).toMatchObject({ subscribed: false, overcastId: 202 });
    expect(show("Dead Feed")).toMatchObject({ subscribed: true });
    expect(db.settings.find((s) => s.podcastId === show("Tech Talk Weekly")._id)?.notifications).toBe(true);

    const ep = (title: string) => db.episodes.find((e) => e.title === title)!;
    const st = (title: string) => db.states.find((s) => s.episodeId === ep(title)._id)!;
    // Matched by enclosure with a different query string.
    expect(ep("TTW 1: Played").isGhost).toBe(false);
    expect(st("TTW 1: Played")).toMatchObject({ played: true, archived: true, playedAt: Date.parse("2025-09-02T08:00:00+10:00") });
    // In progress.
    expect(st("TTW 2: Halfway")).toMatchObject({ played: false, position: 1834 });
    // Matched by title + date after a CDN move; starred.
    expect(ep("TTW 3: Moved CDN")).toMatchObject({ isGhost: false, guid: "ttw-3" });
    expect(st("TTW 3: Moved CDN")).toMatchObject({ starred: true, played: true });
    // Gone from the feed: a ghost.
    expect(ep("TTW 0: Gone from feed")).toMatchObject({ isGhost: true, enclosureUrl: "https://oldcdn.example.com/ttw/0.mp3" });
    // Deleted unplayed = skipped.
    expect(st("TTW 4: Skipped")).toMatchObject({ archived: true, played: false });
    expect(db.events.some((e) => e.type === "skipped" && e.episodeId === ep("TTW 4: Skipped")._id)).toBe(true);
    expect(st("TTW 5: Barely started").position).toBe(120);
    // Overcast has no Inbox: unplayed episodes go to Up Next (chronological, as
    // the main playlist sorts), including the one he hadn't touched yet.
    expect(await t.query(api.episodes.inbox, {})).toEqual([]);
    expect(db.states.find((s) => s.episodeId === ep("TTW 6: Brand new")._id)).toBeUndefined();
    const queue = await t.query(api.queue.upNext, {});
    expect(queue.map((q) => q.row.episode.title)).toEqual(["TTW 2: Halfway", "TTW 5: Barely started", "TTW 6: Brand new"]);
    // The dead feed's episode is a ghost; its session uses the overall median.
    expect(ep("DF 1").isGhost).toBe(true);
    expect(db.sessions.find((s) => s.sessionId === "overcast:3001")).toMatchObject({ contentEnd: 3200, isEstimated: true });

    const session = db.sessions.find((s) => s.sessionId === "overcast:1003")!;
    expect(session).toMatchObject({ isEstimated: true, source: "overcastImport", rate: 1.5, contentEnd: 4000 });
    expect(session.endedAt).toBe(Date.parse("2025-09-16T21:45:00+10:00"));
    expect(session.endedAt - session.startedAt).toBe(Math.round((4000 / 1.5) * 1000));
    expect(db.sessions.map((s) => s.sessionId).sort()).toEqual([
      "overcast:1001",
      "overcast:1002",
      "overcast:1003",
      "overcast:1004",
      "overcast:2001",
      "overcast:3001",
    ]);

    // Past shows: unsubscribed with history.
    expect((await t.query(api.podcasts.pastShows, {})).map((p) => p.title)).toEqual(["Old Favourite"]);
    // Stats see the history.
    const y = await t.query(api.stats.summary, { period: "year", anchorDay: "2025-06-01" });
    expect(y.completion.completed).toBe(3); // TTW 1, TTW 3, DF 1
    expect(y.includesEstimated).toBe(true);
  });

  test("re-running is idempotent and keeps newer Poddle changes", async () => {
    const t = setup();
    await runImport(t);
    const before = await snapshot(t);
    const ttw2 = before.episodes.find((e) => e.title === "TTW 2: Halfway")!;
    await t.mutation(api.episodes.updatePosition, { episodeId: ttw2._id, position: 4000, positionUpdatedAt: NOW, deviceId: "phone" });

    const again = await runImport(t);
    expect(again.counts.sessions).toBe(6);
    const after = await snapshot(t);
    expect(after.podcasts).toHaveLength(before.podcasts.length);
    expect(after.episodes).toHaveLength(before.episodes.length);
    expect(after.states).toHaveLength(before.states.length);
    expect(after.sessions).toHaveLength(before.sessions.length);
    expect(after.events).toHaveLength(before.events.length);
    expect(after.states.find((s) => s.episodeId === ttw2._id)?.position).toBe(4000);
    const y = await t.query(api.stats.summary, { period: "all" });
    expect(y.totals.sessions).toBe(6);
    expect(await t.query(api.queue.upNext, {})).toHaveLength(3);
  });

  test("warns on the plain subscriptions export", async () => {
    const t = setup();
    const batchId = await t.mutation(api.overcastImport.startOvercastImport, {
      opml: `<?xml version="1.0"?><opml version="1.0"><body><outline type="rss" text="Old" title="Old" xmlUrl="https://feeds.example.com/oldfav.xml"/></body></opml>`,
      assumedSpeed: 1,
    });
    await drain(t);
    const batch = await t.query(api.overcastImport.getImport, { batchId });
    expect(batch?.status).toBe("done");
    expect(batch?.warning).toMatch(/All data/);
    expect(batch?.counts.subscribedPodcasts).toBe(1);
  });
});

// The import runs as a chain of scheduled actions (importActions.processBatch).
// These cover what happens when that chain is interrupted or races something.
describe("Overcast import, when things go wrong", () => {
  const MIN = 60_000;
  const TTW = "https://feeds.example.com/techtalk.xml";

  /** Starts an import and runs only the parse: the batch is fetching, its first worker run is scheduled but hasn't run. */
  async function parsedOnly(t: T) {
    const batchId = await t.mutation(api.overcastImport.startOvercastImport, { opml: fixture("overcast-all-data.opml"), assumedSpeed: 1.5 });
    vi.runOnlyPendingTimers();
    await t.finishInProgressScheduledFunctions();
    return batchId;
  }

  /** The worker chain dies: whatever it scheduled next finds it's no longer the batch's worker, and stops. */
  async function killWorker(t: T, batchId: Id<"importBatches">) {
    await t.run(async (ctx) => {
      const batch = (await ctx.db.get(batchId))!;
      await ctx.db.patch(batchId, { worker: (batch.worker ?? 0) + 100 });
    });
  }

  const batchOf = async (t: T, batchId: Id<"importBatches">) => (await t.query(api.overcastImport.getImport, { batchId }))!;
  const scratchRows = (t: T) =>
    t.run(async (ctx) => [
      ...(await ctx.db.query("importItems").collect()),
      ...(await ctx.db.query("importQueue").collect()),
      ...(await ctx.db.query("importUpNext").collect()),
    ]);

  /** A run of the watchdog cron, after `minutes` without progress. */
  async function watchdogAfter(t: T, minutes: number) {
    vi.setSystemTime(Date.now() + minutes * MIN);
    await t.mutation(internal.overcastImport.resumeStalled, {});
    await drain(t);
  }

  // A fetch of the same feed already running (the poller, someone else adding the
  // show) made the import's claim answer "busy", which it took as fetched. It then
  // matched the history against whatever episodes happened to be stored: here none,
  // so every played episode became a ghost.
  test("a feed another fetch is holding is fetched once it's free, not matched against nothing", async () => {
    const t = setup();
    const podcastId = await t.mutation(internal.podcasts.ensurePodcast, { feedUrl: TTW, title: "Tech Talk Weekly" });
    await t.run(async (ctx) => {
      await ctx.db.insert("feedStates", { podcastId, active: false, nextCheckAt: NOW, consecutiveErrors: 0, fetchingUntil: NOW + 2 * MIN });
    });
    const batch = await runImport(t);
    expect(batch.status).toBe("done");
    expect(batch.counts).toMatchObject({ podcastsProcessed: 3, episodesMatched: 6, ghostEpisodes: 2, upNextEpisodes: 3 });
    const db = await snapshot(t);
    expect(db.episodes.find((e) => e.title === "TTW 1: Played")?.isGhost).toBe(false);
  });

  // Nothing watched the chain: if one of its actions died, the batch said
  // "fetching" forever and the app's import screen never finished.
  test("an import whose worker died picks up where it left off", async () => {
    const t = setup();
    const batchId = await parsedOnly(t);
    await killWorker(t, batchId);
    await drain(t);
    expect((await batchOf(t, batchId)).status).toBe("fetching");

    await watchdogAfter(t, 2);
    expect((await batchOf(t, batchId)).status).toBe("fetching"); // not stalled long enough yet

    await watchdogAfter(t, 6);
    const batch = await batchOf(t, batchId);
    expect(batch.status).toBe("done");
    expect(batch.counts).toMatchObject({ podcastsProcessed: 3, episodesMatched: 6, sessions: 6, upNextEpisodes: 3 });
    expect(await scratchRows(t)).toEqual([]);
  });

  // claimMatches deleted the shows' queue rows before matching them, so a worker
  // that died mid-match lost those shows: a restarted run found nothing left to
  // match and finished without their history.
  test("a worker that dies mid-match loses no shows and doubles no history", async () => {
    const t = setup();
    const batchId = await parsedOnly(t);
    const worker = (await t.run(async (ctx) => (await ctx.db.get(batchId))!.worker))!;
    // One worker run fetches all three feeds, then the chain dies just after
    // claiming shows to match, and once more part way through matching one.
    await t.action(internal.importActions.processBatch, { batchId, worker });
    await killWorker(t, batchId);
    await t.mutation(internal.overcastImport.claimMatches, { batchId, count: 6 });
    const [row] = await t.run(async (ctx) => await ctx.db.query("importQueue").collect());
    await t.mutation(internal.overcastImport.matchPodcast, { batchId, rowId: row!._id });
    await drain(t);

    await watchdogAfter(t, 6);
    const batch = await batchOf(t, batchId);
    expect(batch.status).toBe("done");
    expect(batch.counts).toMatchObject({ podcastsProcessed: 3, episodesMatched: 6, ghostEpisodes: 2, sessions: 6, playedEpisodes: 5 });
    const db = await snapshot(t);
    expect(db.sessions).toHaveLength(6);
    expect(await t.query(api.queue.upNext, {})).toHaveLength(3);
  });

  test("an import that keeps dying gives up, says so and clears its scratch rows", async () => {
    const t = setup();
    const batchId = await parsedOnly(t);
    await killWorker(t, batchId);
    await drain(t);
    // Each restart dies before it gets anywhere.
    let restarts = 0;
    while ((await batchOf(t, batchId)).status === "fetching" && restarts < 10) {
      vi.setSystemTime(Date.now() + 6 * MIN);
      await t.mutation(internal.overcastImport.resumeStalled, {});
      await killWorker(t, batchId);
      await drain(t);
      restarts++;
    }
    expect(restarts).toBe(4); // three restarts, then it gives up
    const batch = await batchOf(t, batchId);
    expect(batch.status).toBe("failed");
    expect(batch.error).toMatch(/stopped/);
    expect(batch.finishedAt).toBeDefined();
    await drain(t);
    expect(await scratchRows(t)).toEqual([]);

    // A late run of a worker from before it gave up changes nothing.
    const worker = (await t.run(async (ctx) => (await ctx.db.get(batchId))!.worker))!;
    await t.action(internal.importActions.processBatch, { batchId, worker });
    await t.mutation(internal.overcastImport.finishBatch, { batchId });
    expect(await batchOf(t, batchId)).toMatchObject({ status: "failed" });
    expect(await t.query(api.queue.upNext, {})).toEqual([]);
  });

  test("reading a file that never finishes fails the import instead of leaving it reading", async () => {
    const t = setup();
    const batchId = await t.mutation(api.overcastImport.startOvercastImport, { opml: fixture("overcast-all-data.opml"), assumedSpeed: 1.5 });
    // The parse action is lost before it runs.
    await t.run(async (ctx) => {
      for (const job of await ctx.db.system.query("_scheduled_functions").collect()) await ctx.scheduler.cancel(job._id);
    });
    await watchdogAfter(t, 10);
    expect((await batchOf(t, batchId)).status).toBe("parsing");
    await watchdogAfter(t, 6);
    expect(await batchOf(t, batchId)).toMatchObject({ status: "failed", error: expect.stringMatching(/stopped/) });
  });

  test("finishing twice seeds Up Next once", async () => {
    const t = setup();
    const batchId = await t.mutation(api.overcastImport.startOvercastImport, { opml: fixture("overcast-all-data.opml"), assumedSpeed: 1.5 });
    await drain(t);
    await t.mutation(internal.overcastImport.finishBatch, { batchId });
    const batch = await batchOf(t, batchId);
    expect(batch.counts.upNextEpisodes).toBe(3);
    expect(await t.query(api.queue.upNext, {})).toHaveLength(3);
  });
});

