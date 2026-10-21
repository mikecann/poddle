import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { nextCheckDelay } from "../convex/feeds";
import { drain, fixture, mockFetch, setup, TOKEN, type T } from "./helpers";

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

async function subscribeTo(t: T) {
  const podcastId = await t.mutation(api.podcasts.subscribe, { token: TOKEN, feedUrl: FEED, at: NOW });
  await drain(t);
  return podcastId;
}

async function inboxTitles(t: T) {
  return (await t.query(api.episodes.inbox, { token: TOKEN })).map((r) => r.episode.title);
}
async function queueTitles(t: T) {
  return (await t.query(api.queue.upNext, { token: TOKEN })).map((r) => r.row.episode.title);
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("subscribing", () => {
  test("first fetch creates every episode but only the latest lands in the Inbox", async () => {
    const t = setup();
    mockFetch({ [FEED]: { body: fixture("odd-feed.xml"), headers: { etag: '"v1"' } } });
    const podcastId = await subscribeTo(t);

    const page = await t.query(api.podcasts.episodes, { token: TOKEN, podcastId, paginationOpts: { cursor: null, numItems: 50 } });
    expect(page.page).toHaveLength(4);
    expect(await inboxTitles(t)).toEqual(["Episode 4: Chapters & Transcripts"]);

    const show = await t.query(api.podcasts.get, { token: TOKEN, podcastId });
    expect(show?.podcast).toMatchObject({ title: "The Odd Show", subscribed: true, episodeCount: 4, artworkUrl: "https://cdn.example.com/odd-3000.jpg" });
  });

  test("rejects a bad token", async () => {
    const t = setup();
    await expect(t.query(api.episodes.inbox, { token: "nope" })).rejects.toThrow(/Bad API token/);
  });
});

describe("refreshing", () => {
  test("uses conditional GET and handles 304", async () => {
    const t = setup();
    mockFetch({ [FEED]: { body: fixture("odd-feed.xml"), headers: { etag: '"v1"', "last-modified": "Tue, 14 Oct 2025 18:00:00 GMT" } } });
    const podcastId = await subscribeTo(t);

    const fetchMock = mockFetch({ [FEED]: { status: 304 } });
    const r = await t.action(api.feedActions.refreshNow, { token: TOKEN, podcastId });
    expect(r.result?.status).toBe("notModified");
    const headers = fetchMock.mock.calls[0]![1]!.headers as Record<string, string>;
    expect(headers["If-None-Match"]).toBe('"v1"');
    expect(headers["If-Modified-Since"]).toBe("Tue, 14 Oct 2025 18:00:00 GMT");
  });

  test("an unchanged body is skipped even without 304 support", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const podcastId = await subscribeTo(t);
    const r = await t.action(api.feedActions.refreshNow, { token: TOKEN, podcastId });
    expect(r.result?.status).toBe("unchanged");
  });

  test("new episodes follow the show's rule and never clobber user state", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const podcastId = await subscribeTo(t);
    const ep4 = (await t.query(api.episodes.inbox, { token: TOKEN }))[0]!.episode._id;
    await t.mutation(api.episodes.setStarredState, { token: TOKEN, episodeId: ep4, starred: true, at: NOW });
    await t.mutation(api.episodes.updatePosition, { token: TOKEN, episodeId: ep4, position: 99, positionUpdatedAt: NOW, deviceId: "phone" });

    // Publisher renames episode 4 and publishes episode 5.
    const body = withNewItems(newItem(5, "Wed, 15 Oct 2025 00:00:00 GMT")).replace(
      "Episode 4: Chapters &amp; Transcripts</title>",
      "Episode 4: Renamed</title>",
    );
    mockFetch({ [FEED]: body });
    const r = await t.action(api.feedActions.refreshNow, { token: TOKEN, podcastId });
    expect(r.result).toMatchObject({ status: "updated", newEpisodes: 1 });
    expect(await inboxTitles(t)).toEqual(["Episode 5: Fresh", "Episode 4: Renamed"]);

    const detail = await t.query(api.episodes.get, { token: TOKEN, episodeId: ep4 });
    expect(detail?.row.state).toMatchObject({ starred: true, position: 99, positionDeviceId: "phone" });
  });

  test("back-catalogue items appearing later don't go to the Inbox", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const podcastId = await subscribeTo(t);
    mockFetch({ [FEED]: withNewItems(newItem(0, "Mon, 01 Jan 2024 00:00:00 GMT")) });
    const r = await t.action(api.feedActions.refreshNow, { token: TOKEN, podcastId });
    expect(r.result?.newEpisodes).toBe(1);
    expect(await inboxTitles(t)).toEqual(["Episode 4: Chapters & Transcripts"]);
  });

  test.each([
    ["upNextBottom", ["Playing", "Queued", "Episode 5: Fresh"], []],
    ["upNextTop", ["Playing", "Episode 5: Fresh", "Queued"], []],
    ["none", ["Playing", "Queued"], []],
    ["inbox", ["Playing", "Queued"], ["Episode 5: Fresh"]],
  ] as const)("rule %s", async (rule, expectedQueue, expectedInbox) => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const podcastId = await subscribeTo(t);
    // Take the first-subscribe episode out of the Inbox to keep the assertions focused.
    const first = (await t.query(api.episodes.inbox, { token: TOKEN }))[0]!.episode._id;
    await t.mutation(api.episodes.setArchivedState, { token: TOKEN, episodeId: first, archived: true, at: Date.now() });
    await seedQueue(t, podcastId, ["Playing", "Queued"]);
    await t.mutation(api.settings.updatePodcast, { token: TOKEN, podcastId, patch: { newEpisodes: rule }, at: Date.now() });

    mockFetch({ [FEED]: withNewItems(newItem(5, "Wed, 15 Oct 2025 00:00:00 GMT")) });
    await t.action(api.feedActions.refreshNow, { token: TOKEN, podcastId });
    expect(await queueTitles(t)).toEqual(expectedQueue);
    expect(await inboxTitles(t)).toEqual(expectedInbox);
  });

  test("notifications go out only for new episodes on shows with them on", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const podcastId = await subscribeTo(t);
    await t.mutation(api.settings.updatePodcast, { token: TOKEN, podcastId, patch: { notifications: true }, at: NOW });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    mockFetch({ [FEED]: withNewItems(newItem(5, "Wed, 15 Oct 2025 00:00:00 GMT")) });
    await t.action(api.feedActions.refreshNow, { token: TOKEN, podcastId });
    await drain(t);
    expect(log.mock.calls.flat().join("\n")).toContain("[apns] not configured, skipping: The Odd Show: Episode 5: Fresh");
    log.mockRestore();
  });
});

