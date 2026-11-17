import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { scheduleSyncWake } from "./devices";
import { asUser, type UserMutationCtx } from "./lib/auth";
import { upsertEpisode, vIncomingEpisode, vIngestMode } from "./lib/ingest";
import { trimToKeepLatest } from "./lib/keepLatest";
import { hasSubscribers, subscribersOf } from "./lib/library";
import { addToQueue } from "./lib/queue";
import type { NewEpisodeRule } from "./lib/settings";
import { resolvedSettingsFor } from "./lib/settingsDb";
import { systemAt } from "./lib/state";
import { asMutationCtx, feedFetch, machines } from "./machines";

// Feed bookkeeping and ingestion. The fetching itself happens in feedActions.ts.
// Feeds are shared: each is polled once, and each new episode is then applied
// to every subscriber with that person's own new-episode rule.

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
export const POLL_INTERVAL = 15 * MINUTE;

/** How long to wait before checking a feed again. Quiet feeds are checked less often. */
export function nextCheckDelay(latestEpisodeAt: number | undefined, consecutiveErrors: number, now: number): number {
  if (consecutiveErrors > 0) return Math.min(POLL_INTERVAL * 2 ** consecutiveErrors, DAY);
  const age = latestEpisodeAt === undefined ? Infinity : now - latestEpisodeAt;
  if (age < 7 * DAY) return POLL_INTERVAL;
  if (age < 30 * DAY) return HOUR;
  if (age < 180 * DAY) return 4 * HOUR;
  return 12 * HOUR;
}


export async function feedStateFor(ctx: QueryCtx, podcastId: Id<"podcasts">) {
  return await ctx.db
    .query("feedStates")
    .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
    .unique();
}

/** Make sure a podcast has fetch bookkeeping; `active` is whether anyone subscribes. */
export async function ensureFeedState(ctx: MutationCtx, podcastId: Id<"podcasts">, active: boolean, checkNow: boolean) {
  const now = Date.now();
  const existing = await feedStateFor(ctx, podcastId);
  if (existing) {
    await ctx.db.patch(existing._id, { active, ...(checkNow ? { nextCheckAt: now } : {}) });
    return existing._id;
  }
  return await ctx.db.insert("feedStates", { podcastId, active, nextCheckAt: now, consecutiveErrors: 0 });
}

/** A fetch holds this lease so the cron, refreshNow and imports never fetch one feed twice at once. */
const FETCH_LEASE_MS = 5 * MINUTE;

/** The feed's fetch claim (the feedFetch machine), if it's ever been fetched since claims moved there. */
export async function feedFetchFor(ctx: QueryCtx, podcastId: Id<"podcasts">) {
  return await ctx.db
    .query("feedFetches")
    .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
    .unique();
}

/** Whether a fetch of the feed holds a claim that hasn't run out. */
export async function isBeingFetched(ctx: QueryCtx, podcastId: Id<"podcasts">, now: number) {
  const claim = (await feedFetchFor(ctx, podcastId))?.state;
  return claim?.kind === "fetching" && claim.until > now;
}

/** Claim a feed for fetching (feedFetch's CLAIM). Returns null if it's unknown or already being fetched. */
export const claimFetch = machines.internalMutation({
  args: { podcastId: v.id("podcasts") },
  returns: v.union(
    v.null(),
    v.object({
      feedUrl: v.string(),
      etag: v.optional(v.string()),
      lastModified: v.optional(v.string()),
      bodyHash: v.optional(v.string()),
      isFirstFetch: v.boolean(),
      latestEpisodeAt: v.optional(v.number()),
      /** This claim's lease (its expiry). recordFetch takes it back, so only the claim's own fetch can release it. */
      lease: v.number(),
    }),
  ),
  handler: async (machineCtx, { podcastId }) => {
    const ctx = asMutationCtx(machineCtx);
    const podcast = await ctx.db.get(podcastId);
    if (!podcast) return null;
    const now = Date.now();
    const lease = now + FETCH_LEASE_MS;
    const claim = await feedFetchFor(ctx, podcastId);
    const claimed = claim
      ? await feedFetch.send(machineCtx, claim._id, { type: "CLAIM", lease })
      : await feedFetch.create(machineCtx, { podcastId }, { type: "CLAIM", lease });
    if (claimed.status !== "done") return null;
    const stateId = await ensureFeedState(ctx, podcastId, await hasSubscribers(ctx, podcastId), false);
    const state = (await ctx.db.get(stateId))!;
    return {
      lease,
      feedUrl: podcast.feedUrl,
      etag: state.etag,
      lastModified: state.lastModified,
      bodyHash: state.bodyHash,
      isFirstFetch: !state.lastSuccessAt,
      latestEpisodeAt: podcast.latestEpisodeAt,
    };
  },
});

