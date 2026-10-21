import { paginationOptsValidator, paginationResultValidator } from "convex/server";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, type MutationCtx, type QueryCtx } from "./_generated/server";
import { feedStateFor, ensureFeedState } from "./feeds";
import { userMutation, userQuery } from "./lib/auth";
import { looksPrivate, normalizeFeedUrl } from "./lib/parse";
import { resolveShowSettings, resolveGlobalSettings, showSettingFields } from "./lib/settings";
import { globalSettingsDoc, overridesOf, podcastSettingsDoc } from "./lib/settingsDb";
import { episodeRows } from "./lib/rows";
import { logEvent, setInbox, setPlayed } from "./lib/state";
import { vEpisodeRow, vPodcastDoc } from "./lib/validators";

// Library: subscriptions, past shows, a show's page.

export const list = userQuery({
  args: {},
  returns: v.array(vPodcastDoc),
  handler: async (ctx) => {
    return await ctx.db
      .query("podcasts")
      .withIndex("by_subscribed_title", (q) => q.eq("subscribed", true))
      .collect();
  },
});

async function hasHistory(ctx: QueryCtx, podcastId: Id<"podcasts">) {
  const session = await ctx.db
    .query("listeningSessions")
    .withIndex("by_podcast_startedAt", (q) => q.eq("podcastId", podcastId))
    .first();
  if (session) return true;
  const states = await ctx.db
    .query("episodeStates")
    .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
    .take(200);
  return states.some((s) => s.played || s.position > 0 || s.starred);
}

/** Unsubscribed shows that still have listening history (spec §2.1 "Past shows"). */
export const pastShows = userQuery({
  args: {},
  returns: v.array(vPodcastDoc),
  handler: async (ctx) => {
    const unsubscribed = await ctx.db
      .query("podcasts")
      .withIndex("by_subscribed_title", (q) => q.eq("subscribed", false))
      .collect();
    const out: Doc<"podcasts">[] = [];
    for (const p of unsubscribed) if (await hasHistory(ctx, p._id)) out.push(p);
    return out;
  },
});

export const get = userQuery({
  args: { podcastId: v.id("podcasts") },
  returns: v.union(
    v.null(),
    v.object({
      podcast: vPodcastDoc,
      overrides: v.object(Object.fromEntries(Object.entries(showSettingFields).map(([k, val]) => [k, v.optional(val)]))),
      resolved: v.object({ ...showSettingFields, inherited: v.array(v.string()) }),
      feed: v.object({
        lastCheckedAt: v.optional(v.number()),
        lastSuccessAt: v.optional(v.number()),
        nextCheckAt: v.optional(v.number()),
        lastError: v.optional(v.string()),
      }),
    }),
  ),
  handler: async (ctx, { podcastId }) => {
    const podcast = await ctx.db.get(podcastId);
    if (!podcast) return null;
    const overrides = overridesOf(await podcastSettingsDoc(ctx, podcastId));
    const resolved = resolveShowSettings(resolveGlobalSettings(await globalSettingsDoc(ctx)), overrides);
    const state = await feedStateFor(ctx, podcastId);
    return {
      podcast,
      overrides,
      resolved,
      feed: {
        lastCheckedAt: state?.lastCheckedAt,
        lastSuccessAt: state?.lastSuccessAt,
        nextCheckAt: state?.nextCheckAt,
        lastError: state?.lastError,
      },
    };
  },
});

/** A show's episodes, paginated, newest first unless `order` is "oldestFirst". */
export const episodes = userQuery({
  args: {
    podcastId: v.id("podcasts"),
    order: v.optional(v.union(v.literal("newestFirst"), v.literal("oldestFirst"))),
    paginationOpts: paginationOptsValidator,
  },
  returns: paginationResultValidator(vEpisodeRow),
  handler: async (ctx, { podcastId, order, paginationOpts }) => {
    const page = await ctx.db
      .query("episodes")
      .withIndex("by_podcast_pubDate", (q) => q.eq("podcastId", podcastId))
      .order(order === "oldestFirst" ? "asc" : "desc")
      .paginate(paginationOpts);
    return { ...page, page: await episodeRows(ctx, page.page) };
  },
});

export async function findPodcastByFeedUrl(ctx: QueryCtx, feedUrl: string) {
  return await ctx.db
    .query("podcasts")
    .withIndex("by_feedUrl", (q) => q.eq("feedUrl", feedUrl))
    .first();
}

/** Create a podcast row (unsubscribed) if this feed isn't known yet. */
export async function getOrCreatePodcast(
  ctx: MutationCtx,
  input: { feedUrl: string; title?: string; author?: string; artworkUrl?: string; appleId?: number; overcastId?: number },
): Promise<Doc<"podcasts">> {
  const feedUrl = normalizeFeedUrl(input.feedUrl);
  const existing = await findPodcastByFeedUrl(ctx, feedUrl);
  if (existing) return existing;
  const now = Date.now();
  const id = await ctx.db.insert("podcasts", {
    feedUrl,
    title: input.title ?? feedUrl,
    author: input.author,
    artworkUrl: input.artworkUrl,
    appleId: input.appleId,
    overcastId: input.overcastId,
    isPrivate: looksPrivate(feedUrl),
    subscribed: false,
    subscriptionUpdatedAt: 0,
    episodeCount: 0,
    createdAt: now,
    updatedAt: now,
  });
  return (await ctx.db.get(id))!;
}

