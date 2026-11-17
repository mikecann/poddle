import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server";
import { ensureFeedState } from "./feeds";
import { asUser, userMutation, userQuery, type UserMutationCtx } from "./lib/auth";
import { ensureLibraryRow, hasSubscribers, subscriptionFor } from "./lib/library";
import { findByEnclosure, findByGuid, findByLink, findByTitleDate, findByUniqueTitle } from "./lib/ingest";
import { countsAsListened } from "./lib/opml";
import { enclosureKey } from "./lib/parse";
import { addToQueue, queueItemFor, type AddedBy } from "./lib/queue";
import { getOrCreatePodcast, setSubscribed } from "./podcasts";
import { upsertSession } from "./sessions";
import { setArchived, setPlayed, setPosition, setStarred, stateFor, userUtcOffset } from "./lib/state";
import { mirrorBatch, mirrorShow } from "./lib/importStates";
import { vImportBatchDoc } from "./lib/validators";

// Overcast "All data" import (spec §2.2, decisions.md), into the library of
// whoever started it (the batch's `userId`). Pipeline:
//   startOvercastImport → importActions.parse (stage podcasts + episodes)
//   → importActions.processBatch, repeatedly: fetch a few feeds; once every feed
//     is in, match each show's staged episodes, creating ghosts, states and
//     estimated sessions (fetching first means the overall median duration is
//     known for shows with none of their own)
//   → finishBatch seeds Up Next in Overcast's main-playlist order → done.
// Counts on the importBatches doc update live for the app's receipt.
// Re-running is safe: podcasts match by overcastId / feed URL, state is LWW on
// Overcast's dates, sessions and events have deterministic ids, and Up Next
// only gains episodes that aren't already queued or since removed.
//
// The batch's lifecycle is `BATCH_MOVES` below, and every status change goes
// through `moveBatch`, so a late result (a parse or worker run that outlived
// its batch) can't move it backwards or finish it twice. The worker chain can
// die (an action that throws or is lost), so the `resumeStalled` cron watches
// for batches that stop making progress: it starts a new run of the chain,
// which picks up where the old one stopped, and gives up after a few tries.
// A show's queue row stays until its episodes are all matched, so nothing a
// dead run had claimed is lost.

type ImportStatus = Doc<"importBatches">["status"];

/** Where each status may go next. done and failed are final. */
const BATCH_MOVES: Record<ImportStatus, readonly ImportStatus[]> = {
  parsing: ["fetching", "failed"],
  fetching: ["done", "failed"],
  done: [],
  failed: [],
};

/** Moves the batch on if its lifecycle allows it from where it is now. False (and nothing written) if not. */
async function moveBatch(
  ctx: MutationCtx,
  batch: Doc<"importBatches">,
  to: ImportStatus,
  patch: Partial<Doc<"importBatches">> = {},
): Promise<boolean> {
  if (!BATCH_MOVES[batch.status].includes(to)) return false;
  const now = Date.now();
  const final = BATCH_MOVES[to].length === 0;
  await ctx.db.patch(batch._id, { ...patch, status: to, ...(final ? { finishedAt: now } : {}), updatedAt: now });
  await mirrorBatch(ctx, batch._id);
  // A finished or failed batch's leftover scratch rows go, a page at a time.
  if (to === "failed") await ctx.scheduler.runAfter(0, internal.overcastImport.discardScratch, { batchId: batch._id });
  return true;
}

/** No progress for this long and the watchdog starts the worker again. */
export const IMPORT_STALL_MS = 5 * 60_000;
/** Reading the file is one action, which Convex stops after 10 minutes. */
export const PARSE_STALL_MS = 15 * 60_000;
/** Restarts in a row without progress before the import gives up. */
const MAX_RESTARTS = 3;
/** A fetch claim older than this belongs to a run that died, and another may take it. */
const CLAIM_STALE_MS = 3 * 60_000;
/** Another fetch of the feed is running: try again this much later, this many times (past its 5-minute lease). */
const BUSY_RETRY_MS = 30_000;
const BUSY_LIMIT = 12;

/** Upload URL for the OPML file (POST the file, then pass the storageId). */
export const generateUploadUrl = userMutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => await ctx.storage.generateUploadUrl(),
});

const emptyCounts = (): Doc<"importBatches">["counts"] => ({
  podcasts: 0,
  subscribedPodcasts: 0,
  podcastsProcessed: 0,
  feedsFailed: 0,
  episodes: 0,
  episodesMatched: 0,
  ghostEpisodes: 0,
  playedEpisodes: 0,
  inProgressEpisodes: 0,
  starredEpisodes: 0,
  ghostsOlderThanFeed: 0,
  ghostsMissingFromFeed: 0,
  ghostsFeedFailed: 0,
  sessions: 0,
  estimatedDurationSessions: 0,
  estimatedListenSeconds: 0,
  upNextEpisodes: 0,
});

/**
 * Start an import from an uploaded file (`storageId`) or the OPML text (`opml`).
 * `assumedSpeed` is the speed he usually listened at, used to estimate listening time.
 */
