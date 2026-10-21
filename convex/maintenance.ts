import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { resolvedSettingsFor } from "./lib/settingsDb";
import { setArchived, systemAt } from "./lib/state";

// Daily housekeeping, run by crons.ts.

const DAY = 86_400_000;
/** Tombstones older than this are dropped; an app offline longer must resync from since = 0. */
export const TOMBSTONE_TTL = 90 * DAY;

export const daily = internalMutation({
  args: {},
  returns: v.object({ archived: v.number(), tombstones: v.number(), cache: v.number() }),
  handler: async (ctx) => {
    const now = Date.now();

    // Per-show "auto-archive unplayed after N days" (0 = never).
    let archived = 0;
    const inbox = await ctx.db
      .query("episodeStates")
      .withIndex("by_inbox", (q) => q.eq("inInbox", true))
      .take(1000);
    const days = new Map<string, number>();
    for (const s of inbox) {
      if (!days.has(s.podcastId)) days.set(s.podcastId, (await resolvedSettingsFor(ctx, s.podcastId)).autoArchiveUnplayedAfterDays);
      const limit = days.get(s.podcastId)!;
      if (limit > 0 && s.inboxAt !== undefined && now - s.inboxAt > limit * DAY) {
        const episode = await ctx.db.get(s.episodeId);
        if (episode && (await setArchived(ctx, episode, true, systemAt(now)))) archived++;
      }
    }

    const oldTombstones = await ctx.db
      .query("deletions")
      .withIndex("by_updatedAt", (q) => q.lt("updatedAt", now - TOMBSTONE_TTL))
      .take(500);
    for (const t of oldTombstones) await ctx.db.delete(t._id);

    const cache = await ctx.db.query("directoryCache").take(1000);
    let cleared = 0;
    for (const c of cache) {
      if (now - c.fetchedAt > 2 * DAY) {
        await ctx.db.delete(c._id);
        cleared++;
      }
    }
    return { archived, tombstones: oldTombstones.length, cache: cleared };
  },
});
