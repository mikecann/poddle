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

async function bumpCounts(ctx: MutationCtx, batchId: Id<"importBatches">, delta: Partial<Counts>) {
  const batch = await ctx.db.get(batchId);
  if (!batch) return;
  const counts = { ...batch.counts };
  for (const [k, val] of Object.entries(delta) as [keyof Counts, number | undefined][]) {
    if (val === undefined) continue;
    if (k === "earliestListenAt") counts.earliestListenAt = Math.min(counts.earliestListenAt ?? Infinity, val);
    else counts[k] = (counts[k] ?? 0) + val;
  }
  await ctx.db.patch(batchId, { counts, updatedAt: Date.now() });
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
    if (!owned) return null;
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
      await ctx.db.insert("importQueue", { batchId, podcastId: podcast._id, phase: "fetch", newestExportedAt, addedAt: feed.addedAt });
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
    if (!owned) return null;
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
    await ctx.db.patch(batchId, {
      status: "fetching",
      warning,
      playlists: resolved,
      upNextPlan: { ...upNextPlan, priorityPodcastIds: priority.map((p) => p._id) },
      updatedAt: Date.now(),
    });
    await ctx.scheduler.runAfter(0, internal.importActions.processBatch, { batchId });
    return null;
  },
});

export const failBatch = internalMutation({
  args: { batchId: v.id("importBatches"), error: v.string() },
  returns: v.null(),
  handler: async (ctx, { batchId, error }) => {
    await ctx.db.patch(batchId, { status: "failed", error, finishedAt: Date.now(), updatedAt: Date.now() });
    return null;
  },
});

/** The next few feeds to fetch. Empty once every feed has been fetched. */
export const claimFetches = internalMutation({
  args: { batchId: v.id("importBatches"), count: v.number() },
  returns: v.array(v.object({ rowId: v.id("importQueue"), podcastId: v.id("podcasts") })),
  handler: async (ctx, { batchId, count }) => {
    const rows = await ctx.db
      .query("importQueue")
      .withIndex("by_batch_phase", (q) => q.eq("batchId", batchId).eq("phase", "fetch"))
      .take(count);
    return rows.map((r) => ({ rowId: r._id, podcastId: r.podcastId }));
  },
});

/** Most recent known durations kept per show for the batch-wide median. */
const DURATION_SAMPLE = 500;

/** A feed has been fetched (or failed): note what matching needs and queue it for matching. */
export const feedFetched = internalMutation({
  args: {
    batchId: v.id("importBatches"),
    rowId: v.id("importQueue"),
    ok: v.boolean(),
    status: v.optional(v.number()),
    error: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { batchId, rowId, ok, status, error }) => {
    const row = await ctx.db.get(rowId);
    const batch = await ctx.db.get(batchId);
    if (!row || !batch) return null;
    const podcast = await ctx.db.get(row.podcastId);
    if (!ok && podcast) {
      const failed = { podcastId: podcast._id, title: podcast.title, feedUrl: podcast.feedUrl, status, error: error ?? "Fetch failed" };
      await ctx.db.patch(batchId, { failedFeeds: [...(batch.failedFeeds ?? []), failed], updatedAt: Date.now() });
    }
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
    });
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
    if (!batch) return [];
    const pending = () =>
      ctx.db.query("importQueue").withIndex("by_batch_phase", (q) => q.eq("batchId", batchId).eq("phase", "match"));
    if (batch.medianDuration === undefined) {
      const overall = median((await pending().collect()).flatMap((r) => r.durations ?? []));
      if (overall !== undefined) await ctx.db.patch(batchId, { medianDuration: overall });
    }
    const rows = await pending().take(count);
    for (const r of rows) await ctx.db.delete(r._id);
    return rows.map((r) => ({
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
 */
export const matchPodcast = internalMutation({
  args: { batchId: v.id("importBatches"), row: vMatchRow },
  returns: v.boolean(),
  handler: async (rawCtx, { batchId, row }) => {
    const owned = await batchCtx(rawCtx, batchId);
    const podcast = await rawCtx.db.get(row.podcastId);
    if (!owned || !podcast) return true;
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
  returns: v.null(),
  handler: async (rawCtx, { batchId }) => {
    const owned = await batchCtx(rawCtx, batchId);
    if (!owned) return null;
    const { batch, ctx } = owned;
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
    await ctx.db.patch(batchId, {
      status: "done",
      counts: { ...batch.counts, upNextEpisodes: upNext },
      finishedAt: Date.now(),
      updatedAt: Date.now(),
    });
    return null;
  },
});

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