export const startOvercastImport = userMutation({
  args: {
    storageId: v.optional(v.id("_storage")),
    opml: v.optional(v.string()),
    assumedSpeed: v.number(),
  },
  returns: v.id("importBatches"),
  handler: async (ctx, { storageId, opml, assumedSpeed }) => {
    if (!storageId && !opml) throw new Error("Pass storageId or opml");
    if (!(assumedSpeed >= 0.5 && assumedSpeed <= 3)) throw new Error("assumedSpeed must be between 0.5 and 3");
    const now = Date.now();
    const batchId = await ctx.db.insert("importBatches", {
      userId: ctx.userId,
      source: "overcast",
      status: "parsing",
      assumedSpeed,
      startedAt: now,
      counts: emptyCounts(),
      playlists: [],
      updatedAt: now,
    });
    await mirrorBatch(ctx, batchId);
    await ctx.scheduler.runAfter(0, internal.importActions.parse, { batchId, storageId, opml });
    return batchId;
  },
});

/** Live progress for the import receipt. */
export const getImport = userQuery({
  args: { batchId: v.id("importBatches") },
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx, { batchId }) => {
    const batch = await ctx.db.get(batchId);
    return batch?.userId === ctx.userId ? batch : null;
  },
});

export const latestImport = userQuery({
  args: {},
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx) =>
    await ctx.db
      .query("importBatches")
      .withIndex("by_user_startedAt", (q) => q.eq("userId", ctx.userId))
      .order("desc")
      .first(),
});

/** The batch and a ctx acting as its owner. */
async function batchCtx(ctx: MutationCtx, batchId: Id<"importBatches">) {
  const batch = await ctx.db.get(batchId);
  if (!batch?.userId) return null;
  return { batch, ctx: asUser(ctx, batch.userId) };
}

// ---- Internal steps ----

export const getBatch = internalQuery({
  args: { batchId: v.id("importBatches") },
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx, { batchId }) => await ctx.db.get(batchId),
});

type Counts = Doc<"importBatches">["counts"];

/** Adds to the batch's counts. Every call is progress, which the watchdog looks for in `updatedAt`. */
async function bumpCounts(ctx: MutationCtx, batchId: Id<"importBatches">, delta: Partial<Counts>) {
  const batch = await ctx.db.get(batchId);
  if (!batch) return;
  const counts = { ...batch.counts };
  for (const [k, val] of Object.entries(delta) as [keyof Counts, number | undefined][]) {
    if (val === undefined) continue;
    if (k === "earliestListenAt") counts.earliestListenAt = Math.min(counts.earliestListenAt ?? Infinity, val);
    else counts[k] = (counts[k] ?? 0) + val;
  }
  await ctx.db.patch(batchId, { counts, ...progressed(batch) });
  if (batch.restarts) await mirrorBatch(ctx, batchId);
}

/** What a step that got somewhere writes: the time the watchdog checks, and no restarts owed. */
function progressed(batch: Doc<"importBatches">) {
  return { updatedAt: Date.now(), ...(batch.restarts ? { restarts: 0 } : {}) };
}

const vStagedEpisode = v.object({
  overcastId: v.number(),
  title: v.string(),
  url: v.optional(v.string()),
  enclosureUrl: v.optional(v.string()),
  pubDate: v.optional(v.number()),
  played: v.boolean(),
  progress: v.optional(v.number()),
  userDeleted: v.boolean(),
  userUpdatedAt: v.optional(v.number()),
  userRecommendedAt: v.optional(v.number()),
});

/** Create (or find) the shows from one chunk of the export and stage their episodes. */
export const stageFeeds = internalMutation({
  args: {
    batchId: v.id("importBatches"),
    feeds: v.array(
      v.object({
        overcastId: v.optional(v.number()),
        title: v.string(),
        feedUrl: v.string(),
        subscribed: v.boolean(),
        notifications: v.boolean(),
        addedAt: v.optional(v.number()),
        episodes: v.array(vStagedEpisode),
      }),
    ),
  },
  returns: v.null(),
  handler: async (rawCtx, { batchId, feeds }) => {
    const owned = await batchCtx(rawCtx, batchId);
    // A parse that outlived its batch (the watchdog failed it) stages nothing.
    if (!owned || owned.batch.status !== "parsing") return null;
    const { ctx } = owned;
    let subscribed = 0;
    let episodes = 0;
    for (const feed of feeds) {
      const byOvercast =
        feed.overcastId !== undefined
          ? await ctx.db
              .query("podcasts")
              .withIndex("by_overcastId", (q) => q.eq("overcastId", feed.overcastId))
              .first()
          : null;
      const podcast = byOvercast ?? (await getOrCreatePodcast(ctx, { feedUrl: feed.feedUrl, title: feed.title, overcastId: feed.overcastId }));
      if (feed.overcastId !== undefined && podcast.overcastId === undefined) {
        await ctx.db.patch(podcast._id, { overcastId: feed.overcastId });
      }
      // LWW on Overcast's added date, so anything changed in Poddle since wins.
      const at = feed.addedAt ?? 1;
      if (feed.subscribed) {
        await setSubscribed(ctx, podcast, true, at);
        subscribed++;
      } else {
        await importUnsubscribed(ctx, podcast, at, feed.addedAt);
      }
      if (feed.notifications) await setShowOverride(ctx, podcast._id, { notifications: true }, at);
      // The import fetches the feed itself; keep the poller off it until then.
      const stateId = await ensureFeedState(ctx, podcast._id, await hasSubscribers(ctx, podcast._id), false);
      await ctx.db.patch(stateId, { nextCheckAt: Date.now() + 6 * 3600_000 });

      let newestExportedAt: number | undefined;
      for (const e of feed.episodes) {
        await ctx.db.insert("importItems", { batchId, podcastId: podcast._id, ...e });
        if (e.pubDate !== undefined) newestExportedAt = Math.max(newestExportedAt ?? -Infinity, e.pubDate);
      }
      episodes += feed.episodes.length;
      const rowId = await ctx.db.insert("importQueue", { batchId, podcastId: podcast._id, phase: "fetch", newestExportedAt, addedAt: feed.addedAt });
      await mirrorShow(ctx, rowId);
    }
    await bumpCounts(ctx, batchId, { podcasts: feeds.length, subscribedPodcasts: subscribed, episodes });
    return null;
  },
});

