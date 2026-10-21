import { v } from "convex/values";
import { userMutation, userQuery } from "./lib/auth";
import { addToQueue, clearQueue, moveInQueue, orderedQueue, removeFromQueue } from "./lib/queue";
import { episodeRows } from "./lib/rows";
import { requireEpisode, setInbox } from "./lib/state";
import { vEpisodeRow, vQueueItemDoc } from "./lib/validators";

// Up Next. The first item is what's playing. Order keys are computed here, not
// on the client, so concurrent moves from two devices can't collide.

/** The queue in play order, each item joined with its episode, state and show. */
export const upNext = userQuery({
  args: {},
  returns: v.array(v.object({ item: vQueueItemDoc, row: vEpisodeRow })),
  handler: async (ctx) => {
    const items = await orderedQueue(ctx);
    const out = [];
    for (const item of items) {
      const episode = await ctx.db.get(item.episodeId);
      if (!episode) continue;
      const [row] = await episodeRows(ctx, [episode]);
      if (row) out.push({ item, row });
    }
    return out;
  },
});

/**
 * Add to Up Next. `top` = play now position, `next` = straight after the
 * current (first) item, `bottom` = the end. Moves it if already queued.
 * Takes it out of the Inbox. Returns false if a newer change wins.
 */
export const add = userMutation({
  args: {
    episodeId: v.id("episodes"),
    position: v.union(v.literal("top"), v.literal("next"), v.literal("bottom")),
    at: v.number(),
  },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, position, at }) => {
    const episode = await requireEpisode(ctx, episodeId);
    const added = await addToQueue(ctx, episode, position, at, "manual");
    if (added) await setInbox(ctx, episode, false, at);
    return added;
  },
});

/** Play now: moves it to the top, so the current item becomes second. */
export const playNow = userMutation({
  args: { episodeId: v.id("episodes"), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, at }) => {
    const episode = await requireEpisode(ctx, episodeId);
    const added = await addToQueue(ctx, episode, "top", at, "manual");
    if (added) await setInbox(ctx, episode, false, at);
    return added;
  },
});

/**
 * Reorder: place the item directly after `afterEpisodeId` (null = top). If that
 * neighbour has since left the queue, it goes directly before `beforeEpisodeId`.
 */
export const move = userMutation({
  args: {
    episodeId: v.id("episodes"),
    afterEpisodeId: v.union(v.id("episodes"), v.null()),
    beforeEpisodeId: v.optional(v.union(v.id("episodes"), v.null())),
    at: v.number(),
  },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, afterEpisodeId, beforeEpisodeId, at }) => {
    return await moveInQueue(ctx, episodeId, afterEpisodeId, beforeEpisodeId, at);
  },
});

export const remove = userMutation({
  args: { episodeId: v.id("episodes"), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, at }) => await removeFromQueue(ctx, episodeId, at),
});

/** Clear Up Next. Only removes items added or moved at or before `at`. */
export const clear = userMutation({
  args: { at: v.number() },
  returns: v.number(),
  handler: async (ctx, { at }) => await clearQueue(ctx, at),
});
