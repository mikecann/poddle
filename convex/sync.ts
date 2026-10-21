import { paginationOptsValidator } from "convex/server";
import { v } from "convex/values";
import { userQuery } from "./lib/auth";
import {
  vDeletionDoc,
  vDeviceDoc,
  vEpisodeDoc,
  vEpisodeNotesDoc,
  vEpisodeStateDoc,
  vGlobalSettingsDoc,
  vImportBatchDoc,
  vLibraryEventDoc,
  vPodcastDoc,
  vPodcastSettingsDoc,
  vQueueItemDoc,
  vSessionDoc,
} from "./lib/validators";

// Offline catch-up. For each synced table the app keeps a `since` cursor (the
// largest `updatedAt` it has stored) and pages through everything changed at or
// after `since - OVERLAP_MS`. Re-delivered rows are harmless (upsert by `_id`).
// `deletions` reports removed rows (queue items, devices). since = 0 is a full
// snapshot. See docs/api.md, "Offline and outbox contract".

/**
 * Mutations stamp `updatedAt` when they start, but commit a moment later, so a
 * row can appear with an `updatedAt` slightly below a cursor the app already
 * holds. Re-reading a short overlap closes that gap.
 */
export const OVERLAP_MS = 30_000;

export const SYNC_TABLES = [
  "podcasts",
  "episodes",
  "episodeNotes",
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

const vSyncTable = v.union(...SYNC_TABLES.map((t) => v.literal(t)));

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
        vEpisodeNotesDoc,
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
    const result = await ctx.db
      .query(table)
      .withIndex("by_updatedAt", (q) => q.gte("updatedAt", from))
      .paginate(paginationOpts);
    const max = result.page.reduce<number | null>((m, d) => Math.max(m ?? 0, d.updatedAt), null);
    return { page: result.page, isDone: result.isDone, continueCursor: result.continueCursor, maxUpdatedAt: max };
  },
});
