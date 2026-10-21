import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server";
import { ensureFeedState } from "./feeds";
import { userMutation, userQuery } from "./lib/auth";
import { findByEnclosure, findByGuid, findByTitleDate } from "./lib/ingest";
import { countsAsListened } from "./lib/opml";
import { enclosureKey } from "./lib/parse";
import { getOrCreatePodcast, setSubscribed } from "./podcasts";
import { upsertSession } from "./sessions";
import { setArchived, setPlayed, setPosition, setStarred, userUtcOffset } from "./lib/state";
import { vImportBatchDoc } from "./lib/validators";

// Overcast "All data" import (spec §2.2). Pipeline:
//   startOvercastImport → importActions.parse (stage podcasts + episodes)
//   → importActions.processBatch, repeatedly: fetch a few feeds, then match their
//     staged episodes, create ghosts, states and estimated sessions
//   → done. Counts on the importBatches doc update live for the app's receipt.
// Re-running is safe: podcasts match by overcastId / feed URL, state is LWW on
// Overcast's `userUpdatedDate`, sessions and events have deterministic ids.

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
  sessions: 0,
  estimatedListenSeconds: 0,
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
  handler: async (ctx, { batchId }) => await ctx.db.get(batchId),
});

export const latestImport = userQuery({
  args: {},
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx) => await ctx.db.query("importBatches").withIndex("by_startedAt").order("desc").first(),
});

// ---- Internal steps ----

export const getBatch = internalQuery({
  args: { batchId: v.id("importBatches") },
  returns: v.union(vImportBatchDoc, v.null()),
  handler: async (ctx, { batchId }) => await ctx.db.get(batchId),
});

async function bumpCounts(ctx: MutationCtx, batchId: Id<"importBatches">, delta: Partial<Doc<"importBatches">["counts"]>) {
  const batch = await ctx.db.get(batchId);
  if (!batch) return;
  const counts = { ...batch.counts };
  for (const [k, val] of Object.entries(delta) as [keyof typeof counts, number | undefined][]) {
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
  handler: async (ctx, { batchId, feeds }) => {
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
      } else if (podcast.subscriptionUpdatedAt === 0) {
        await ctx.db.patch(podcast._id, { subscriptionUpdatedAt: at, subscribedAt: podcast.subscribedAt ?? feed.addedAt });
      }
      if (feed.notifications) await setNotifyOverride(ctx, podcast._id, at);
      // The import fetches the feed itself; keep the poller off it until then.
      const stateId = await ensureFeedState(ctx, podcast._id, feed.subscribed || podcast.subscribed, false);
      await ctx.db.patch(stateId, { nextCheckAt: Date.now() + 6 * 3600_000 });

      for (const e of feed.episodes) {
        await ctx.db.insert("importItems", { batchId, podcastId: podcast._id, ...e });
      }
      episodes += feed.episodes.length;
      await ctx.db.insert("importQueue", { batchId, podcastId: podcast._id });
    }
    await bumpCounts(ctx, batchId, { podcasts: feeds.length, subscribedPodcasts: subscribed, episodes });
    return null;
  },
});

async function setNotifyOverride(ctx: MutationCtx, podcastId: Id<"podcasts">, at: number) {
  const existing = await ctx.db
    .query("podcastSettings")
    .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
    .unique();
  if (existing && (existing.fieldTimes.notifications ?? 0) > at) return;
  const fieldTimes = { ...(existing?.fieldTimes ?? {}), notifications: at };
  if (existing) await ctx.db.patch(existing._id, { notifications: true, fieldTimes, updatedAt: Date.now() });
  else await ctx.db.insert("podcastSettings", { podcastId, notifications: true, fieldTimes, updatedAt: Date.now() });
}

