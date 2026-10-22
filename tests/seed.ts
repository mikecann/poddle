import type { Id } from "../convex/_generated/dataModel";
import type { T } from "./helpers";

export const BASE = Date.UTC(2025, 9, 15);

/** A show with `n` plain episodes, newest last, that `t`'s user subscribes to. Returns ids oldest first. */
export async function seedShow(t: T, n: number, opts: { title?: string; duration?: number } = {}) {
  const userId = await t.userId();
  return await t.run(async (ctx) => {
    const podcastId = await ctx.db.insert("podcasts", {
      feedUrl: `https://feeds.example.com/${opts.title ?? "show"}.xml`,
      title: opts.title ?? "Show",
      isPrivate: false,
      episodeCount: n,
      createdAt: BASE,
      updatedAt: BASE,
    });
    await ctx.db.insert("subscriptions", {
      userId,
      podcastId,
      subscribed: true,
      subscribedAt: BASE,
      subscriptionUpdatedAt: BASE,
      addedAt: BASE,
      updatedAt: BASE,
    });
    const episodeIds: Id<"episodes">[] = [];
    for (let i = 0; i < n; i++) {
      episodeIds.push(
        await ctx.db.insert("episodes", {
          podcastId,
          title: `Ep ${i}`,
          guid: `${opts.title ?? "show"}-${i}`,
          enclosureUrl: `https://cdn.example.com/${opts.title ?? "show"}/${i}.mp3`,
          pubDate: BASE + i * 86_400_000,
          duration: opts.duration ?? 3600,
          transcripts: [],
          isGhost: false,
          firstSeenAt: BASE,
          updatedAt: BASE,
        }),
      );
    }
    return { podcastId, episodeIds };
  });
}

/**
 * Puts episodes in `t`'s old Inbox, the way the retired code did. Nothing does
 * that any more; this is the data `migrations:retireInbox` cleans up.
 */
export async function seedInbox(t: T, episodeIds: Id<"episodes">[], at = BASE) {
  const userId = await t.userId();
  await t.run(async (ctx) => {
    for (const episodeId of episodeIds) {
      const episode = (await ctx.db.get(episodeId))!;
      const inbox = { inInbox: true, inboxAt: episode.pubDate ?? at, inboxUpdatedAt: at, updatedAt: at };
      const existing = await ctx.db
        .query("episodeStates")
        .withIndex("by_user_episode", (q) => q.eq("userId", userId).eq("episodeId", episodeId))
        .unique();
      if (existing) {
        await ctx.db.patch(existing._id, inbox);
        continue;
      }
      await ctx.db.insert("episodeStates", {
        userId,
        episodeId,
        podcastId: episode.podcastId,
        position: 0,
        positionUpdatedAt: 0,
        played: false,
        playedUpdatedAt: 0,
        starred: false,
        starredUpdatedAt: 0,
        archived: false,
        archivedUpdatedAt: 0,
        ...inbox,
      });
    }
  });
}
