import { generateKeyBetween } from "fractional-indexing";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";

// Up Next: one row per queued episode with a fractional string order key.
// Keys are always computed on the server inside a transaction, so two devices
// moving things "between the same neighbours" can never collide. Every op
// carries the client time `at`; ops older than the item's last change (or its
// removal) are ignored, so replaying an offline outbox can't undo newer work.

export type QueuePosition = "top" | "next" | "bottom";
export type AddedBy = Doc<"queueItems">["addedBy"];

export async function queueItemFor(ctx: QueryCtx, episodeId: Id<"episodes">) {
  return await ctx.db
    .query("queueItems")
    .withIndex("by_episode", (q) => q.eq("episodeId", episodeId))
    .unique();
}

export async function orderedQueue(ctx: QueryCtx) {
  return await ctx.db.query("queueItems").withIndex("by_orderKey").collect();
}

async function queueTombstone(ctx: QueryCtx, episodeId: Id<"episodes">) {
  return await ctx.db
    .query("deletions")
    .withIndex("by_table_episode", (q) => q.eq("table", "queueItems").eq("episodeId", episodeId))
    .unique();
}

/** Keys of the first `n` items, skipping `exclude`. */
async function firstKeys(ctx: QueryCtx, n: number, exclude?: Id<"queueItems">) {
  const items = await ctx.db.query("queueItems").withIndex("by_orderKey").take(n + 1);
  return items.filter((i) => i._id !== exclude).slice(0, n);
}

async function lastItem(ctx: QueryCtx, exclude?: Id<"queueItems">) {
  const items = await ctx.db.query("queueItems").withIndex("by_orderKey").order("desc").take(2);
  return items.find((i) => i._id !== exclude) ?? null;
}

async function itemAfter(ctx: QueryCtx, key: string, exclude?: Id<"queueItems">) {
  const items = await ctx.db
    .query("queueItems")
    .withIndex("by_orderKey", (q) => q.gt("orderKey", key))
    .take(2);
  return items.find((i) => i._id !== exclude) ?? null;
}

async function itemBefore(ctx: QueryCtx, key: string, exclude?: Id<"queueItems">) {
  const items = await ctx.db
    .query("queueItems")
    .withIndex("by_orderKey", (q) => q.lt("orderKey", key))
    .order("desc")
    .take(2);
  return items.find((i) => i._id !== exclude) ?? null;
}

function keyBetween(a: string | null, b: string | null): string {
  if (a !== null && b !== null && a >= b) return generateKeyBetween(a, null);
  return generateKeyBetween(a, b);
}

async function keyFor(ctx: QueryCtx, position: QueuePosition, exclude?: Id<"queueItems">) {
  if (position === "bottom") {
    const last = await lastItem(ctx, exclude);
    return keyBetween(last?.orderKey ?? null, null);
  }
  const [first, second] = await firstKeys(ctx, 2, exclude);
  if (position === "top" || !first) return keyBetween(null, first?.orderKey ?? null);
  return keyBetween(first.orderKey, second?.orderKey ?? null);
}

/** Add an episode to Up Next, or move it if it's already there. Returns false if the op was stale. */
export async function addToQueue(
  ctx: MutationCtx,
  episode: Doc<"episodes">,
  position: QueuePosition,
  at: number,
  addedBy: AddedBy,
): Promise<boolean> {
  const tomb = await queueTombstone(ctx, episode._id);
  if (tomb && tomb.deletedAt > at) return false;
  const existing = await queueItemFor(ctx, episode._id);
  if (existing && existing.orderUpdatedAt > at) return false;
  const orderKey = await keyFor(ctx, position, existing?._id);
  const now = Date.now();
  if (existing) {
    await ctx.db.patch(existing._id, { orderKey, orderUpdatedAt: at, updatedAt: now });
  } else {
    await ctx.db.insert("queueItems", {
      episodeId: episode._id,
      podcastId: episode.podcastId,
      orderKey,
      addedAt: at,
      addedBy,
      orderUpdatedAt: at,
      updatedAt: now,
    });
  }
  return true;
}

/**
 * Place an item directly after `afterEpisodeId` (null = top). If that neighbour
 * has left the queue, fall back to directly before `beforeEpisodeId`.
 */
export async function moveInQueue(
  ctx: MutationCtx,
  episodeId: Id<"episodes">,
  afterEpisodeId: Id<"episodes"> | null,
  beforeEpisodeId: Id<"episodes"> | null | undefined,
  at: number,
): Promise<boolean> {
  const item = await queueItemFor(ctx, episodeId);
  if (!item || item.orderUpdatedAt > at) return false;
  let orderKey: string | undefined;
  const after = afterEpisodeId ? await queueItemFor(ctx, afterEpisodeId) : null;
  if (afterEpisodeId === null) {
    orderKey = await keyFor(ctx, "top", item._id);
  } else if (after && after._id !== item._id) {
    const next = await itemAfter(ctx, after.orderKey, item._id);
    orderKey = keyBetween(after.orderKey, next?.orderKey ?? null);
  } else if (beforeEpisodeId) {
    const before = await queueItemFor(ctx, beforeEpisodeId);
    if (before && before._id !== item._id) {
      const prev = await itemBefore(ctx, before.orderKey, item._id);
      orderKey = keyBetween(prev?.orderKey ?? null, before.orderKey);
    }
  }
  if (!orderKey) return false;
  await ctx.db.patch(item._id, { orderKey, orderUpdatedAt: at, updatedAt: Date.now() });
  return true;
}

export async function removeFromQueue(ctx: MutationCtx, episodeId: Id<"episodes">, at: number): Promise<boolean> {
  const item = await queueItemFor(ctx, episodeId);
  if (item && item.orderUpdatedAt > at) return false;
  if (item) await ctx.db.delete(item._id);
  const now = Date.now();
  const tomb = await queueTombstone(ctx, episodeId);
  if (tomb) {
    await ctx.db.patch(tomb._id, {
      docId: item?._id ?? tomb.docId,
      deletedAt: Math.max(tomb.deletedAt, at),
      updatedAt: now,
    });
  } else {
    await ctx.db.insert("deletions", {
      table: "queueItems",
      docId: item?._id ?? "",
      episodeId,
      deletedAt: at,
      updatedAt: now,
    });
  }
  return item !== null;
}

/** Remove everything that was added or moved at or before `at`. */
export async function clearQueue(ctx: MutationCtx, at: number): Promise<number> {
  const items = await orderedQueue(ctx);
  let removed = 0;
  for (const item of items) {
    if (item.orderUpdatedAt <= at && (await removeFromQueue(ctx, item.episodeId, at))) removed++;
  }
  return removed;
}