/** All feeds staged: resolve playlists and start fetching. */
export const beginFetching = internalMutation({
  args: {
    batchId: v.id("importBatches"),
    warning: v.optional(v.string()),
    playlists: v.array(v.object({ title: v.string(), smart: v.boolean(), includePodcastIds: v.array(v.number()) })),
  },
  returns: v.null(),
  handler: async (ctx, { batchId, warning, playlists }) => {
    const resolved = [];
    for (const p of playlists) {
      const podcastIds: Id<"podcasts">[] = [];
      for (const overcastId of p.includePodcastIds) {
        const podcast = await ctx.db
          .query("podcasts")
          .withIndex("by_overcastId", (q) => q.eq("overcastId", overcastId))
          .first();
        if (podcast) podcastIds.push(podcast._id);
      }
      resolved.push({ title: p.title, smart: p.smart, podcastIds });
    }
    await ctx.db.patch(batchId, { status: "fetching", warning, playlists: resolved, updatedAt: Date.now() });
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

/** Take the next few podcasts to fetch. Empty when the batch is finished. */
export const claimPodcasts = internalMutation({
  args: { batchId: v.id("importBatches"), count: v.number() },
  returns: v.array(v.id("podcasts")),
  handler: async (ctx, { batchId, count }) => {
    const rows = await ctx.db
      .query("importQueue")
      .withIndex("by_batch", (q) => q.eq("batchId", batchId))
      .take(count);
    for (const r of rows) await ctx.db.delete(r._id);
    return rows.map((r) => r.podcastId);
  },
});

export const finishBatch = internalMutation({
  args: { batchId: v.id("importBatches") },
  returns: v.null(),
  handler: async (ctx, { batchId }) => {
    await ctx.db.patch(batchId, { status: "done", finishedAt: Date.now(), updatedAt: Date.now() });
    return null;
  },
});

const MATCH_PAGE = 100;

/**
 * Match one page of a podcast's staged episodes against its (freshly fetched)
 * feed episodes, then apply their state. Returns true when the podcast is done.
 */
export const matchPodcast = internalMutation({
  args: { batchId: v.id("importBatches"), podcastId: v.id("podcasts"), feedOk: v.boolean() },
  returns: v.boolean(),
  handler: async (ctx, { batchId, podcastId, feedOk }) => {
    const batch = await ctx.db.get(batchId);
    if (!batch) return true;
    const items = await ctx.db
      .query("importItems")
      .withIndex("by_batch_podcast", (q) => q.eq("batchId", batchId).eq("podcastId", podcastId))
      .take(MATCH_PAGE);
    const delta = { ...emptyCounts(), earliestListenAt: undefined as number | undefined };
    for (const item of items) {
      const { episode, matched } = await matchOrGhost(ctx, podcastId, item);
      if (matched) delta.episodesMatched++;
      else delta.ghostEpisodes++;
      const r = await applyImportedState(ctx, batch, episode, item);
      if (item.played) delta.playedEpisodes++;
      else if ((item.progress ?? 0) > 0) delta.inProgressEpisodes++;
      if (item.userRecommendedAt) delta.starredEpisodes++;
      if (r.sessionWall !== undefined) {
        delta.sessions++;
        delta.estimatedListenSeconds += r.sessionWall;
        delta.earliestListenAt = Math.min(delta.earliestListenAt ?? Infinity, r.sessionStart!);
      }
      await ctx.db.delete(item._id);
    }
    const done = items.length < MATCH_PAGE;
    if (done) {
      delta.podcastsProcessed = 1;
      if (!feedOk) delta.feedsFailed = 1;
      const episodeCount = await countEpisodes(ctx, podcastId);
      await ctx.db.patch(podcastId, { episodeCount, updatedAt: Date.now() });
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

/** Enclosure URL (query stripped), then GUID (Overcast's `url`), then title + date. Else a ghost. */
async function matchOrGhost(ctx: MutationCtx, podcastId: Id<"podcasts">, item: Doc<"importItems">) {
  const match = { enclosureUrl: item.enclosureUrl, title: item.title, pubDate: item.pubDate };
  const found =
    (await findByEnclosure(ctx, podcastId, match)) ??
    (await findByGuid(ctx, podcastId, item.url)) ??
    (await findByTitleDate(ctx, podcastId, match));
  if (found) return { episode: found, matched: !found.isGhost };
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

async function applyImportedState(
  ctx: MutationCtx,
  batch: Doc<"importBatches">,
  episode: Doc<"episodes">,
  item: Doc<"importItems">,
): Promise<{ sessionWall?: number; sessionStart?: number }> {
  const at = item.userUpdatedAt ?? item.pubDate ?? batch.startedAt;
  if (item.played) await setPlayed(ctx, episode, true, at);
  else if ((item.progress ?? 0) > 0) await setPosition(ctx, episode, item.progress!, at, "overcast-import");
  if (item.userRecommendedAt) await setStarred(ctx, episode, true, item.userRecommendedAt);
  if (item.userDeleted) await setArchived(ctx, episode, true, at);

  if (!countsAsListened(item) || item.userUpdatedAt === undefined) return {};
  // Content heard: the whole episode if played, else how far he got.
  const content = item.played ? (episode.duration ?? item.progress ?? 0) : (item.progress ?? 0);
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
  return { sessionWall: wall, sessionStart: startedAt };
}