/**
 * A show Overcast has as unsubscribed. New shows just get their added date.
 * A show an earlier import wrongly subscribed (it read a missing `subscribed`
 * as "1") is put back, and that run's "subscribed" event removed, unless
 * he's changed the subscription in Poddle since.
 */
async function importUnsubscribed(ctx: UserMutationCtx, podcast: Doc<"podcasts">, at: number, addedAt: number | undefined) {
  const sub = await ensureLibraryRow(ctx, podcast._id);
  const now = Date.now();
  if (sub.subscriptionUpdatedAt === 0) {
    await ctx.db.patch(sub._id, { subscriptionUpdatedAt: at, subscribedAt: sub.subscribedAt ?? addedAt, updatedAt: now });
    return;
  }
  if (!sub.subscribed || sub.subscriptionUpdatedAt > at) return;
  await ctx.db.patch(sub._id, { subscribed: false, subscriptionUpdatedAt: at, unsubscribedAt: undefined, updatedAt: now });
  await ensureFeedState(ctx, podcast._id, await hasSubscribers(ctx, podcast._id), false);
  const event = await ctx.db
    .query("libraryEvents")
    .withIndex("by_user_eventId", (q) => q.eq("userId", ctx.userId).eq("eventId", `subscribed:${podcast._id}:${at}`))
    .unique();
  if (event) {
    await ctx.db.delete(event._id);
    await ctx.db.insert("deletions", { userId: ctx.userId, table: "libraryEvents", docId: event._id, deletedAt: now, updatedAt: now });
  }
}

/** Per-show setting override, LWW on `at` so anything he's changed in Poddle since wins. */
async function setShowOverride(
  ctx: UserMutationCtx,
  podcastId: Id<"podcasts">,
  values: Partial<Pick<Doc<"podcastSettings">, "notifications" | "newEpisodes">>,
  at: number,
) {
  const existing = await ctx.db
    .query("podcastSettings")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId).eq("podcastId", podcastId))
    .unique();
  const fieldTimes = { ...(existing?.fieldTimes ?? {}) };
  const patch: Record<string, unknown> = {};
  for (const [k, val] of Object.entries(values)) {
    if ((fieldTimes[k] ?? 0) > at) continue;
    patch[k] = val;
    fieldTimes[k] = at;
  }
  if (!Object.keys(patch).length) return;
  if (existing) await ctx.db.patch(existing._id, { ...patch, fieldTimes, updatedAt: Date.now() });
  else await ctx.db.insert("podcastSettings", { userId: ctx.userId, podcastId, ...patch, fieldTimes, updatedAt: Date.now() });
}

const vPlaylist = v.object({
  title: v.string(),
  smart: v.boolean(),
  sorting: v.optional(v.string()),
  includePodcastIds: v.array(v.number()),
  priorityPodcastIds: v.array(v.number()),
  includeEpisodeIds: v.array(v.number()),
  sortedEpisodeIds: v.array(v.number()),
});

/** All feeds staged: record the playlists, apply priority shows and start fetching. */
export const beginFetching = internalMutation({
  args: {
    batchId: v.id("importBatches"),
    warning: v.optional(v.string()),
    playlists: v.array(vPlaylist),
    upNextPlan: v.object({
      leadingEpisodeIds: v.array(v.number()),
      priorityPodcastIds: v.array(v.number()),
      newestFirst: v.boolean(),
    }),
  },
  returns: v.null(),
  handler: async (rawCtx, { batchId, warning, playlists, upNextPlan }) => {
    const owned = await batchCtx(rawCtx, batchId);
    if (!owned || owned.batch.status !== "parsing") return null;
    const { ctx } = owned;
    const resolve = async (overcastIds: number[]) => {
      const podcasts: Doc<"podcasts">[] = [];
      for (const overcastId of overcastIds) {
        const podcast = await ctx.db
          .query("podcasts")
          .withIndex("by_overcastId", (q) => q.eq("overcastId", overcastId))
          .first();
        if (podcast) podcasts.push(podcast);
      }
      return podcasts;
    };
    const resolved = [];
    for (const p of playlists) {
      resolved.push({
        title: p.title,
        smart: p.smart,
        sorting: p.sorting,
        podcastIds: (await resolve(p.includePodcastIds)).map((x) => x._id),
        priorityPodcastIds: (await resolve(p.priorityPodcastIds)).map((x) => x._id),
        episodeCount: p.includeEpisodeIds.length + p.sortedEpisodeIds.length,
      });
    }
    // Overcast's priority shows get "Up Next top" for new episodes.
    const priority = await resolve(upNextPlan.priorityPodcastIds);
    for (const podcast of priority) {
      const sub = await subscriptionFor(ctx, podcast._id);
      await setShowOverride(ctx, podcast._id, { newEpisodes: "upNextTop" }, sub?.subscribedAt ?? 1);
    }
    await moveBatch(ctx, owned.batch, "fetching", {
      warning,
      playlists: resolved,
      upNextPlan: { ...upNextPlan, priorityPodcastIds: priority.map((p) => p._id) },
      worker: 1,
      restarts: 0,
    });
    await ctx.scheduler.runAfter(0, internal.importActions.processBatch, { batchId, worker: 1 });
    return null;
  },
});

