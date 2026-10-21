"use node";

import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalAction } from "./_generated/server";
import { refreshPodcast } from "./lib/feedFetch";
import { parseOvercastOpml, type OvercastFeed } from "./lib/opml";

// Node side of the Overcast import: parsing the file and fetching feeds.
// See overcastImport.ts for the pipeline.

const STAGE_CHUNK_BYTES = 1_000_000;
/** Feeds fetched in parallel per scheduled run. */
const FETCH_BATCH = 6;

export const parse = internalAction({
  args: {
    batchId: v.id("importBatches"),
    storageId: v.optional(v.id("_storage")),
    opml: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { batchId, storageId, opml }) => {
    try {
      let text = opml;
      if (!text && storageId) {
        const blob = await ctx.storage.get(storageId);
        if (!blob) throw new Error("Uploaded file not found");
        text = await blob.text();
      }
      const parsed = parseOvercastOpml(text ?? "");
      for (const chunk of chunkFeeds(parsed.feeds)) {
        await ctx.runMutation(internal.overcastImport.stageFeeds, {
          batchId,
          feeds: chunk.map(({ htmlUrl: _h, episodes, ...f }) => ({
            ...f,
            episodes: episodes.map(({ overcastUrl: _o, ...e }) => e),
          })),
        });
      }
      await ctx.runMutation(internal.overcastImport.beginFetching, {
        batchId,
        warning: parsed.hasEpisodeData
          ? undefined
          : "This looks like the plain subscriptions export. Use Overcast's \"All data\" export to bring in history.",
        playlists: parsed.playlists.map((p) => ({ title: p.title, smart: p.smart, includePodcastIds: p.includePodcastIds })),
      });
      if (storageId) await ctx.storage.delete(storageId);
    } catch (e) {
      await ctx.runMutation(internal.overcastImport.failBatch, { batchId, error: (e as Error).message });
    }
    return null;
  },
});

function chunkFeeds(feeds: OvercastFeed[]): OvercastFeed[][] {
  const chunks: OvercastFeed[][] = [];
  let current: OvercastFeed[] = [];
  let bytes = 0;
  for (const f of feeds) {
    const size = JSON.stringify(f).length;
    if (current.length && (bytes + size > STAGE_CHUNK_BYTES || current.length >= 25)) {
      chunks.push(current);
      current = [];
      bytes = 0;
    }
    current.push(f);
    bytes += size;
  }
  if (current.length) chunks.push(current);
  return chunks;
}

/** Fetch a handful of feeds, match their staged episodes, then schedule the next handful. */
export const processBatch = internalAction({
  args: { batchId: v.id("importBatches") },
  returns: v.null(),
  handler: async (ctx, { batchId }) => {
    const batch = await ctx.runQuery(internal.overcastImport.getBatch, { batchId });
    if (!batch || batch.status !== "fetching") return null;
    const podcastIds: Id<"podcasts">[] = await ctx.runMutation(internal.overcastImport.claimPodcasts, { batchId, count: FETCH_BATCH });
    if (podcastIds.length === 0) {
      await ctx.runMutation(internal.overcastImport.finishBatch, { batchId });
      return null;
    }
    const results = await Promise.all(
      podcastIds.map((podcastId) =>
        refreshPodcast(ctx, podcastId, { mode: "import", force: true }).catch((e: Error) => ({
          status: "error" as const,
          newEpisodes: 0,
          error: e.message,
        })),
      ),
    );
    for (const [i, podcastId] of podcastIds.entries()) {
      const feedOk = results[i]!.status !== "error";
      let done = false;
      while (!done) {
        done = await ctx.runMutation(internal.overcastImport.matchPodcast, { batchId, podcastId, feedOk });
      }
    }
    await ctx.scheduler.runAfter(0, internal.importActions.processBatch, { batchId });
    return null;
  },
});
