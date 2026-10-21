import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import { countsAsListened, parseOvercastOpml } from "../convex/lib/opml";
import { drain, fixture, mockFetch, setup, TOKEN, type T } from "./helpers";

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
    expect(x.playlists).toEqual([{ title: "All Episodes", smart: true, sorting: "chronological", includePodcastIds: [101, 303] }]);
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
    token: TOKEN,
    opml: fixture("overcast-all-data.opml"),
    assumedSpeed,
  });
  await drain(t);
  return (await t.query(api.overcastImport.getImport, { token: TOKEN, batchId }))!;
}

async function snapshot(t: T) {
  return await t.run(async (ctx) => ({
    podcasts: await ctx.db.query("podcasts").collect(),
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
      sessions: 5,
      earliestListenAt: Date.parse("2022-02-03T20:00:00Z") - 1200_000,
    });
    // (3600 + 1834 + 4000 + 2400 + 1800) / 1.5
    expect(batch.counts.estimatedListenSeconds).toBeCloseTo(13634 / 1.5, 6);
    expect(batch.playlists).toHaveLength(1);
    expect(batch.playlists[0]!.podcastIds).toHaveLength(2);

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
    // New in the feed, not in Overcast: no Inbox flood from an import.
    expect(await t.query(api.episodes.inbox, { token: TOKEN })).toEqual([]);
    expect(db.states.find((s) => s.episodeId === ep("TTW 6: Brand new")._id)).toBeUndefined();
    // The dead feed's episode is a ghost, played, but with no duration it has no session.
    expect(ep("DF 1").isGhost).toBe(true);

    const session = db.sessions.find((s) => s.sessionId === "overcast:1003")!;
    expect(session).toMatchObject({ isEstimated: true, source: "overcastImport", rate: 1.5, contentEnd: 4000 });
    expect(session.endedAt).toBe(Date.parse("2025-09-16T21:45:00+10:00"));
    expect(session.endedAt - session.startedAt).toBe(Math.round((4000 / 1.5) * 1000));
    expect(db.sessions.map((s) => s.sessionId).sort()).toEqual(["overcast:1001", "overcast:1002", "overcast:1003", "overcast:1004", "overcast:2001"]);

    // Past shows: unsubscribed with history.
    expect((await t.query(api.podcasts.pastShows, { token: TOKEN })).map((p) => p.title)).toEqual(["Old Favourite"]);
    // Stats see the history.
    const y = await t.query(api.stats.summary, { token: TOKEN, period: "year", anchorDay: "2025-06-01" });
    expect(y.completion.completed).toBe(3); // TTW 1, TTW 3, DF 1
    expect(y.includesEstimated).toBe(true);
  });

  test("re-running is idempotent and keeps newer Poddle changes", async () => {
    const t = setup();
    await runImport(t);
    const before = await snapshot(t);
    const ttw2 = before.episodes.find((e) => e.title === "TTW 2: Halfway")!;
    await t.mutation(api.episodes.updatePosition, { token: TOKEN, episodeId: ttw2._id, position: 4000, positionUpdatedAt: NOW, deviceId: "phone" });

    const again = await runImport(t);
    expect(again.counts.sessions).toBe(5);
    const after = await snapshot(t);
    expect(after.podcasts).toHaveLength(before.podcasts.length);
    expect(after.episodes).toHaveLength(before.episodes.length);
    expect(after.states).toHaveLength(before.states.length);
    expect(after.sessions).toHaveLength(before.sessions.length);
    expect(after.events).toHaveLength(before.events.length);
    expect(after.states.find((s) => s.episodeId === ttw2._id)?.position).toBe(4000);
    const y = await t.query(api.stats.summary, { token: TOKEN, period: "all" });
    expect(y.totals.sessions).toBe(5);
  });

  test("warns on the plain subscriptions export", async () => {
    const t = setup();
    const batchId = await t.mutation(api.overcastImport.startOvercastImport, {
      token: TOKEN,
      opml: `<?xml version="1.0"?><opml version="1.0"><body><outline type="rss" text="Old" title="Old" xmlUrl="https://feeds.example.com/oldfav.xml"/></body></opml>`,
      assumedSpeed: 1,
    });
    await drain(t);
    const batch = await t.query(api.overcastImport.getImport, { token: TOKEN, batchId });
    expect(batch?.status).toBe("done");
    expect(batch?.warning).toMatch(/All data/);
    expect(batch?.counts.subscribedPodcasts).toBe(1);
  });
});
