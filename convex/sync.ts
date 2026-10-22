import { paginationOptsValidator } from "convex/server";
import { v } from "convex/values";
import { stream } from "convex-helpers/server/stream";
import schema from "./schema";
import { userQuery, type UserQueryCtx } from "./lib/auth";
import { podcastView } from "./lib/library";
import {
  vDeletionDoc,
  vDeviceDoc,
  vEpisodeDoc,
  vEpisodeStateDoc,
  vGlobalSettingsDoc,
  vImportBatchDoc,
  vLibraryEventDoc,
  vPodcastDoc,
  vPodcastSettingsDoc,
  vQueueItemDoc,
  vSessionDoc,
} from "./lib/validators";

// Offline catch-up, for the caller's data only. For each synced table the app
// keeps a `since` cursor (the largest `updatedAt` it has stored) and pages
// through everything changed at or after `since - OVERLAP_MS`. Re-delivered rows
// are harmless (upsert by `_id`). `deletions` reports removed rows. since = 0 is
// a full snapshot. See docs/api.md, "Offline and outbox contract".
//
// Personal tables are read straight off their `by_user_updatedAt` index. The
// shared shows and episodes come through the caller's library (`subscriptions`):
// a show is sent when it or the caller's subscription changed, and its episodes
// when they changed, or all of them if the show joined the library since `since`.

/**
 * Mutations stamp `updatedAt` when they start, but commit a moment later, so a
 * row can appear with an `updatedAt` slightly below a cursor the app already
 * holds. Re-reading a short overlap closes that gap.
 */
export const OVERLAP_MS = 30_000;

const PERSONAL_TABLES = [
  "episodeStates",
  "queueItems",
  "podcastSettings",
  "globalSettings",
  "listeningSessions",
  "libraryEvents",
  "devices",
  "importBatches",
  "deletions",
] as const;

export const SYNC_TABLES = ["podcasts", "episodes", ...PERSONAL_TABLES] as const;

const vSyncTable = v.union(...SYNC_TABLES.map((t) => v.literal(t)));

type PaginationOpts = { numItems: number; cursor: string | null };

function libraryRows(ctx: UserQueryCtx) {
  return stream(ctx.db, schema)
    .query("subscriptions")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId));
}

async function podcastChanges(ctx: UserQueryCtx, from: number, opts: PaginationOpts) {
  return await libraryRows(ctx)
    .map(async (sub) => {
      const p = await ctx.db.get(sub.podcastId);
      if (!p) return null;
      const view = podcastView(p, sub);
      return view.updatedAt >= from ? view : null;
    })
    .paginate({ ...opts, maximumRowsRead: 2000 });
}

async function episodeChanges(ctx: UserQueryCtx, from: number, opts: PaginationOpts) {
  return await libraryRows(ctx)
    .flatMap(
      async (sub) =>
        stream(ctx.db, schema)
          .query("episodes")
          .withIndex("by_podcast_updatedAt", (q) =>
            sub.addedAt >= from ? q.eq("podcastId", sub.podcastId) : q.eq("podcastId", sub.podcastId).gte("updatedAt", from),
          ),
      ["podcastId", "updatedAt"],
    )
    .paginate(opts);
}

export const changes = userQuery({
  args: {
    table: vSyncTable,
    since: v.number(),
    paginationOpts: paginationOptsValidator,
  },
  returns: v.object({
    page: v.array(
      v.union(
        vPodcastDoc,
        vEpisodeDoc,
        vEpisodeStateDoc,
        vQueueItemDoc,
        vPodcastSettingsDoc,
        vGlobalSettingsDoc,
        vSessionDoc,
        vLibraryEventDoc,
        vDeviceDoc,
        vImportBatchDoc,
        vDeletionDoc,
      ),
    ),
    isDone: v.boolean(),
    continueCursor: v.string(),
    /** Largest updatedAt in this page; store the max across pages as the next `since`. */
    maxUpdatedAt: v.union(v.number(), v.null()),
  }),
  handler: async (ctx, { table, since, paginationOpts }) => {
    const from = since > 0 ? since - OVERLAP_MS : 0;
    const result =
      table === "podcasts"
        ? await podcastChanges(ctx, from, paginationOpts)
        : table === "episodes"
          ? await episodeChanges(ctx, from, paginationOpts)
          : await ctx.db
              .query(table)
              .withIndex("by_user_updatedAt", (q) => q.eq("userId", ctx.userId).gte("updatedAt", from))
              .paginate(paginationOpts);
    const page = result.page as { updatedAt: number }[];
    const max = page.reduce<number | null>((m, d) => Math.max(m ?? 0, d.updatedAt), null);
    return { page: result.page, isDone: result.isDone, continueCursor: result.continueCursor, maxUpdatedAt: max };
  },
});
