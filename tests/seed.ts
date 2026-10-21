import type { Id } from "../convex/_generated/dataModel";
import type { T } from "./helpers";

export const BASE = Date.UTC(2025, 9, 15);

/** A subscribed show with `n` plain episodes, newest last. Returns ids oldest first. */
export async function seedShow(t: T, n: number, opts: { title?: string; duration?: number } = {}) {
  return await t.run(async (ctx) => {
    const podcastId = await ctx.db.insert("podcasts", {
      feedUrl: `https://feeds.example.com/${opts.title ?? "show"}.xml`,
      title: opts.title ?? "Show",
      isPrivate: false,
      subscribed: true,
      subscribedAt: BASE,
      subscriptionUpdatedAt: BASE,
      episodeCount: n,
      createdAt: BASE,
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
