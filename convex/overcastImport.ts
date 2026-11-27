import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalQuery, type MutationCtx } from "./_generated/server";
import { ensureFeedState } from "./feeds";
import { asUser, userMutation, userQuery, type UserMutationCtx } from "./lib/auth";
import { ensureLibraryRow, hasSubscribers, subscriptionFor } from "./lib/library";
import { findByEnclosure, findByGuid, findByLink, findByTitleDate, findByUniqueTitle } from "./lib/ingest";
import { countsAsListened } from "./lib/opml";
import { enclosureKey } from "./lib/parse";
import { addToQueue, queueItemFor, type AddedBy } from "./lib/queue";
import { getOrCreatePodcast, setSubscribed } from "./podcasts";
import { syncStreakAfterChanges } from "./lib/rollups";
import { upsertSession } from "./sessions";
import { setArchived, setPlayed, setPosition, setStarred, stateFor, userUtcOffset } from "./lib/state";
import { importBatchView, vImportBatchDoc, vImportBatchRow } from "./lib/validators";
import { CLAIM_STALE_MS } from "./lifecycles/importShow";
import { asMutationCtx, importBatch, importShow, machines, type MachineCtx } from "./machines";

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
//
// The batch is the importBatch machine (lifecycles/importBatch.ts) and each
// show in it an importShow (lifecycles/importShow.ts); docs/state-machines.md
// draws both. A late result (a parse or worker run that outlived its batch, a
// fetch report from a run whose claim was taken over) is refused by the state
// it finds. The worker chain can die, so the batch's own timer checks every 5
// minutes that it's getting somewhere, starts a new run if not, and gives up
// after three. A show's row stays until its episodes are all matched, so
// nothing a dead run had claimed is lost.

/** Another fetch of the feed is running: try again this much later. */
const BUSY_RETRY_MS = 30_000;

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
    // The batch is born by importBatch's START, a server event, so through an internal mutation.
    const batchId: Id<"importBatches"> = await ctx.runMutation(internal.overcastImport.createBatch, { userId: ctx.userId, storageId, opml, assumedSpeed });
    return batchId;
  },
});

export const createBatch = machines.internalMutation({
  args: { userId: v.id("users"), storageId: v.optional(v.id("_storage")), opml: v.optional(v.string()), assumedSpeed: v.number() },
  returns: v.id("importBatches"),
  handler: async (ctx, { userId, storageId, opml, assumedSpeed }) => {
    const now = Date.now();
    const created = await importBatch.create(
      ctx,
      { userId, source: "overcast", assumedSpeed, startedAt: now, counts: emptyCounts(), playlists: [], updatedAt: now },
      { type: "START" },
    );
    if (created.status !== "done") throw new Error(created.reasons.join(" "));
    // The row has to exist before the reading can be scheduled for it, so it's
    // here rather than in START's effect. The file's text stays out of history.
    await ctx.scheduler.runAfter(0, internal.importActions.parse, { batchId: created.id, storageId, opml });
    return created.id;
  },
});

/** Live progress for the import receipt. */
export const getImport = userQuery({
  args: { batchId: v.id("importBatches") },
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx, { batchId }) => {
    const batch = await ctx.db.get("importBatches", batchId);
    return batch?.userId === ctx.userId ? importBatchView(batch) : null;
  },
});

export const latestImport = userQuery({
  args: {},
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx) => {
    const batch = await ctx.db
      .query("importBatches")
      .withIndex("by_user_startedAt", (q) => q.eq("userId", ctx.userId))
      .order("desc")
      .first();
    return batch ? importBatchView(batch) : null;
  },
});

/** The batch and a ctx acting as its owner. */
async function batchCtx(ctx: MutationCtx, batchId: Id<"importBatches">) {
  const batch = await ctx.db.get("importBatches", batchId);
  if (!batch?.userId) return null;
  return { batch, ctx: asUser(ctx, batch.userId) };
}

// ---- Internal steps ----

export const getBatch = internalQuery({
  args: { batchId: v.id("importBatches") },
  returns: v.union(vImportBatchRow, v.null()),
  handler: async (ctx, { batchId }) => await ctx.db.get("importBatches", batchId),
});

type Counts = Doc<"importBatches">["counts"];

/** Adds to the batch's counts. Every call is progress, which the batch's CHECK timer looks for in `updatedAt`. */
async function bumpCounts(ctx: MutationCtx, batchId: Id<"importBatches">, delta: Partial<Counts>) {
  const batch = await ctx.db.get("importBatches", batchId);
  if (!batch) return;
  const counts = { ...batch.counts };
  for (const [k, val] of Object.entries(delta) as [keyof Counts, number | undefined][]) {
    if (val === undefined) continue;
    if (k === "earliestListenAt") counts.earliestListenAt = Math.min(counts.earliestListenAt ?? Infinity, val);
    else counts[k] = (counts[k] ?? 0) + val;
  }
  await ctx.db.patch("importBatches", batchId, { counts, ...progressed() });
}