export async function setSubscribed(ctx: MutationCtx, podcast: Doc<"podcasts">, subscribed: boolean, at: number) {
  if (at < podcast.subscriptionUpdatedAt) return false;
  const now = Date.now();
  if (podcast.subscribed === subscribed) {
    await ctx.db.patch(podcast._id, { subscriptionUpdatedAt: at });
    return false;
  }
  await ctx.db.patch(podcast._id, {
    subscribed,
    subscriptionUpdatedAt: at,
    ...(subscribed ? { subscribedAt: podcast.subscribedAt ?? at, unsubscribedAt: undefined } : { unsubscribedAt: at }),
    updatedAt: now,
  });
  await logEvent(ctx, `${subscribed ? "subscribed" : "unsubscribed"}:${podcast._id}:${at}`, subscribed ? "subscribed" : "unsubscribed", at, {
    podcastId: podcast._id,
  });
  await ensureFeedState(ctx, podcast._id, subscribed, subscribed);
  return true;
}

/**
 * Subscribe by feed URL. Creates the show if needed and fetches it straight away.
 * Only the newest episode lands in the Inbox (or Up Next, per the show's rule).
 */
export const subscribe = userMutation({
  args: {
    feedUrl: v.string(),
    at: v.number(),
    title: v.optional(v.string()),
    author: v.optional(v.string()),
    artworkUrl: v.optional(v.string()),
    appleId: v.optional(v.number()),
  },
  returns: v.id("podcasts"),
  handler: async (ctx, { at, ...input }) => {
    const podcast = await getOrCreatePodcast(ctx, input);
    if (input.appleId && !podcast.appleId) await ctx.db.patch(podcast._id, { appleId: input.appleId });
    if (await setSubscribed(ctx, podcast, true, at)) {
      await ctx.scheduler.runAfter(0, internal.feedActions.fetchFeed, { podcastId: podcast._id });
    }
    return podcast._id;
  },
});

/** Unsubscribe. History, queue entries and stats are kept; its Inbox entries are cleared. */
export const unsubscribe = userMutation({
  args: { podcastId: v.id("podcasts"), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { podcastId, at }) => {
    const podcast = await ctx.db.get(podcastId);
    if (!podcast) return false;
    const changed = await setSubscribed(ctx, podcast, false, at);
    if (changed) {
      const inbox = await ctx.db
        .query("episodeStates")
        .withIndex("by_podcast_inbox", (q) => q.eq("podcastId", podcastId).eq("inInbox", true))
        .collect();
      for (const s of inbox) {
        const episode = await ctx.db.get(s.episodeId);
        if (episode) await setInbox(ctx, episode, false, at);
      }
    }
    return changed;
  },
});

export const setPrivate = userMutation({
  args: { podcastId: v.id("podcasts"), isPrivate: v.boolean() },
  returns: v.null(),
  handler: async (ctx, { podcastId, isPrivate }) => {
    await ctx.db.patch(podcastId, { isPrivate, updatedAt: Date.now() });
    return null;
  },
});

/** "Mark all played" / "Mark all older as played" on a show. Runs in batches. */
export const markAllPlayed = userMutation({
  args: { podcastId: v.id("podcasts"), at: v.number(), beforePubDate: v.optional(v.number()) },
  returns: v.null(),
  handler: async (ctx, args) => {
    await ctx.scheduler.runAfter(0, internal.podcasts.markAllPlayedBatch, { ...args, cursor: null });
    return null;
  },
});

export const markAllPlayedBatch = internalMutation({
  args: {
    podcastId: v.id("podcasts"),
    at: v.number(),
    beforePubDate: v.optional(v.number()),
    cursor: v.union(v.string(), v.null()),
  },
  returns: v.null(),
  handler: async (ctx, { podcastId, at, beforePubDate, cursor }) => {
    const page = await ctx.db
      .query("episodes")
      .withIndex("by_podcast_pubDate", (q) =>
        beforePubDate === undefined ? q.eq("podcastId", podcastId) : q.eq("podcastId", podcastId).lt("pubDate", beforePubDate),
      )
      .paginate({ cursor, numItems: 100 });
    // Bulk marking isn't listening, so it doesn't count towards completion stats.
    for (const episode of page.page) await setPlayed(ctx, episode, true, at, { countCompletion: false });
    if (!page.isDone) {
      await ctx.scheduler.runAfter(0, internal.podcasts.markAllPlayedBatch, { podcastId, at, beforePubDate, cursor: page.continueCursor });
    }
    return null;
  },
});