export const failBatch = internalMutation({
  args: { batchId: v.id("importBatches"), error: v.string() },
  returns: v.null(),
  handler: async (ctx, { batchId, error }) => {
    const batch = await ctx.db.get(batchId);
    if (batch) await moveBatch(ctx, batch, "failed", { error });
    return null;
  },
});

/**
 * Cron: imports that have stopped making progress. A fetching one gets a new
 * run of the worker chain, and the old run (if it's only slow) stops at its next
 * step. After MAX_RESTARTS in a row without progress, or a parse that never
 * finished, it fails with a message the app shows.
 */
export const resumeStalled = internalMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const now = Date.now();
    const stalled = (status: ImportStatus, ms: number) =>
      ctx.db
        .query("importBatches")
        .withIndex("by_status_updatedAt", (q) => q.eq("status", status).lt("updatedAt", now - ms))
        .take(20);
    for (const batch of await stalled("parsing", PARSE_STALL_MS)) {
      await moveBatch(ctx, batch, "failed", { error: "Reading the file stopped part way. Try importing it again." });
    }
    for (const batch of await stalled("fetching", IMPORT_STALL_MS)) {
      const restarts = batch.restarts ?? 0;
      if (restarts >= MAX_RESTARTS) {
        await moveBatch(ctx, batch, "failed", { error: "The import stopped part way and couldn't restart. Try importing the file again." });
        continue;
      }
      const worker = (batch.worker ?? 0) + 1;
      console.warn(`Import ${batch._id} made no progress for ${Math.round((now - batch.updatedAt) / 60_000)} min: restarting it (run ${worker})`);
      await ctx.db.patch(batch._id, { worker, restarts: restarts + 1, updatedAt: now });
      await mirrorBatch(ctx, batch._id);
      await ctx.scheduler.runAfter(0, internal.importActions.processBatch, { batchId: batch._id, worker });
    }
    return null;
  },
});

const SCRATCH_PAGE = 500;

/** A failed batch's scratch rows, a page at a time. */
export const discardScratch = internalMutation({
  args: { batchId: v.id("importBatches") },
  returns: v.null(),
  handler: async (ctx, { batchId }) => {
    const batch = await ctx.db.get(batchId);
    if (batch && batch.status !== "failed") return null;
    const rows: { _id: Id<"importItems"> | Id<"importQueue"> | Id<"importUpNext"> }[] = [
      ...(await ctx.db.query("importItems").withIndex("by_batch_podcast", (q) => q.eq("batchId", batchId)).take(SCRATCH_PAGE)),
      ...(await ctx.db.query("importQueue").withIndex("by_batch_phase", (q) => q.eq("batchId", batchId)).take(SCRATCH_PAGE)),
      ...(await ctx.db.query("importUpNext").withIndex("by_batch", (q) => q.eq("batchId", batchId)).take(SCRATCH_PAGE)),
    ];
    for (const row of rows) await ctx.db.delete(row._id);
    if (rows.length) await ctx.scheduler.runAfter(0, internal.overcastImport.discardScratch, { batchId });
    return null;
  },
});

/** Whether `worker` is still the batch's run of the chain, and the batch still fetching. */
const isCurrent = (batch: Doc<"importBatches"> | null, worker: number | undefined): batch is Doc<"importBatches"> =>
  batch?.status === "fetching" && (worker === undefined || (batch.worker ?? 0) === worker);

/**
 * The next few feeds to fetch, claimed for this run. None and no `waitMs`: every
 * feed is in. None with `waitMs`: some are waiting (another fetch of the feed is
 * running, or a run that died claimed it), so look again then. `stale`: this
 * run is no longer the batch's, and should stop.
 */
export const claimFetches = internalMutation({
  args: { batchId: v.id("importBatches"), count: v.number(), worker: v.optional(v.number()) },
  returns: v.object({
    stale: v.boolean(),
    /** `claimedAt` is the claim's identity: a report must bring it back (feedFetched, feedBusy). */
    rows: v.array(v.object({ rowId: v.id("importQueue"), podcastId: v.id("podcasts"), claimedAt: v.number() })),
    waitMs: v.optional(v.number()),
  }),
  handler: async (ctx, { batchId, count, worker }) => {
    if (!isCurrent(await ctx.db.get(batchId), worker)) return { stale: true, rows: [] };
    const now = Date.now();
    const rows = await ctx.db
      .query("importQueue")
      .withIndex("by_batch_phase", (q) => q.eq("batchId", batchId).eq("phase", "fetch"))
      .collect();
    // When each row may next be taken.
    const freeAt = (r: Doc<"importQueue">) => Math.max(r.notBefore ?? 0, r.claimedAt !== undefined ? r.claimedAt + CLAIM_STALE_MS : 0);
    const free = rows.filter((r) => freeAt(r) <= now).slice(0, count);
    for (const r of free) {
      await ctx.db.patch(r._id, { claimedAt: now });
      await mirrorShow(ctx, r._id);
    }
    const waiting = rows.filter((r) => !free.includes(r));
    const waitMs = !free.length && waiting.length ? Math.max(1000, Math.min(...waiting.map(freeAt)) - now) : undefined;
    return { stale: false, rows: free.map((r) => ({ rowId: r._id, podcastId: r.podcastId, claimedAt: now })), waitMs };
  },
});