/** What a step that got somewhere writes: the time importBatch's CHECK looks at. */
function progressed() {
  return { updatedAt: Date.now() };
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
export const stageFeeds = machines.internalMutation({
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
  handler: async (machineCtx, { batchId, feeds }) => {
    const owned = await batchCtx(asMutationCtx(machineCtx), batchId);
    // A parse that outlived its batch (its READ_STALLED timer failed it) stages nothing.
    if (!owned || owned.batch.state.kind !== "parsing") return null;
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
        await ctx.db.patch("podcasts", podcast._id, { overcastId: feed.overcastId });
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
      await ctx.db.patch("feedStates", stateId, { nextCheckAt: Date.now() + 6 * 3600_000 });

      let newestExportedAt: number | undefined;
      for (const e of feed.episodes) {
        await ctx.db.insert("importItems", { batchId, podcastId: podcast._id, ...e });
        if (e.pubDate !== undefined) newestExportedAt = Math.max(newestExportedAt ?? -Infinity, e.pubDate);
      }
      episodes += feed.episodes.length;
      await queueShow(machineCtx, { batchId, podcastId: podcast._id, newestExportedAt, addedAt: feed.addedAt });
    }
    await bumpCounts(ctx, batchId, { podcasts: feeds.length, subscribedPodcasts: subscribed, episodes });
    return null;
  },
});

