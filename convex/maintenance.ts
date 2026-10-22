import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { asUser } from "./lib/auth";
import { resolvedSettingsFor } from "./lib/settingsDb";
import { setArchived, systemAt } from "./lib/state";

// Daily housekeeping, run by crons.ts.

const DAY = 86_400_000;
/** Tombstones older than this are dropped; an app offline longer must resync from since = 0. */
export const TOMBSTONE_TTL = 90 * DAY;

export const daily = internalMutation({
  args: {},
  returns: v.object({ archived: v.number(), tombstones: v.number(), cache: v.number() }),
  handler: async (rawCtx) => {
    const now = Date.now();
    let archived = 0;
    let tombstones = 0;

    for (const user of await rawCtx.db.query("users").collect()) {
      if (user.mergedInto) continue;
      const ctx = asUser(rawCtx, user._id);

      // Per-show "auto-archive unplayed after N days" (0 = never), with this person's settings.
      const inbox = await ctx.db
        .query("episodeStates")
        .withIndex("by_user_inbox", (q) => q.eq("userId", user._id).eq("inInbox", true))
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

      const old = await ctx.db
        .query("deletions")
        .withIndex("by_user_updatedAt", (q) => q.eq("userId", user._id).lt("updatedAt", now - TOMBSTONE_TTL))
        .take(500);
      for (const t of old) await ctx.db.delete(t._id);
      tombstones += old.length;
    }

    const cache = await rawCtx.db.query("directoryCache").take(1000);
    let cleared = 0;
    for (const c of cache) {
      if (now - c.fetchedAt > 2 * DAY) {
        await rawCtx.db.delete(c._id);
        cleared++;
      }
    }
    return { archived, tombstones, cache: cleared };
  },
});
