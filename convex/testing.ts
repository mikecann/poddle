import { v } from "convex/values";
import type { TableNames } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { action, internalQuery, mutation } from "./_generated/server";
import { assertE2e } from "./lib/e2e";
import { normalizeFeedUrl } from "./lib/parse";
import schema from "./schema";

// Hooks for the end-to-end suites (docs/testing.md), on their throwaway local
// backend only: every function needs PODDLE_E2E=1, a 127.0.0.1 deployment and
// the admin token (lib/e2e.ts). Seeding goes through the public functions with
// the admin path, like the scripts; these are only what no public function does.

const TABLES = Object.keys(schema.tables) as TableNames[];
/** Rows deleted per call, well under a mutation's limits. The caller repeats while `more`. */
const BATCH = 2000;

/**
 * Empties every app table and cancels whatever's scheduled, so each scenario
 * starts from nothing. Convex Auth's own tables are left: their sessions point at
 * users that no longer exist, which reads as signed out.
 */
export const reset = mutation({
  args: { token: v.string() },
  returns: v.object({ deleted: v.number(), more: v.boolean() }),
  handler: async (ctx, { token }) => {
    assertE2e(token);
    let deleted = 0;
    for (const table of TABLES) {
      for (const doc of await ctx.db.query(table).take(BATCH - deleted)) {
        await ctx.db.delete(doc._id);
        deleted++;
      }
      if (deleted >= BATCH) return { deleted, more: true };
    }
    for (const job of await ctx.db.system.query("_scheduled_functions").collect()) {
      if (job.state.kind === "pending" || job.state.kind === "inProgress") await ctx.scheduler.cancel(job._id);
    }
    return { deleted, more: false };
  },
});

export const podcastByFeedUrl = internalQuery({
  args: { feedUrl: v.string() },
  returns: v.union(v.id("podcasts"), v.null()),
  handler: async (ctx, { feedUrl }) => {
    const podcast = await ctx.db
      .query("podcasts")
      .withIndex("by_feedUrl", (q) => q.eq("feedUrl", feedUrl))
      .unique();
    return podcast?._id ?? null;
  },
});

/**
 * Fetches a show's feed now, the way the 15-minute poll would, so a scenario can
 * add an episode to a fixture feed and see it arrive without waiting.
 */
export const refreshFeed = action({
  args: { token: v.string(), feedUrl: v.string() },
  returns: v.object({ status: v.string(), newEpisodes: v.number(), error: v.optional(v.string()) }),
  handler: async (ctx, { token, feedUrl }): Promise<{ status: string; newEpisodes: number; error?: string }> => {
    assertE2e(token);
    const podcastId = await ctx.runQuery(internal.testing.podcastByFeedUrl, { feedUrl: normalizeFeedUrl(feedUrl) });
    if (!podcastId) throw new Error(`No show with feed ${feedUrl}`);
    return await ctx.runAction(internal.feedActions.fetchFeed, { podcastId, force: true });
  },
});