/** How a fetch went (and feedFetch's FINISHED, which lets the feed go). */
export const recordFetch = machines.internalMutation({
  args: {
    podcastId: v.id("podcasts"),
    /** The claim's lease, from claimFetch. */
    lease: v.number(),
    status: v.number(),
    error: v.optional(v.string()),
    etag: v.optional(v.string()),
    lastModified: v.optional(v.string()),
    bodyHash: v.optional(v.string()),
    changed: v.boolean(),
  },
  /** False: the fetch had lost its claim, and nothing was recorded. */
  returns: v.boolean(),
  handler: async (machineCtx, a) => {
    const ctx = asMutationCtx(machineCtx);
    const now = Date.now();
    const podcast = await ctx.db.get(a.podcastId);
    if (!podcast) return false;
    // A fetch that ran past its claim, after another took the feed over (or that
    // one already finished), is refused: its answer is older, and letting the feed
    // go would let a third fetch start alongside the one holding it. A fetch
    // claimed before claims moved to feedFetches has no row there, and is checked
    // against its old lease on feedStates.
    if (!(await holdsLease(ctx, a.podcastId, a.lease))) {
      console.warn(`A fetch of ${podcast._id} reported after its claim was taken over; ignoring its bookkeeping`);
      return false;
    }
    const claim = await feedFetchFor(ctx, a.podcastId);
    if (claim && (await feedFetch.send(machineCtx, claim._id, { type: "FINISHED", lease: a.lease })).status !== "done") return false;
    const stateId = await ensureFeedState(ctx, a.podcastId, await hasSubscribers(ctx, a.podcastId), false);
    const state = (await ctx.db.get(stateId))!;
    const ok = !a.error;
    const consecutiveErrors = ok ? 0 : state.consecutiveErrors + 1;
    await ctx.db.patch(stateId, {
      lastCheckedAt: now,
      lastStatus: a.status,
      lastError: a.error,
      consecutiveErrors,
      nextCheckAt: now + nextCheckDelay(podcast.latestEpisodeAt, consecutiveErrors, now),
      ...(ok ? { lastSuccessAt: now } : {}),
      ...(a.changed ? { lastChangedAt: now } : {}),
      ...(a.etag !== undefined ? { etag: a.etag } : {}),
      ...(a.lastModified !== undefined ? { lastModified: a.lastModified } : {}),
      ...(a.bodyHash !== undefined ? { bodyHash: a.bodyHash } : {}),
    });
    if (ok && podcast.lastFetchedAt === undefined) {
      await ctx.db.patch(a.podcastId, { lastFetchedAt: now, updatedAt: now });
    }
    return true;
  },
});

/**
 * Whether the fetch with this lease still holds the feed. A fetch that lost it
 * stores nothing more: the one that took over has a newer answer.
 */
async function holdsLease(ctx: QueryCtx, podcastId: Id<"podcasts">, lease: number) {
  const claim = await feedFetchFor(ctx, podcastId);
  return claim?.state.kind === "fetching" && claim.state.until === lease;
}