/** A show's row in the batch's queue: an importShow, born waiting for a worker. */
async function queueShow(
  ctx: MachineCtx,
  fields: { batchId: Id<"importBatches">; podcastId: Id<"podcasts">; newestExportedAt?: number; addedAt?: number },
) {
  const queued = await importShow.create(ctx, fields, { type: "QUEUED" });
  if (queued.status !== "done") throw new Error(queued.reasons.join(" "));
}

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
    await ctx.db.patch("subscriptions", sub._id, { subscriptionUpdatedAt: at, subscribedAt: sub.subscribedAt ?? addedAt, updatedAt: now });
    return;
  }
  if (!sub.subscribed || sub.subscriptionUpdatedAt > at) return;
  await ctx.db.patch("subscriptions", sub._id, { subscribed: false, subscriptionUpdatedAt: at, unsubscribedAt: undefined, updatedAt: now });
  await ensureFeedState(ctx, podcast._id, await hasSubscribers(ctx, podcast._id), false);
  const event = await ctx.db
    .query("libraryEvents")
    .withIndex("by_user_eventId", (q) => q.eq("userId", ctx.userId).eq("eventId", `subscribed:${podcast._id}:${at}`))
    .unique();
  if (event) {
    await ctx.db.delete("libraryEvents", event._id);
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
  if (existing) await ctx.db.patch("podcastSettings", existing._id, { ...patch, fieldTimes, updatedAt: Date.now() });
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
export const beginFetching = machines.internalMutation({
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
  handler: async (machineCtx, { batchId, warning, playlists, upNextPlan }) => {
    const owned = await batchCtx(asMutationCtx(machineCtx), batchId);
    if (!owned || owned.batch.state.kind !== "parsing") return null;
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
    await ctx.db.patch("importBatches", batchId, {
      warning,
      playlists: resolved,
      upNextPlan: { ...upNextPlan, priorityPodcastIds: priority.map((p) => p._id) },
      ...progressed(),
    });
    await importBatch.send(machineCtx, batchId, { type: "PARSED" });
    return null;
  },
});

export const failBatch = machines.internalMutation({
  args: { batchId: v.id("importBatches"), error: v.string() },
  returns: v.null(),
  handler: async (ctx, { batchId, error }) => {
    // Refused if it's already moved on (its READ_STALLED timer failed it first): nothing to do.
    await importBatch.send(ctx, batchId, { type: "FAILED", error });
    return null;
  },
});

const SCRATCH_PAGE = 500;

/** A failed batch's scratch rows, a page at a time (importBatch's failing effects schedule it). */
export const discardScratch = machines.internalMutation({
  args: { batchId: v.id("importBatches") },
  returns: v.null(),
  handler: async (machineCtx, { batchId }) => {
    const ctx = asMutationCtx(machineCtx);
    const batch = await ctx.db.get("importBatches", batchId);
    if (batch && batch.state.kind !== "failed") return null;
    const shows = await ctx.db.query("importQueue").withIndex("by_batch_state", (q) => q.eq("batchId", batchId)).take(SCRATCH_PAGE);
    for (const row of shows) await importShow.purge(machineCtx, row._id, { force: true });
    const rows: { _id: Id<"importItems"> | Id<"importUpNext"> }[] = [
      ...(await ctx.db.query("importItems").withIndex("by_batch_podcast", (q) => q.eq("batchId", batchId)).take(SCRATCH_PAGE)),
      ...(await ctx.db.query("importUpNext").withIndex("by_batch", (q) => q.eq("batchId", batchId)).take(SCRATCH_PAGE)),
    ];
    for (const row of rows) await ctx.db.delete(row._id);
    if (rows.length || shows.length) await ctx.scheduler.runAfter(0, internal.overcastImport.discardScratch, { batchId });
    return null;
  },
});

/** Whether `worker` is still the batch's run of the chain, and the batch still fetching. */
const isCurrent = (batch: Doc<"importBatches"> | null, worker: number | undefined): batch is Doc<"importBatches"> =>
  batch?.state.kind === "fetching" && (worker === undefined || batch.state.worker === worker);

/**
 * The next few feeds to fetch, claimed for this run (importShow's CLAIM). None
 * and no `waitMs`: every feed is in. None with `waitMs`: some are waiting
 * (another fetch of the feed is running, or a run that died claimed it), so look
 * again then. `stale`: this run is no longer the batch's, and should stop.
 */
export const claimFetches = machines.internalMutation({
  args: { batchId: v.id("importBatches"), count: v.number(), worker: v.optional(v.number()) },
  returns: v.object({
    stale: v.boolean(),
    /** `claimedAt` is the claim's identity: a report must bring it back (feedFetched, feedBusy). */
    rows: v.array(v.object({ rowId: v.id("importQueue"), podcastId: v.id("podcasts"), claimedAt: v.number() })),
    waitMs: v.optional(v.number()),
  }),
  handler: async (machineCtx, { batchId, count, worker }) => {
    const ctx = asMutationCtx(machineCtx);
    if (!isCurrent(await ctx.db.get("importBatches", batchId), worker)) return { stale: true, rows: [] };
    const now = Date.now();
    const inState = (kind: "waiting" | "fetching") =>
      ctx.db.query("importQueue").withIndex("by_batch_state", (q) => q.eq("batchId", batchId).eq("state.kind", kind)).collect();
    const rows = [...(await inState("waiting")), ...(await inState("fetching"))];
    // When each row may next be taken: a busy feed's retry time, or when a claim goes stale.
    const freeAt = ({ state }: Doc<"importQueue">) =>
      state.kind === "waiting" ? state.notBefore : state.kind === "fetching" ? state.claimedAt + CLAIM_STALE_MS : Infinity;
    const claimed: { rowId: Id<"importQueue">; podcastId: Id<"podcasts">; claimedAt: number }[] = [];
    for (const r of rows) {
      if (claimed.length >= count || freeAt(r) > now) continue;
      if ((await importShow.send(machineCtx, r._id, { type: "CLAIM", claimedAt: now })).status === "done") {
        claimed.push({ rowId: r._id, podcastId: r.podcastId, claimedAt: now });
      }
    }
    const waiting = rows.filter((r) => !claimed.some((c) => c.rowId === r._id));
    const waitMs = !claimed.length && waiting.length ? Math.max(1000, Math.min(...waiting.map(freeAt)) - now) : undefined;
    return { stale: false, rows: claimed, waitMs };
  },
});

/** Most recent known durations kept per show for the batch-wide median. */
const DURATION_SAMPLE = 500;

/** A feed has been fetched (or failed): importShow's FETCHED, with what matching needs. */
export const feedFetched = machines.internalMutation({
  args: {
    batchId: v.id("importBatches"),
    rowId: v.id("importQueue"),
    /** The claim this fetch was made under (claimFetches). */
    claimedAt: v.number(),
    ok: v.boolean(),
    status: v.optional(v.number()),
    error: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (machineCtx, { batchId, rowId, claimedAt, ok, status, error }) => {
    const ctx = asMutationCtx(machineCtx);
    const row = await ctx.db.get("importQueue", rowId);
    const batch = await ctx.db.get("importBatches", batchId);
    if (!row || batch?.state.kind !== "fetching") return null;
    const episodes = await ctx.db
      .query("episodes")
      .withIndex("by_podcast_pubDate", (q) => q.eq("podcastId", row.podcastId))
      .collect();
    const inFeed = episodes.filter((e) => !e.isGhost);
    const durations = inFeed.map((e) => e.duration).filter((d): d is number => d !== undefined && d > 0);
    const dates = inFeed.map((e) => e.pubDate).filter((d): d is number => d !== undefined);
    const oldest = dates.length ? Math.min(...dates) : undefined;
    const medianDuration = median(durations);
    const fetched = await importShow.send(machineCtx, rowId, {
      type: "FETCHED",
      claimedAt,
      feedOk: ok,
      ...(oldest !== undefined ? { oldestFeedPubDate: oldest } : {}),
      ...(medianDuration !== undefined ? { medianDuration } : {}),
      durations: durations.slice(-DURATION_SAMPLE),
    });
    // Refused: a run that was only slow, reporting after a newer run claimed the show again or fetched it.
    if (fetched.status !== "done") return null;
    await ctx.db.patch("importBatches", batchId, { ...(ok ? {} : { failedFeeds: withFailedFeed(await ctx.db.get("podcasts", row.podcastId), batch, status, error) }), ...progressed() });
    return null;
  },
});

function withFailedFeed(podcast: Doc<"podcasts"> | null, batch: Doc<"importBatches">, status: number | undefined, error: string | undefined) {
  const failed = batch.failedFeeds ?? [];
  if (!podcast) return failed;
  return [...failed, { podcastId: podcast._id, title: podcast.title, feedUrl: podcast.feedUrl, status, error: error ?? "Fetch failed" }];
}

/**
 * Another fetch of the feed was running when this run tried, so the stored
 * episodes may be half there (importShow's BUSY). It waits and tries again rather
 * than matching against them, and only counts the feed as failed if that fetch
 * never ends.
 */
export const feedBusy = machines.internalMutation({
  args: { batchId: v.id("importBatches"), rowId: v.id("importQueue"), claimedAt: v.number() },
  returns: v.null(),
  handler: async (machineCtx, { batchId, rowId, claimedAt }) => {
    const ctx = asMutationCtx(machineCtx);
    const row = await ctx.db.get("importQueue", rowId);
    const batch = await ctx.db.get("importBatches", batchId);
    if (!row || batch?.state.kind !== "fetching") return null;
    const busy = await importShow.send(machineCtx, rowId, { type: "BUSY", claimedAt, retryAt: Date.now() + BUSY_RETRY_MS });
    if (busy.status !== "done") return null;
    const gaveUp = busy.to === "fetched";
    const failedFeeds = gaveUp ? withFailedFeed(await ctx.db.get("podcasts", row.podcastId), batch, undefined, "Another fetch of this feed never finished") : undefined;
    await ctx.db.patch("importBatches", batchId, { ...(failedFeeds ? { failedFeeds } : {}), ...progressed() });
    return null;
  },
});

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
export const claimMatches = machines.internalMutation({
  args: { batchId: v.id("importBatches"), count: v.number() },
  returns: v.array(vMatchRow),
  handler: async (machineCtx, { batchId, count }) => {
    const ctx = asMutationCtx(machineCtx);
    const batch = await ctx.db.get("importBatches", batchId);
    if (batch?.state.kind !== "fetching") return [];
    const pending = () =>
      ctx.db.query("importQueue").withIndex("by_batch_state", (q) => q.eq("batchId", batchId).eq("state.kind", "fetched"));
    if (batch.medianDuration === undefined) {
      const overall = median((await pending().collect()).flatMap((r) => (r.state.kind === "fetched" ? r.state.durations : [])));
      if (overall !== undefined) await ctx.db.patch("importBatches", batchId, { medianDuration: overall });
    }
    // The rows stay until their show is matched (matchPodcast deletes each), so a
    // run that dies part way loses nothing: the next one takes them again.
    const rows = await pending().take(count);
    return rows.map((r) => ({
      rowId: r._id,
      podcastId: r.podcastId,
      feedOk: r.state.kind === "fetched" && r.state.feedOk,
      oldestFeedPubDate: r.state.kind === "fetched" ? r.state.oldestFeedPubDate : undefined,
      medianDuration: r.state.kind === "fetched" ? r.state.medianDuration : undefined,
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
export const matchPodcast = machines.internalMutation({
  args: { batchId: v.id("importBatches"), rowId: v.id("importQueue") },
  returns: v.boolean(),
  handler: async (machineCtx, { batchId, rowId }) => {
    const rawCtx = asMutationCtx(machineCtx);
    const owned = await batchCtx(rawCtx, batchId);
    const queued = await rawCtx.db.get("importQueue", rowId);
    // Gone: another run finished this show. Not fetching: the batch is over.
    if (!owned || owned.batch.state.kind !== "fetching" || !queued || queued.state.kind !== "fetched") return true;
    const row = { ...queued, ...queued.state };
    // Its staged episodes are all applied (or its show's gone): importShow's MATCHED, and the row goes.
    const matched = async () => {
      await importShow.send(machineCtx, rowId, { type: "MATCHED" });
      await importShow.purge(machineCtx, rowId);
    };
    const podcast = await rawCtx.db.get("podcasts", row.podcastId);
    if (!podcast) {
      await matched();
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
    const deferredStreakDays = new Map<string, boolean>();
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
      const r = await applyImportedState(ctx, batch, subscribed, episode, item, estimatedDuration, deferredStreakDays);
      if (item.played) delta.playedEpisodes++;
      else if ((item.progress ?? 0) > 0) delta.inProgressEpisodes++;
      if (item.userRecommendedAt) delta.starredEpisodes++;
      if (r.sessionWall !== undefined) {
        delta.sessions++;
        if (r.durationEstimated) delta.estimatedDurationSessions++;
        delta.estimatedListenSeconds += r.sessionWall;
        delta.earliestListenAt = Math.min(delta.earliestListenAt ?? Infinity, r.sessionStart!);
      }
      await ctx.db.delete("importItems", item._id);
    }
    if (deferredStreakDays.size > 0) await syncStreakAfterChanges(ctx, deferredStreakDays);
    const done = items.length < MATCH_PAGE;
    if (done) {
      await matched();
      delta.podcastsProcessed = 1;
      if (!row.feedOk) delta.feedsFailed = 1;
      if (subscribed && row.feedOk) await stageUntouchedEpisodes(ctx, batchId, podcast._id, row);
      const episodeCount = await countEpisodes(ctx, row.podcastId);
      await ctx.db.patch("podcasts", row.podcastId, { episodeCount, updatedAt: Date.now() });
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
  return { episode: (await ctx.db.get("episodes", id))!, matched: false };
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
  deferredStreakDays: Map<string, boolean>,
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
  }, { deferStreakInto: deferredStreakDays });
  return { sessionWall: wall, sessionStart: startedAt, durationEstimated };
}

/**
 * Every show is matched: seed Up Next in the order Overcast's main playlist had
 * (decisions.md), then mark the batch done. Episodes already queued, or played
 * or archived since, are left alone, as are ones he's removed from Up Next
 * after Overcast's date (the queue tombstone wins).
 */
export const finishBatch = machines.internalMutation({
  args: { batchId: v.id("importBatches") },
  /** False: there's more to do after all, so the worker carries on. */
  returns: v.boolean(),
  handler: async (machineCtx, { batchId }) => {
    const owned = await batchCtx(asMutationCtx(machineCtx), batchId);
    // Only once, and only when every show is in: a second or late call does nothing.
    if (!owned || owned.batch.state.kind !== "fetching") return true;
    const { batch, ctx } = owned;
    const unfinished = await ctx.db
      .query("importQueue")
      .withIndex("by_batch_state", (q) => q.eq("batchId", batchId))
      .first();
    if (unfinished) return false;
    if (await requeueOrphans(machineCtx, ctx, batchId)) return false;
    if ((await importBatch.send(machineCtx, batchId, { type: "ALL_MATCHED" })).status !== "done") return true;
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
      const episode = await ctx.db.get("episodes", row.episodeId);
      const state = await stateFor(ctx, row.episodeId);
      if (!episode || (state && (state.played || state.archived))) continue;
      if (await addToQueue(ctx, episode, "bottom", row.at, addedBy)) upNext++;
    }
    for (const row of rows) await ctx.db.delete("importUpNext", row._id);
    await ctx.db.patch("importBatches", batchId, { counts: { ...batch.counts, upNextEpisodes: upNext }, updatedAt: Date.now() });
    return true;
  },
});

/**
 * Staged episodes whose show has no queue row: before this fix, claimMatches
 * deleted a show's row before matching it, so a run that died there left them
 * behind. Their shows go back in the queue, to be fetched and matched like the
 * rest. True if any did.
 */
async function requeueOrphans(machineCtx: MachineCtx, ctx: MutationCtx, batchId: Id<"importBatches">) {
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
    const batch = (await ctx.db.get("importBatches", batchId))!;
    const sub = await subscriptionFor(asUser(ctx, batch.userId!), podcastId);
    await queueShow(machineCtx, {
      batchId,
      podcastId,
      ...(dates.length ? { newestExportedAt: Math.max(...dates) } : {}),
      ...(sub?.subscribedAt !== undefined ? { addedAt: sub.subscribedAt } : {}),
    });
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
