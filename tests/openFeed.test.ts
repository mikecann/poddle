import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { fixture, mockFetch, podcastViews, setup } from "./helpers";

// Finding one episode without following its show (decisions.md, 27 Oct 2026):
// Apple's episode search, and opening a show from Discover without subscribing.

const FEED = "https://feeds.example.com/odd.xml";
const NOW = Date.UTC(2025, 9, 15, 0, 0);

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("feedActions:openFeed", () => {
  test("opens a new show with its episodes, without following it", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const { podcastId, episodeId } = await t.action(api.feedActions.openFeed, { feedUrl: FEED, title: "The Odd Show" });

    expect(episodeId).toBeUndefined();
    const show = await t.query(api.podcasts.get, { podcastId });
    expect(show?.podcast).toMatchObject({ title: "The Odd Show", subscribed: false, episodeCount: 4 });
    const page = await t.query(api.podcasts.episodes, { podcastId, paginationOpts: { cursor: null, numItems: 50 } });
    expect(page.page).toHaveLength(4);
    // Nothing personal: not in the library, nothing in Up Next.
    expect(await podcastViews(t)).toEqual([]);
    expect(await t.query(api.podcasts.list, {})).toEqual([]);
    expect(await t.query(api.queue.upNext, {})).toEqual([]);
  });

  test("finds the episode Apple's search pointed at, by guid, then audio URL, then title and date", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const titleOf = async (episodeId: Id<"episodes"> | undefined) =>
      episodeId ? (await t.run((ctx) => ctx.db.get(episodeId)))?.title : undefined;

    const byGuid = await t.action(api.feedActions.openFeed, { feedUrl: FEED, episodeGuid: "https://odd.example.com/episodes/3" });
    expect(await titleOf(byGuid.episodeId)).toBe("Episode 3: Seconds");

    // Episode 2 has no guid in the feed, so Apple's guid can't match; its audio URL does.
    const byAudio = await t.action(api.feedActions.openFeed, {
      feedUrl: FEED,
      episodeGuid: "apple-made-this-up",
      enclosureUrl: "https://cdn.example.com/odd/ep2.mp3",
    });
    expect(await titleOf(byAudio.episodeId)).toBe("Episode 2: No GUID");

    const byTitle = await t.action(api.feedActions.openFeed, {
      feedUrl: FEED,
      episodeTitle: "Episode 1: Minutes",
      pubDate: Date.parse("2025-09-22T09:00:00Z"),
    });
    expect(await titleOf(byTitle.episodeId)).toBe("Episode 1: Minutes");

    const missing = await t.action(api.feedActions.openFeed, { feedUrl: FEED, episodeGuid: "nope" });
    expect(missing.episodeId).toBeUndefined();
    expect(missing.podcastId).toBe(byGuid.podcastId);
  });

  test("queueing one of its episodes puts the show in the library, still unfollowed", async () => {
    const t = setup();
    mockFetch({ [FEED]: fixture("odd-feed.xml") });
    const { podcastId, episodeId } = await t.action(api.feedActions.openFeed, { feedUrl: FEED, episodeGuid: "odd-ep-4" });
    await t.mutation(api.queue.add, { episodeId: episodeId!, position: "bottom", at: NOW });

    expect((await t.query(api.queue.upNext, {})).map((r) => r.row.episode.title)).toEqual(["Episode 4: Chapters & Transcripts"]);
    expect(await podcastViews(t)).toMatchObject([{ _id: podcastId, subscribed: false }]);
    expect(await t.query(api.podcasts.list, {})).toEqual([]);
  });

  test("a feed that can't be loaded is an error, not an empty show", async () => {
    const t = setup();
    mockFetch({ [FEED]: { status: 500, body: "boom" } });
    await expect(t.action(api.feedActions.openFeed, { feedUrl: FEED })).rejects.toThrow(/500/);
  });
});

describe("directory:searchEpisodes", () => {
  test("maps Apple's episode results, and leaves out ones without a feed", async () => {
    const t = setup();
    const fetchMock = mockFetch({
      "https://itunes.apple.com/search": JSON.stringify({
        results: [
          {
            trackId: 1000700000001,
            trackName: "A deep dive on AI model distillation attacks",
            collectionName: "Risky Business Features",
            artistName: "Patrick Gray",
            artworkUrl600: "https://is1.example.com/rb600.jpg",
            feedUrl: "https://risky.biz/feeds/risky-business-features/",
            episodeGuid: "https://risky.biz/RBFEATURES17/",
            episodeUrl: "https://media3.risky.biz/RBFEATURES17.mp3",
            releaseDate: "2026-10-21T22:00:00Z",
            trackTimeMillis: 2_712_000,
          },
          { trackId: 2, trackName: "No feed, so nothing to open", collectionName: "Somewhere" },
        ],
      }),
    });

    const results = await t.action(api.directory.searchEpisodes, { term: "Distillation Attacks" });
    expect(results).toEqual([
      {
        appleId: 1000700000001,
        title: "A deep dive on AI model distillation attacks",
        showTitle: "Risky Business Features",
        author: "Patrick Gray",
        artworkUrl: "https://is1.example.com/rb600.jpg",
        feedUrl: "https://risky.biz/feeds/risky-business-features/",
        guid: "https://risky.biz/RBFEATURES17/",
        audioUrl: "https://media3.risky.biz/RBFEATURES17.mp3",
        pubDate: Date.parse("2026-10-21T22:00:00Z"),
        duration: 2712,
      },
    ]);
    expect(String(fetchMock.mock.calls[0]![0])).toContain("entity=podcastEpisode");
    expect(await t.action(api.directory.searchEpisodes, { term: "  " })).toEqual([]);
  });

  test("refuses callers who aren't signed in", async () => {
    const t = setup();
    await expect(t.raw.action(api.directory.searchEpisodes, { term: "a" })).rejects.toThrow(/Sign in first/);
  });
});
