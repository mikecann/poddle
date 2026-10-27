"use node";

import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import type { ActionCtx } from "./_generated/server";
import { userAction } from "./lib/auth";
import { directoryBase } from "./lib/e2e";
import { fetchWithTimeout, USER_AGENT } from "./lib/feedFetch";
import { parseAppleId } from "./lib/parse";
import { type DirectoryEpisode, type DirectoryResult, vDirectoryEpisode, vDirectoryResult } from "./lib/validators";

// Apple Podcasts directory (iTunes Search API), spec §2.1. The e2e suites point
// it at their fixture server instead (lib/e2e.ts).

type ItunesItem = {
  collectionId?: number;
  trackId?: number;
  collectionName?: string;
  trackName?: string;
  artistName?: string;
  artworkUrl600?: string;
  artworkUrl100?: string;
  feedUrl?: string;
  primaryGenreName?: string;
  trackCount?: number;
  // Episode results (entity=podcastEpisode) also have these.
  episodeGuid?: string;
  episodeUrl?: string;
  releaseDate?: string;
  trackTimeMillis?: number;
};

async function itunesJson(ctx: ActionCtx, url: string): Promise<ItunesItem[]> {
  const cached = await ctx.runQuery(internal.directoryCache.getCached, { key: url });
  if (cached) return JSON.parse(cached) as ItunesItem[];
  const res = await fetchWithTimeout(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } }, 10_000);
  if (!res.ok) throw new Error(`Apple directory returned HTTP ${res.status}`);
  const body = (await res.json()) as { results?: ItunesItem[] };
  const results = body.results ?? [];
  await ctx.runMutation(internal.directoryCache.putCached, { key: url, json: JSON.stringify(results) });
  return results;
}

async function toResults(ctx: ActionCtx & { userId: Id<"users"> }, items: ItunesItem[]): Promise<DirectoryResult[]> {
  const feedUrls = items.map((i) => i.feedUrl).filter((u): u is string => !!u);
  const matches = await ctx.runQuery(internal.directoryCache.libraryMatches, { userId: ctx.userId, feedUrls });
  const byUrl = new Map(matches.map((m) => [m.feedUrl, m]));
  return items.map((i) => {
    const match = i.feedUrl ? byUrl.get(i.feedUrl) : undefined;
    return {
      appleId: i.collectionId ?? i.trackId,
      title: i.collectionName ?? i.trackName ?? "Untitled",
      author: i.artistName,
      artworkUrl: i.artworkUrl600 ?? i.artworkUrl100,
      feedUrl: i.feedUrl,
      genre: i.primaryGenreName,
      episodeCount: i.trackCount,
      podcastId: match?.podcastId,
      subscribed: match?.subscribed ?? false,
    };
  });
}

/** Search Apple's directory (AU store). Results are cached for 24 h. Debounce on the client. */
export const search = userAction({
  args: { term: v.string(), limit: v.optional(v.number()) },
  returns: v.array(vDirectoryResult),
  handler: async (ctx, { term, limit }) => {
    const t = term.trim();
    if (!t) return [];
    const n = Math.min(Math.max(limit ?? 50, 1), 200);
    const url = `${directoryBase()}/search?term=${encodeURIComponent(t.toLowerCase())}&media=podcast&entity=podcast&country=AU&limit=${n}`;
    return await toResults(ctx, await itunesJson(ctx, url));
  },
});

/**
 * Search Apple's directory for episodes by name (decisions.md, 27 Oct 2026), so
 * one episode can be found and played without following its show. Results
 * without a feed are left out, since there'd be nothing to open. Cached 24 h.
 */
export const searchEpisodes = userAction({
  args: { term: v.string(), limit: v.optional(v.number()) },
  returns: v.array(vDirectoryEpisode),
  handler: async (ctx, { term, limit }) => {
    const t = term.trim();
    if (!t) return [];
    const n = Math.min(Math.max(limit ?? 25, 1), 200);
    const url = `${directoryBase()}/search?term=${encodeURIComponent(t.toLowerCase())}&media=podcast&entity=podcastEpisode&country=AU&limit=${n}`;
    return (await itunesJson(ctx, url)).flatMap((i): DirectoryEpisode[] => {
      if (!i.feedUrl || !i.trackName) return [];
      const released = i.releaseDate ? Date.parse(i.releaseDate) : NaN;
      return [
        {
          appleId: i.trackId,
          title: i.trackName,
          showTitle: i.collectionName ?? "Untitled",
          author: i.artistName,
          artworkUrl: i.artworkUrl600 ?? i.artworkUrl100,
          feedUrl: i.feedUrl,
          guid: i.episodeGuid,
          audioUrl: i.episodeUrl,
          pubDate: Number.isNaN(released) ? undefined : released,
          duration: i.trackTimeMillis ? Math.round(i.trackTimeMillis / 1000) : undefined,
        },
      ];
    });
  },
});

/** Look up a show by Apple ID or a pasted podcasts.apple.com / overcast.fm link. */
export const lookup = userAction({
  args: { appleIdOrUrl: v.string() },
  returns: v.union(vDirectoryResult, v.null()),
  handler: async (ctx, { appleIdOrUrl }) => {
    const id = parseAppleId(appleIdOrUrl);
    if (!id) return null;
    const items = await itunesJson(ctx, `${directoryBase()}/lookup?id=${id}&entity=podcast&country=AU`);
    const [first] = await toResults(ctx, items.slice(0, 1));
    return first ?? null;
  },
});