/** Most recent known durations kept per show for the batch-wide median. */
const DURATION_SAMPLE = 500;

/** A feed has been fetched (or failed): note what matching needs and queue it for matching. */
export const feedFetched = internalMutation({
  args: {
    batchId: v.id("importBatches"),
    rowId: v.id("importQueue"),
    /** The claim this fetch was made under (claimFetches). A run from before claims had one can't report. */
    claimedAt: v.number(),
    ok: v.boolean(),
    status: v.optional(v.number()),
    error: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { batchId, rowId, claimedAt, ok, status, error }) => {
    await markFetched(ctx, batchId, rowId, claimedAt, { ok, status, error });
    return null;
  },
});

/**
 * Another fetch of the feed was running when this run tried, so the stored
 * episodes may be half there. It waits and tries again rather than matching
 * against them, and only counts the feed as failed if that fetch never ends.
 */
export const feedBusy = internalMutation({
  args: { batchId: v.id("importBatches"), rowId: v.id("importQueue"), claimedAt: v.number() },
  returns: v.null(),
  handler: async (ctx, { batchId, rowId, claimedAt }) => {
    const row = await ctx.db.get(rowId);
    const batch = await ctx.db.get(batchId);
    if (!row || !holdsClaim(row, claimedAt) || batch?.status !== "fetching") return null;
    const busyCount = (row.busyCount ?? 0) + 1;
    if (busyCount >= BUSY_LIMIT) {
      await markFetched(ctx, batchId, rowId, claimedAt, { ok: false, error: "Another fetch of this feed never finished" });
      return null;
    }
    await ctx.db.patch(rowId, { busyCount, claimedAt: undefined, notBefore: Date.now() + BUSY_RETRY_MS });
    await mirrorShow(ctx, rowId);
    await ctx.db.patch(batchId, progressed(batch));
    if (batch.restarts) await mirrorBatch(ctx, batchId);
    return null;
  },
});

/**
 * Whether a report belongs to the row's current claim. A run that was only slow
 * reports after a newer run claimed the show again (or after it was fetched), and
 * its answer mustn't overwrite the newer run's.
 */
function holdsClaim(row: Doc<"importQueue">, claimedAt: number) {
  return row.phase === "fetch" && row.claimedAt === claimedAt;
}

async function markFetched(
  ctx: MutationCtx,
  batchId: Id<"importBatches">,
  rowId: Id<"importQueue">,
  claimedAt: number,
  { ok, status, error }: { ok: boolean; status?: number; error?: string },
) {
  const row = await ctx.db.get(rowId);
  const batch = await ctx.db.get(batchId);
  if (!row || !holdsClaim(row, claimedAt) || batch?.status !== "fetching") return;
  {
    const podcast = await ctx.db.get(row.podcastId);
    const failedFeeds =
      !ok && podcast
        ? [...(batch.failedFeeds ?? []), { podcastId: podcast._id, title: podcast.title, feedUrl: podcast.feedUrl, status, error: error ?? "Fetch failed" }]
        : batch.failedFeeds;
    await ctx.db.patch(batchId, { failedFeeds, ...progressed(batch) });
    if (batch.restarts) await mirrorBatch(ctx, batchId);
    const episodes = await ctx.db
      .query("episodes")
      .withIndex("by_podcast_pubDate", (q) => q.eq("podcastId", row.podcastId))
      .collect();
    const inFeed = episodes.filter((e) => !e.isGhost);
    const durations = inFeed.map((e) => e.duration).filter((d): d is number => d !== undefined && d > 0);
    const dates = inFeed.map((e) => e.pubDate).filter((d): d is number => d !== undefined);
    await ctx.db.patch(rowId, {
      phase: "match",
      feedOk: ok,
      oldestFeedPubDate: dates.length ? Math.min(...dates) : undefined,
      medianDuration: median(durations),
      durations: durations.slice(-DURATION_SAMPLE),
      claimedAt: undefined,
      notBefore: undefined,
    });
    await mirrorShow(ctx, rowId);
  }
}

