import type { Id } from "../_generated/dataModel";
import type { UserMutationCtx as MutationCtx } from "./auth";
import { removeFromQueue } from "./queue";
import { resolveGlobalSettings, type KeepLatest } from "./settings";
import { globalSettingsDoc, overridesOf, podcastSettingsDoc, resolvedSettingsFor } from "./settingsDb";

// "Keep latest N" limits Up Next as well as downloads, like Overcast's episode limit
// (decisions.md, 25 Oct 2026). Of a show's episodes in Up Next, the newest N stay and older
// unplayed ones come out, the same as "remove from Up Next": not played, not archived, still on
// the show's page. Some always stay: an episode that's been started (it has a saved position),
// played or starred (Overcast spares starred ones too), and the first item, which is what's
// playing. "all" takes nothing out.
// Adding an episode by hand doesn't trim; the next new episode or settings change does.

/**
 * Trims one show's Up Next to its limit and returns how many came out. `at` is the LWW time of
 * the removals: a settings change's own `at`, so anything queued or moved after it stays, or
 * `{ system: systemAt(now) }` when a new episode arrives. That one takes out whatever is there at
 * that moment, recorded no earlier than each item's last change so the removal always applies.
 */
export async function trimToKeepLatest(
  ctx: MutationCtx,
  podcastId: Id<"podcasts">,
  limit: KeepLatest,
  at: number | { system: number },
): Promise<number> {
  if (limit === "all") return 0;
  // The UI goes from 1 to 50. Anything else from a script still keeps at least one.
  const keep = Math.max(1, Math.floor(limit));
  const items = await ctx.db
    .query("queueItems")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId).eq("podcastId", podcastId))
    .collect();
  if (items.length <= keep) return 0;
  const first = await ctx.db
    .query("queueItems")
    .withIndex("by_user_orderKey", (q) => q.eq("userId", ctx.userId))
    .first();

  const queued = [];
  for (const item of items) {
    const episode = await ctx.db.get(item.episodeId);
    queued.push({ item, publishedAt: episode?.pubDate ?? episode?.firstSeenAt ?? item.addedAt });
  }
  queued.sort((a, b) => b.publishedAt - a.publishedAt);

  let removed = 0;
  for (const { item } of queued.slice(keep)) {
    if (item._id === first?._id) continue;
    const state = await ctx.db
      .query("episodeStates")
      .withIndex("by_user_episode", (q) => q.eq("userId", ctx.userId).eq("episodeId", item.episodeId))
      .unique();
    if (state && (state.position > 0 || state.played || state.starred)) continue;
    const removeAt = typeof at === "number" ? at : Math.max(at.system, item.orderUpdatedAt);
    if (await removeFromQueue(ctx, item.episodeId, removeAt)) removed++;
  }
  return removed;
}

/** After a show's "Keep latest" changed (or was reset to the default): trim it straight away. */
export async function trimShowAfterChange(ctx: MutationCtx, podcastId: Id<"podcasts">, at: number) {
  const { keepLatestDownloaded } = await resolvedSettingsFor(ctx, podcastId);
  return await trimToKeepLatest(ctx, podcastId, keepLatestDownloaded, at);
}

/** After the default "Keep latest" changed: trim every show in Up Next that follows it. */
export async function trimInheritingShows(ctx: MutationCtx, at: number) {
  const limit = resolveGlobalSettings(await globalSettingsDoc(ctx)).keepLatest;
  if (limit === "all") return 0;
  const queue = await ctx.db
    .query("queueItems")
    .withIndex("by_user_orderKey", (q) => q.eq("userId", ctx.userId))
    .collect();
  let removed = 0;
  for (const podcastId of new Set(queue.map((i) => i.podcastId))) {
    if (overridesOf(await podcastSettingsDoc(ctx, podcastId)).keepLatestDownloaded !== undefined) continue;
    removed += await trimToKeepLatest(ctx, podcastId, limit, at);
  }
  return removed;
}