export const updatePodcastMeta = internalMutation({
  args: {
    podcastId: v.id("podcasts"),
    /** The fetch's lease, from claimFetch: a fetch that lost it writes nothing. */
    lease: v.number(),
    title: v.string(),
    author: v.optional(v.string()),
    description: v.optional(v.string()),
    artworkUrl: v.optional(v.string()),
    link: v.optional(v.string()),
    language: v.optional(v.string()),
    newFeedUrl: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { podcastId, lease, newFeedUrl, ...meta }) => {
    const podcast = await ctx.db.get(podcastId);
    if (!podcast || !(await holdsLease(ctx, podcastId, lease))) return null;
    const patch: Partial<Doc<"podcasts">> = {};
    for (const [k, val] of Object.entries(meta) as [keyof typeof meta, string | undefined][]) {
      if (val !== undefined && podcast[k] !== val) (patch as Record<string, unknown>)[k] = val;
    }
    if (newFeedUrl && newFeedUrl !== podcast.feedUrl && /^https?:\/\//.test(newFeedUrl)) {
      const clash = await ctx.db
        .query("podcasts")
        .withIndex("by_feedUrl", (q) => q.eq("feedUrl", newFeedUrl))
        .first();
      if (!clash) patch.feedUrl = newFeedUrl;
    }
    if (Object.keys(patch).length) await ctx.db.patch(podcastId, { ...patch, updatedAt: Date.now() });
    return null;
  },
});

/** New items older than this, relative to the previous newest episode, are back-catalogue, not news. */
const BACKFILL_SLACK = 2 * DAY;
const MAX_RULED_PER_CHUNK = 10;

export const ingestEpisodes = internalMutation({
  args: {
    podcastId: v.id("podcasts"),
    /** The fetch's lease, from claimFetch: a fetch that lost it stores nothing, and is told so. */
    lease: v.number(),
    mode: vIngestMode,
    /** Newest episode in the whole feed; in "initial" mode only it gets the new-episode rule. */
    isFirstChunk: v.boolean(),
    previousLatestAt: v.optional(v.number()),
    episodes: v.array(vIncomingEpisode),
  },
  returns: v.object({ created: v.number(), ruled: v.array(v.id("episodes")), lostLease: v.optional(v.boolean()) }),
  handler: async (ctx, a) => {
    const podcast = await ctx.db.get(a.podcastId);
    if (!podcast) return { created: 0, ruled: [] };
    if (!(await holdsLease(ctx, a.podcastId, a.lease))) return { created: 0, ruled: [], lostLease: true };
    const now = Date.now();
    const subscribers = a.mode === "import" ? [] : await subscribersOf(ctx, a.podcastId);
    let created = 0;
    let latest = podcast.latestEpisodeAt;
    const qualifying: Doc<"episodes">[] = [];

    for (const [i, incoming] of a.episodes.entries()) {
      const { episode, created: isNew } = await upsertEpisode(ctx, a.podcastId, incoming, now);
      if (episode.pubDate !== undefined && (latest === undefined || episode.pubDate > latest)) latest = episode.pubDate;
      if (!isNew) continue;
      created++;
      if (!subscribers.length) continue;
      const qualifies =
        a.mode === "initial"
          ? a.isFirstChunk && i === 0
          : qualifying.length < MAX_RULED_PER_CHUNK &&
            (a.previousLatestAt === undefined ||
              episode.pubDate === undefined ||
              episode.pubDate >= a.previousLatestAt - BACKFILL_SLACK);
      if (qualifies) qualifying.push(episode);
    }

    // Each subscriber gets the new episodes their way, and alerts on their own devices.
    const ruled = new Set<Id<"episodes">>();
    for (const userId of subscribers) {
      const userCtx = asUser(ctx, userId);
      const settings = await resolvedSettingsFor(userCtx, a.podcastId);
      let landed = false;
      for (const episode of qualifying) {
        if (!(await applyNewEpisodeRule(userCtx, episode, settings.newEpisodes, now))) continue;
        ruled.add(episode._id);
        landed = true;
        // Only genuinely new episodes notify, never the first fetch of a show.
        if (a.mode === "normal" && settings.notifications) {
          await ctx.scheduler.runAfter(0, internal.apns.sendNewEpisodeAlert, { episodeId: episode._id, userId });
        }
      }
      if (!landed) continue;
      await trimToKeepLatest(userCtx, a.podcastId, settings.keepLatestDownloaded, { system: systemAt(now) });
      // Their phone hears about it now, not the next time they open Poddle.
      if (a.mode === "normal") await scheduleSyncWake(ctx, userId, now);
    }

    if (created || latest !== podcast.latestEpisodeAt) {
      await ctx.db.patch(a.podcastId, {
        episodeCount: podcast.episodeCount + created,
        latestEpisodeAt: latest,
        updatedAt: now,
      });
    }
    return { created, ruled: [...ruled] };
  },
});

