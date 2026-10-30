"use node";

import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalAction } from "./_generated/server";
import { userAction } from "./lib/auth";
import { fetchFeedDocument, refreshPodcast } from "./lib/feedFetch";
import { normalizeFeedUrl, parseAppleId } from "./lib/parse";
import { vIngestMode } from "./lib/ingest";

// Feed fetching (Node actions). Conditional GET with ETag / Last-Modified.

const vRefreshResult = v.object({
  status: v.union(v.literal("updated"), v.literal("notModified"), v.literal("unchanged"), v.literal("busy"), v.literal("error")),
  newEpisodes: v.number(),
  error: v.optional(v.string()),
});

export const fetchFeed = internalAction({
  args: { podcastId: v.id("podcasts"), mode: v.optional(vIngestMode), force: v.optional(v.boolean()) },
  returns: vRefreshResult,
  handler: async (ctx, { podcastId, mode, force }) => {
    return await refreshPodcast(ctx, podcastId, { mode, force });
  },
});

/**
 * Called on app foreground and pull-to-refresh. With a `podcastId`, fetches that
 * show now and waits for it. Without, schedules every subscribed feed that
 * hasn't been checked in the last 2 minutes (and isn't being fetched) and returns how many.
 */
export const refreshNow = userAction({
  args: { podcastId: v.optional(v.id("podcasts")) },
  returns: v.object({ scheduled: v.number(), result: v.optional(vRefreshResult) }),
  handler: async (ctx, { podcastId }) => {
    if (podcastId) {
      const result = await refreshPodcast(ctx, podcastId, { force: false });
      return { scheduled: 0, result };
    }
    const podcastIds: Id<"podcasts">[] = await ctx.runQuery(internal.feeds.feedsToRefresh, { userId: ctx.userId });
    if (podcastIds.length) await ctx.runMutation(internal.feeds.scheduleFetches, { podcastIds });
    return { scheduled: podcastIds.length };
  },
});

/**
 * Open a show from Discover without following it (decisions.md, 27 Oct 2026).
 * Creates the shared show if it's new and fetches it, so its page can list the
 * episodes, which `podcasts:get` and `podcasts:episodes` then return. With an
 * episode from `directory:searchEpisodes` (its guid, audio URL, title and date),
 * also finds that episode. Nothing personal is written: queueing or downloading
 * one of its episodes is what puts the show in your library, unfollowed.
 */
export const openFeed = userAction({
  args: {
    feedUrl: v.string(),
    title: v.optional(v.string()),
    author: v.optional(v.string()),
    artworkUrl: v.optional(v.string()),
    appleId: v.optional(v.number()),
    episodeGuid: v.optional(v.string()),
    enclosureUrl: v.optional(v.string()),
    episodeTitle: v.optional(v.string()),
    pubDate: v.optional(v.number()),
  },
  returns: v.object({ podcastId: v.id("podcasts"), episodeId: v.optional(v.id("episodes")) }),
  handler: async (ctx, { episodeGuid, enclosureUrl, episodeTitle, pubDate, ...show }) => {
    const podcastId: Id<"podcasts"> = await ctx.runMutation(internal.podcasts.ensurePodcast, show);
    // A conditional GET, so a show other people follow (and so is polled) costs a 304.
    const result = await refreshPodcast(ctx, podcastId, { force: false });
    const opened: { episodeCount: number; episodeId: Id<"episodes"> | null } = await ctx.runQuery(internal.podcasts.feedOpened, {
      podcastId,
      guid: episodeGuid,
      enclosureUrl,
      title: episodeTitle,
      pubDate,
    });
    if (result.status === "error" && opened.episodeCount === 0) throw new Error(result.error ?? "Couldn't load that show");
    return { podcastId, episodeId: opened.episodeId ?? undefined };
  },
});

const PREVIEW_EPISODES = 20;

/**
 * Preview a show before subscribing. Accepts an RSS/Atom URL, a website (feed
 * discovered via <link rel="alternate">), a podcasts.apple.com link or an
 * overcast.fm/itunes… link. Nothing is written.
 */
export const previewFeed = userAction({
  args: { url: v.string() },
  returns: v.object({
    feedUrl: v.string(),
    podcastId: v.optional(v.id("podcasts")),
    subscribed: v.boolean(),
    title: v.string(),
    author: v.optional(v.string()),
    description: v.optional(v.string()),
    artworkUrl: v.optional(v.string()),
    link: v.optional(v.string()),
    episodeCount: v.number(),
    episodes: v.array(
      v.object({
        title: v.string(),
        pubDate: v.optional(v.number()),
        duration: v.optional(v.number()),
        summary: v.optional(v.string()),
        enclosureUrl: v.string(),
        artworkUrl: v.optional(v.string()),
      }),
    ),
  }),
  handler: async (ctx, { url }) => {
    let feedUrl = url.trim();
    if (/apple\.com|overcast\.fm\/itunes/i.test(feedUrl) || /^\d+$/.test(feedUrl)) {
      const appleId = parseAppleId(feedUrl);
      if (!appleId) throw new Error("Couldn't find an Apple ID in that link");
      const res = await fetch(`https://itunes.apple.com/lookup?id=${appleId}&entity=podcast&country=AU`);
      const body = (await res.json()) as { results?: { feedUrl?: string }[] };
      const found = body.results?.[0]?.feedUrl;
      if (!found) throw new Error("Apple doesn't list a feed for that show");
      feedUrl = found;
    }
    const { feed, finalUrl } = await fetchFeedDocument(normalizeFeedUrl(feedUrl));
    const normalized = normalizeFeedUrl(finalUrl);
    const matches: { podcastId: Id<"podcasts">; subscribed: boolean }[] = await ctx.runQuery(
      internal.directoryCache.libraryMatches,
      { userId: ctx.userId, feedUrls: [normalized] },
    );
    const match = matches[0];
    return {
      feedUrl: normalized,
      podcastId: match?.podcastId,
      subscribed: match?.subscribed ?? false,
      title: feed.title,
      author: feed.author,
      description: feed.description,
      artworkUrl: feed.artworkUrl,
      link: feed.link,
      episodeCount: feed.episodes.length,
      episodes: feed.episodes.slice(0, PREVIEW_EPISODES).map((e) => ({
        title: e.title,
        pubDate: e.pubDate,
        duration: e.duration,
        summary: e.summary,
        enclosureUrl: e.enclosureUrl,
        artworkUrl: e.artworkUrl,
      })),
    };
  },
});
