import { v } from "convex/values";
import { internalQuery } from "./_generated/server";

// Whole-app numbers for Mike's Threadbear panel (.threadbear/patches/poddle.ts), through
// `npx convex run --prod adminStats:overview`. Internal, so nothing outside the deployment's admins
// can call it, and it only returns counts: no names, emails or what any one person listens to.
//
// It reads the same rollups as the Stats screen rather than raw sessions, so its size follows the
// number of people, not how much they've listened.

const DAY = 86_400_000;
const isoDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

const vPeriod = v.object({ activeUsers: v.number(), liveHours: v.number(), listens: v.number(), completed: v.number() });

export const overview = internalQuery({
  args: {},
  returns: v.object({
    users: v.number(),
    newUsers7d: v.number(),
    newUsers30d: v.number(),
    last7d: vPeriod,
    last30d: vPeriod,
    allTime: v.object({
      liveHours: v.number(),
      /** History brought over from Overcast: guessed from played episodes, not actually heard in Poddle. */
      importedHours: v.number(),
      /** Includes Overcast imports: the rollups count sessions without saying which were estimated. */
      listens: v.number(),
      completed: v.number(),
    }),
    follows: v.number(),
    shows: v.number(),
  }),
  handler: async (ctx) => {
    const now = Date.now();
    // Rollup days are each person's local day, so these windows can be out by a few hours. Fine here.
    const since7 = isoDay(now - 7 * DAY);
    const since30 = isoDay(now - 30 * DAY);

    const last7d = { activeUsers: 0, liveHours: 0, listens: 0, completed: 0 };
    const last30d = { activeUsers: 0, liveHours: 0, listens: 0, completed: 0 };
    const allTime = { liveHours: 0, importedHours: 0, listens: 0, completed: 0 };
    let users = 0;
    let newUsers7d = 0;
    let newUsers30d = 0;
    let follows = 0;

    for (const user of await ctx.db.query("users").collect()) {
      // A merged row is the same person as another, a deleted one is a tombstone, and test users aren't people.
      if (user.mergedInto || user.deletedAt !== undefined || user.isTest) continue;
      users++;
      if (user._creationTime >= now - 7 * DAY) newUsers7d++;
      if (user._creationTime >= now - 30 * DAY) newUsers30d++;

      const months = await ctx.db
        .query("statsMonths")
        .withIndex("by_user_month", (q) => q.eq("userId", user._id))
        .collect();
      for (const m of months) {
        allTime.liveHours += (m.wall - m.estimatedWall) / 3600;
        allTime.importedHours += m.estimatedWall / 3600;
        allTime.listens += m.sessions;
        allTime.completed += m.episodesCompleted;
      }

      const days = await ctx.db
        .query("statsDays")
        .withIndex("by_user_day", (q) => q.eq("userId", user._id).gte("day", since30))
        .collect();
      // An Overcast import writes rollups for old days only, but a played-yesterday episode could
      // land in this window: only time really heard makes someone active.
      const live = days.filter((d) => d.wall - d.estimatedWall > 0);
      for (const [period, from] of [
        [last30d, since30],
        [last7d, since7],
      ] as const) {
        const inPeriod = live.filter((d) => d.day >= from);
        if (inPeriod.length > 0) period.activeUsers++;
        for (const d of inPeriod) {
          period.liveHours += (d.wall - d.estimatedWall) / 3600;
          period.listens += d.sessions;
          period.completed += d.episodesCompleted;
        }
      }

      const subscriptions = await ctx.db
        .query("subscriptions")
        .withIndex("by_user_subscribed", (q) => q.eq("userId", user._id).eq("subscribed", true))
        .collect();
      follows += subscriptions.length;
    }

    const shows = (await ctx.db.query("podcasts").collect()).length;
    return { users, newUsers7d, newUsers30d, last7d, last30d, allTime, follows, shows };
  },
});