/**
 * Spec §2.3 and decisions.md. `upNextTop` goes straight after the first item,
 * because the first item is what's playing and shouldn't be bumped. Callers then
 * trim the show to its "Keep latest" (`trimToKeepLatest`), once for all the new episodes.
 */
export async function applyNewEpisodeRule(
  ctx: UserMutationCtx,
  episode: Doc<"episodes">,
  rule: NewEpisodeRule,
  now: number,
): Promise<boolean> {
  switch (rule) {
    case "none":
      return false;
    case "upNextTop":
      return await addToQueue(ctx, episode, "next", systemAt(now), "priority");
    // There's no Inbox any more; a stored `inbox` rule means Up Next bottom.
    case "inbox":
    case "upNextBottom":
      return await addToQueue(ctx, episode, "bottom", systemAt(now), "priority");
  }
}

// ---- Polling ----

const POLL_BATCH = 40;

/** Cron, every 15 min: schedule fetches for subscribed feeds that are due. */
export const pollDueFeeds = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const now = Date.now();
    const due = await ctx.db
      .query("feedStates")
      .withIndex("by_active_nextCheckAt", (q) => q.eq("active", true).lte("nextCheckAt", now))
      .take(POLL_BATCH);
    for (const [i, state] of due.entries()) {
      // Lease it so an overlapping run doesn't fetch twice; recordFetch sets the real time.
      await ctx.db.patch(state._id, { nextCheckAt: now + 10 * MINUTE });
      await ctx.scheduler.runAfter(i * 1500, internal.feedActions.fetchFeed, { podcastId: state.podcastId });
    }
    if (due.length === POLL_BATCH) {
      await ctx.scheduler.runAfter(POLL_BATCH * 1500, internal.feeds.pollDueFeeds, {});
    }
    return due.length;
  },
});

/**
 * Pull-to-refresh / app foreground: the feeds this person subscribes to that
 * weren't checked in the last 2 min and aren't mid-fetch.
 *
 * A query, not part of the mutation that schedules them (PODDLE-3): fetches
 * already in flight keep patching these feedStates through recordFetch, and
 * reading a big library's worth of them inside a mutation conflicted with every
 * retry. The fetch lease in claimFetch stops a feed being fetched twice.
 */
export const feedsToRefresh = internalQuery({
  args: { userId: v.id("users") },
  returns: v.array(v.id("podcasts")),
  handler: async (ctx, { userId }) => {
    const now = Date.now();
    const subs = await ctx.db
      .query("subscriptions")
      .withIndex("by_user_subscribed", (q) => q.eq("userId", userId).eq("subscribed", true))
      .collect();
    const due: Id<"podcasts">[] = [];
    for (const sub of subs) {
      const state = await feedStateFor(ctx, sub.podcastId);
      if (!state) continue;
      if (state.lastCheckedAt && now - state.lastCheckedAt < 2 * MINUTE) continue;
      if (await isBeingFetched(ctx, sub.podcastId, now)) continue;
      due.push(sub.podcastId);
    }
    return due;
  },
});

/** Schedules the fetches `feedsToRefresh` found. Reads nothing, so it can't conflict with landing fetches. */
export const scheduleFetches = internalMutation({
  args: { podcastIds: v.array(v.id("podcasts")) },
  returns: v.null(),
  handler: async (ctx, { podcastIds }) => {
    for (const [n, podcastId] of podcastIds.entries()) {
      await ctx.scheduler.runAfter((n % 10) * 300, internal.feedActions.fetchFeed, { podcastId });
    }
    return null;
  },
});
