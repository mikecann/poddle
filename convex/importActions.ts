"use node";

import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import { refreshPodcast } from "./lib/feedFetch";
import { parseOvercastOpml, upNextPlan, type OvercastFeed } from "./lib/opml";

// Node side of the Overcast import: parsing the file and fetching feeds.
// See overcastImport.ts for the pipeline.

const STAGE_CHUNK_BYTES = 300_000;
/** Pause between staging chunks, and backoff when the deployment's write rate limit pushes back. */
const STAGE_PAUSE_MS = 250;
const STAGE_RETRIES = 4;
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
      for (const [i, chunk] of chunkFeeds(parsed.feeds).entries()) {
        if (i > 0) await sleep(STAGE_PAUSE_MS);
        const feeds = chunk.map(({ htmlUrl: _h, episodes, ...f }) => ({
          ...f,
          episodes: episodes.map(({ overcastUrl: _o, ...e }) => e),
        }));
        for (let attempt = 0; ; attempt++) {
          try {
            await ctx.runMutation(internal.overcastImport.stageFeeds, { batchId, feeds });
            break;
          } catch (e) {
            if (attempt >= STAGE_RETRIES || !/too many writes|rate limit/i.test((e as Error).message)) throw e;
            await sleep(1000 * 2 ** attempt);
          }
        }
      }
      await ctx.runMutation(internal.overcastImport.beginFetching, {
        batchId,
        warning: parsed.hasEpisodeData
          ? undefined
          : "This looks like the plain subscriptions export. Use Overcast's \"All data\" export to bring in history.",
        playlists: parsed.playlists,
        upNextPlan: upNextPlan(parsed.playlists),
      });
      if (storageId) await ctx.storage.delete(storageId);
    } catch (e) {
      await ctx.runMutation(internal.overcastImport.failBatch, { batchId, error: (e as Error).message });
    }
    return null;
  },
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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

/**
 * Fetch a handful of feeds, then schedule the next handful. Once every feed is
 * in, match a handful of shows per run instead, then finish.
 */
export const processBatch = internalAction({
  args: { batchId: v.id("importBatches") },
  returns: v.null(),
  handler: async (ctx, { batchId }) => {
    const batch = await ctx.runQuery(internal.overcastImport.getBatch, { batchId });
    if (!batch || batch.status !== "fetching") return null;
    const fetches = await ctx.runMutation(internal.overcastImport.claimFetches, { batchId, count: FETCH_BATCH });
    if (fetches.length) {
      const results = await Promise.all(
        fetches.map(({ podcastId }) =>
          refreshPodcast(ctx, podcastId, { mode: "import", force: true }).catch((e: Error) => ({
            status: "error" as const,
            newEpisodes: 0,
            error: e.message,
            httpStatus: undefined,
          })),
        ),
      );
      for (const [i, { rowId }] of fetches.entries()) {
        const r = results[i]!;
        await ctx.runMutation(internal.overcastImport.feedFetched, {
          batchId,
          rowId,
          ok: r.status !== "error",
          status: r.httpStatus,
          error: r.error,
        });
      }
    } else {
      const rows = await ctx.runMutation(internal.overcastImport.claimMatches, { batchId, count: FETCH_BATCH });
      if (rows.length === 0) {
        await ctx.runMutation(internal.overcastImport.finishBatch, { batchId });
        return null;
      }
      for (const row of rows) {
        let done = false;
        while (!done) done = await ctx.runMutation(internal.overcastImport.matchPodcast, { batchId, row });
      }
    }
    await ctx.scheduler.runAfter(0, internal.importActions.processBatch, { batchId });
    return null;
  },
});