export function median(values: number[]): number | undefined {
  if (!values.length) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

const vMatchRow = v.object({
  rowId: v.id("importQueue"),
  podcastId: v.id("podcasts"),
  feedOk: v.boolean(),
  oldestFeedPubDate: v.optional(v.number()),
  medianDuration: v.optional(v.number()),
  newestExportedAt: v.optional(v.number()),
  addedAt: v.optional(v.number()),
});

/**
 * Take the next few fetched shows to match. Called only once every feed is in,
 * so the first call can work out the batch-wide median duration.
 */
export const claimMatches = internalMutation({
  args: { batchId: v.id("importBatches"), count: v.number() },
  returns: v.array(vMatchRow),
  handler: async (ctx, { batchId, count }) => {
    const batch = await ctx.db.get(batchId);
    if (batch?.status !== "fetching") return [];
    const pending = () =>
      ctx.db.query("importQueue").withIndex("by_batch_phase", (q) => q.eq("batchId", batchId).eq("phase", "match"));
    if (batch.medianDuration === undefined) {
      const overall = median((await pending().collect()).flatMap((r) => r.durations ?? []));
      if (overall !== undefined) await ctx.db.patch(batchId, { medianDuration: overall });
    }
    // The rows stay until their show is matched (matchPodcast deletes each), so a
    // run that dies part way loses nothing: the next one takes them again.
    const rows = await pending().take(count);
    return rows.map((r) => ({
      rowId: r._id,
      podcastId: r.podcastId,
      feedOk: r.feedOk ?? false,
      oldestFeedPubDate: r.oldestFeedPubDate,
      medianDuration: r.medianDuration,
      newestExportedAt: r.newestExportedAt,
      addedAt: r.addedAt,
    }));
  },
});

const MATCH_PAGE = 100;
const DAY = 86_400_000;

/**
 * Match one page of a podcast's staged episodes against its (freshly fetched)
 * feed episodes, then apply their state. Returns true when the podcast is done.
 * Each staged episode is deleted in the same step that applies it, so two runs
 * on one show (a restart while the old run was only slow) never apply one twice.
 */
export const matchPodcast = internalMutation({
  args: { batchId: v.id("importBatches"), rowId: v.id("importQueue") },
  returns: v.boolean(),
  handler: async (rawCtx, { batchId, rowId }) => {
    const owned = await batchCtx(rawCtx, batchId);
    const queued = await rawCtx.db.get(rowId);
    // Gone: another run finished this show. Not fetching: the batch is over.
    if (!owned || owned.batch.status !== "fetching" || !queued || queued.phase !== "match") return true;
    const row = { ...queued, feedOk: queued.feedOk ?? false };
    const podcast = await rawCtx.db.get(row.podcastId);
    if (!podcast) {
      await rawCtx.db.delete(rowId);
      return true;
    }
    const { batch, ctx } = owned;
    const subscribed = (await subscriptionFor(ctx, podcast._id))?.subscribed ?? false;
    const items = await ctx.db
      .query("importItems")
      .withIndex("by_batch_podcast", (q) => q.eq("batchId", batchId).eq("podcastId", row.podcastId))
      .take(MATCH_PAGE);
    const delta = { ...(emptyCounts() as Required<Counts>), earliestListenAt: undefined as number | undefined };
    const estimatedDuration = row.medianDuration ?? batch.medianDuration;
    for (const item of items) {
      const { episode, matched } = await matchOrGhost(ctx, row.podcastId, item);
      if (matched) delta.episodesMatched++;
      else {
        delta.ghostEpisodes++;
        if (!row.feedOk) delta.ghostsFeedFailed++;
        else if (item.pubDate !== undefined && row.oldestFeedPubDate !== undefined && item.pubDate < row.oldestFeedPubDate - DAY)
          delta.ghostsOlderThanFeed++;
        else delta.ghostsMissingFromFeed++;
      }
      const r = await applyImportedState(ctx, batch, subscribed, episode, item, estimatedDuration);
      if (item.played) delta.playedEpisodes++;
      else if ((item.progress ?? 0) > 0) delta.inProgressEpisodes++;
      if (item.userRecommendedAt) delta.starredEpisodes++;
      if (r.sessionWall !== undefined) {
        delta.sessions++;
        if (r.durationEstimated) delta.estimatedDurationSessions++;
        delta.estimatedListenSeconds += r.sessionWall;
        delta.earliestListenAt = Math.min(delta.earliestListenAt ?? Infinity, r.sessionStart!);
      }
      await ctx.db.delete(item._id);
    }
    const done = items.length < MATCH_PAGE;
    if (done) {
      await ctx.db.delete(rowId);
      delta.podcastsProcessed = 1;
      if (!row.feedOk) delta.feedsFailed = 1;
      if (subscribed && row.feedOk) await stageUntouchedEpisodes(ctx, batchId, podcast._id, row);
      const episodeCount = await countEpisodes(ctx, row.podcastId);
      await ctx.db.patch(row.podcastId, { episodeCount, updatedAt: Date.now() });
    }
    await bumpCounts(ctx, batchId, delta);
    return done;
  },
});

async function countEpisodes(ctx: MutationCtx, podcastId: Id<"podcasts">) {
  const eps = await ctx.db
    .query("episodes")
    .withIndex("by_podcast_pubDate", (q) => q.eq("podcastId", podcastId))
    .collect();
  return eps.length;
}

/**
 * The export only lists episodes he's touched. Ones a subscribed show has
 * published since the newest of those (and since he added the show) were
 * sitting unplayed in Overcast, so they're Up Next too.
 */
async function stageUntouchedEpisodes(
  ctx: UserMutationCtx,
  batchId: Id<"importBatches">,
  podcastId: Id<"podcasts">,
  row: { newestExportedAt?: number; addedAt?: number },
) {
  const since = Math.max(row.newestExportedAt ?? -Infinity, row.addedAt ?? -Infinity);
  if (!Number.isFinite(since)) return;
  const newer = await ctx.db
    .query("episodes")
    .withIndex("by_podcast_pubDate", (q) => q.eq("podcastId", podcastId).gt("pubDate", since))
    .collect();
  for (const episode of newer) {
    if (episode.isGhost || episode.pubDate === undefined) continue;
    const state = await stateFor(ctx, episode._id);
    if (state && (state.played || state.archived)) continue;
    await ctx.db.insert("importUpNext", {
      batchId,
      episodeId: episode._id,
      podcastId,
      pubDate: episode.pubDate,
      at: Math.min(episode.pubDate, Date.now()),
    });
  }
}

/**
 * Enclosure (normalised: query, scheme and tracking prefixes ignored), then GUID
 * and link (Overcast's `url` is usually the item's link), then title + date,
 * then a title only one feed episode has. A real feed episode beats a ghost.
 * An existing ghost is only reused for the same title and date (a re-run, or a
 * duplicate row): ghosts keep Overcast's `url`, which is often the show's
 * homepage, and some shows reuse one enclosure URL for every bulletin.
 * Else a new ghost.
 */
function sameItem(ghost: Doc<"episodes">, item: Doc<"importItems">) {
  if ((ghost.title || "Untitled episode") !== (item.title || "Untitled episode")) return false;
  if (ghost.pubDate === undefined || item.pubDate === undefined) return ghost.pubDate === item.pubDate;
  return Math.abs(ghost.pubDate - item.pubDate) < DAY;
}

async function matchOrGhost(ctx: MutationCtx, podcastId: Id<"podcasts">, item: Doc<"importItems">) {
  const match = { enclosureUrl: item.enclosureUrl, title: item.title, pubDate: item.pubDate };
  const strategies = [
    () => findByEnclosure(ctx, podcastId, match),
    () => findByGuid(ctx, podcastId, item.url),
    () => findByLink(ctx, podcastId, item.url),
    () => findByTitleDate(ctx, podcastId, match),
    () => findByUniqueTitle(ctx, podcastId, item.title),
  ];
  let ghost: Doc<"episodes"> | null = null;
  for (const find of strategies) {
    const found = await find();
    if (found && !found.isGhost) return { episode: found, matched: true };
    if (found && sameItem(found, item)) ghost ??= found;
  }
  if (ghost) return { episode: ghost, matched: false };
  const now = Date.now();
  const id = await ctx.db.insert("episodes", {
    podcastId,
    title: item.title || "Untitled episode",
    enclosureUrl: item.enclosureUrl,
    enclosureKey: enclosureKey(item.enclosureUrl),
    link: item.url,
    pubDate: item.pubDate,
    transcripts: [],
    isGhost: true,
    firstSeenAt: now,
    updatedAt: now,
  });
  return { episode: (await ctx.db.get(id))!, matched: false };
}

/**
 * Overcast's state onto the episode. Unplayed, undeleted episodes of subscribed
 * shows are staged for Up Next; everything else is archived (decisions.md).
 */
async function applyImportedState(
  ctx: UserMutationCtx,
  batch: Doc<"importBatches">,
  subscribed: boolean,
  episode: Doc<"episodes">,
  item: Doc<"importItems">,
  estimatedDuration: number | undefined,
): Promise<{ sessionWall?: number; sessionStart?: number; durationEstimated?: boolean }> {
  const at = item.userUpdatedAt ?? item.pubDate ?? batch.startedAt;
  if (item.played) await setPlayed(ctx, episode, true, at);
  else if ((item.progress ?? 0) > 0) await setPosition(ctx, episode, item.progress!, at, "overcast-import");
  if (item.userRecommendedAt) await setStarred(ctx, episode, true, item.userRecommendedAt);
  if (!item.played && !item.userDeleted && subscribed) {
    await ctx.db.insert("importUpNext", {
      batchId: batch._id,
      episodeId: episode._id,
      podcastId: episode.podcastId,
      overcastId: item.overcastId,
      pubDate: episode.pubDate ?? item.pubDate,
      at,
    });
  } else {
    await setArchived(ctx, episode, true, at);
  }

  if (!countsAsListened(item) || item.userUpdatedAt === undefined) return {};
  // Content heard: the whole episode if played, else how far he got. Ghosts and
  // feeds without durations fall back to the show's (or the overall) median.
  let content = item.progress ?? 0;
  let durationEstimated = false;
  if (item.played) {
    if (episode.duration) content = episode.duration;
    else if (estimatedDuration) {
      content = estimatedDuration;
      durationEstimated = true;
    }
  }
  if (content <= 0) return {};
  const wall = content / batch.assumedSpeed;
  const endedAt = item.userUpdatedAt;
  const startedAt = endedAt - Math.round(wall * 1000);
  await upsertSession(ctx, {
    sessionId: `overcast:${item.overcastId}`,
    episodeId: episode._id,
    podcastId: episode.podcastId,
    deviceId: "overcast-import",
    startedAt,
    endedAt,
    contentStart: 0,
    contentEnd: content,
    rate: batch.assumedSpeed,
    smartSpeed: false,
    smartRemovedContent: 0,
    voiceBoost: false,
    source: "overcastImport",
    isEstimated: true,
    utcOffsetMinutes: await userUtcOffset(ctx, startedAt),
    importBatchId: batch._id,
    updatedAt: Date.now(),
  });
  return { sessionWall: wall, sessionStart: startedAt, durationEstimated };
}

/**
 * Every show is matched: seed Up Next in the order Overcast's main playlist had
 * (decisions.md), then mark the batch done. Episodes already queued, or played
 * or archived since, are left alone, as are ones he's removed from Up Next
 * after Overcast's date (the queue tombstone wins).
 */
export const finishBatch = internalMutation({
  args: { batchId: v.id("importBatches") },
  /** False: there's more to do after all, so the worker carries on. */
  returns: v.boolean(),
  handler: async (rawCtx, { batchId }) => {
    const owned = await batchCtx(rawCtx, batchId);
    // Only once, and only when every show is in: a second or late call does nothing.
    if (!owned || owned.batch.status !== "fetching") return true;
    const { batch, ctx } = owned;
    const unfinished = await ctx.db
      .query("importQueue")
      .withIndex("by_batch_phase", (q) => q.eq("batchId", batchId))
      .first();
    if (unfinished) return false;
    if (await requeueOrphans(ctx, batchId)) return false;
    const rows = await ctx.db
      .query("importUpNext")
      .withIndex("by_batch", (q) => q.eq("batchId", batchId))
      .collect();
    let upNext = 0;
    for (const { row, addedBy } of upNextOrder(rows, batch.upNextPlan)) {
      if (await queueItemFor(ctx, row.episodeId)) {
        upNext++;
        continue;
      }
      const episode = await ctx.db.get(row.episodeId);
      const state = await stateFor(ctx, row.episodeId);
      if (!episode || (state && (state.played || state.archived))) continue;
      if (await addToQueue(ctx, episode, "bottom", row.at, addedBy)) upNext++;
    }
    for (const row of rows) await ctx.db.delete(row._id);
    await moveBatch(ctx, batch, "done", { counts: { ...batch.counts, upNextEpisodes: upNext } });
    return true;
  },
});

/**
 * Staged episodes whose show has no queue row: before this fix, claimMatches
 * deleted a show's row before matching it, so a run that died there left them
 * behind. Their shows go back in the queue, to be fetched and matched like the
 * rest. True if any did.
 */
async function requeueOrphans(ctx: MutationCtx, batchId: Id<"importBatches">) {
  let requeued = false;
  let after: Id<"podcasts"> | undefined;
  for (;;) {
    const item = await ctx.db
      .query("importItems")
      .withIndex("by_batch_podcast", (q) => (after ? q.eq("batchId", batchId).gt("podcastId", after) : q.eq("batchId", batchId)))
      .first();
    if (!item) return requeued;
    console.warn(`Import ${batchId}: show ${item.podcastId} had staged episodes but no queue row; queueing it again`);
    // The row's dates (for episodes published since, which go to Up Next) as near
    // as they can be rebuilt: the newest staged episode left, and when the
    // subscription began. stageFeeds set that from Overcast's added date unless he'd
    // followed the show in Poddle since, and then the later date can leave out
    // untouched episodes from between the two. Only imports the old code broke
    // have orphans, and there were none on prod when this shipped (17 Nov 2026).
    const podcastId = item.podcastId;
    const staged = await ctx.db
      .query("importItems")
      .withIndex("by_batch_podcast", (q) => q.eq("batchId", batchId).eq("podcastId", podcastId))
      .collect();
    const dates = staged.map((i) => i.pubDate).filter((d): d is number => d !== undefined);
    const batch = (await ctx.db.get(batchId))!;
    const sub = await subscriptionFor(asUser(ctx, batch.userId!), podcastId);
    const rowId = await ctx.db.insert("importQueue", {
      batchId,
      podcastId,
      phase: "fetch",
      newestExportedAt: dates.length ? Math.max(...dates) : undefined,
      addedAt: sub?.subscribedAt,
    });
    await mirrorShow(ctx, rowId);
    requeued = true;
    after = item.podcastId;
  }
}

/**
 * Overcast's main-playlist order: hand-placed episodes first (manual playlists'
 * episodes, then its own pinned order), then priority shows, then the rest,
 * each by the playlist's sort (newest first unless it's chronological).
 */
export function upNextOrder<R extends { episodeId: string; podcastId: string; overcastId?: number; pubDate?: number }>(
  rows: R[],
  plan: { leadingEpisodeIds: number[]; priorityPodcastIds: string[]; newestFirst: boolean } | undefined,
): { row: R; addedBy: AddedBy }[] {
  const leading = new Map((plan?.leadingEpisodeIds ?? []).map((id, i) => [id, i]));
  const priority = new Set(plan?.priorityPodcastIds ?? []);
  const newestFirst = plan?.newestFirst ?? true;
  const seen = new Set<string>();
  const unique = rows.filter((r) => !seen.has(r.episodeId) && seen.add(r.episodeId));
  const rank = (r: R) => (r.overcastId !== undefined && leading.has(r.overcastId) ? 0 : priority.has(r.podcastId) ? 1 : 2);
  const byDate = (a: R, b: R) => ((a.pubDate ?? 0) - (b.pubDate ?? 0)) * (newestFirst ? -1 : 1);
  return unique
    .sort((a, b) => {
      const ra = rank(a);
      const rb = rank(b);
      if (ra !== rb) return ra - rb;
      if (ra === 0) return leading.get(a.overcastId!)! - leading.get(b.overcastId!)!;
      return byDate(a, b);
    })
    .map((row) => ({ row, addedBy: rank(row) === 0 ? "manual" : rank(row) === 1 ? "priority" : "auto" }));
}