describe("polling", () => {
  test("backs off quiet feeds and failing feeds", () => {
    const now = NOW;
    expect(nextCheckDelay(now - 86_400_000, 0, now)).toBe(15 * 60_000);
    expect(nextCheckDelay(now - 20 * 86_400_000, 0, now)).toBe(60 * 60_000);
    expect(nextCheckDelay(now - 400 * 86_400_000, 0, now)).toBe(12 * 3600_000);
    expect(nextCheckDelay(now, 2, now)).toBe(60 * 60_000);
    expect(nextCheckDelay(now, 10, now)).toBe(24 * 3600_000);
  });

  test("the cron only fetches subscribed feeds that are due", async () => {
    const t = setup();
    const fetchMock = mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const podcastId = await subscribeTo(t);
    fetchMock.mockClear();

    expect(await t.mutation(internal.feeds.pollDueFeeds, {})).toBe(0);
    vi.setSystemTime(NOW + 16 * 60_000);
    expect(await t.mutation(internal.feeds.pollDueFeeds, {})).toBe(1);
    await drain(t);
    expect(fetchMock).toHaveBeenCalledTimes(1);

    await t.mutation(api.podcasts.unsubscribe, { token: TOKEN, podcastId, at: NOW + 17 * 60_000 });
    vi.setSystemTime(NOW + 3 * 3600_000);
    expect(await t.mutation(internal.feeds.pollDueFeeds, {})).toBe(0);
  });
});

/** Put fake episodes for a show straight into the queue, in order. */
async function seedQueue(t: T, podcastId: Id<"podcasts">, titles: string[]) {
  const ids = await t.run(async (ctx) => {
    const out = [];
    for (const title of titles) {
      out.push(
        await ctx.db.insert("episodes", {
          podcastId,
          title,
          enclosureUrl: `https://x.example.com/${title}.mp3`,
          transcripts: [],
          isGhost: false,
          firstSeenAt: NOW,
          updatedAt: NOW,
        }),
      );
    }
    return out;
  });
  for (const episodeId of ids) await t.mutation(api.queue.add, { token: TOKEN, episodeId, position: "bottom", at: Date.now() });
  return ids;
}
