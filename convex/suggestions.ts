import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type QueryCtx } from "./_generated/server";
import { userMutation, userQuery } from "./lib/auth";
import { normalizeFeedUrl } from "./lib/parse";
import { MAX_AGE_MS, type Seed, vSuggestion } from "./lib/suggestions";

// "For you" on Discover (docs/decisions.md, 3 Nov 2026): episodes picked with the person's own Exa
// key, so Poddle never pays for it. The network side is in suggestionsActions.ts.

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
/** About 12 Exa calls, $0.11 of the person's money, so not often. */
const REFRESH_EVERY = 7 * DAY;
/** A refresh that hasn't finished by now has died, and shouldn't show a spinner for ever. */
const REFRESH_TIMEOUT = 5 * 60_000;
const MAX_SEEDS = 6;
const MAX_SEEDS_PER_SHOW = 2;
const RECENT = 60 * DAY;

const suggestionsFor = (ctx: QueryCtx, userId: Id<"users">) =>
  ctx.db
    .query("suggestions")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();
const keyFor = (ctx: QueryCtx, userId: Id<"users">) =>
  ctx.db
    .query("exaKeys")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();

/** What Discover and Profile show. The key itself never comes back: just its last characters. */
export const forYou = userQuery({
  args: {},
  returns: v.object({
    hasKey: v.boolean(),
    keyEnding: v.optional(v.string()),
    refreshing: v.boolean(),
    refreshedAt: v.optional(v.number()),
    error: v.optional(v.string()),
    picks: v.array(vSuggestion),
  }),
  handler: async (ctx) => {
    const [key, row] = await Promise.all([keyFor(ctx, ctx.userId), suggestionsFor(ctx, ctx.userId)]);
    const picks = [];
    for (const pick of row?.picks ?? []) {
      // Followed since the last refresh: it's in their library now, so it isn't a suggestion.
      const show = await ctx.db
        .query("podcasts")
        .withIndex("by_feedUrl", (q) => q.eq("feedUrl", normalizeFeedUrl(pick.feedUrl)))
        .first();
      const sub =
        show &&
        (await ctx.db
          .query("subscriptions")
          .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId).eq("podcastId", show._id))
          .unique());
      if (!sub?.subscribed) picks.push(pick);
    }
    return {
      hasKey: key !== null,
      keyEnding: key?.ending,
      refreshing: row?.refreshingSince !== undefined && Date.now() - row.refreshingSince < REFRESH_TIMEOUT,
      refreshedAt: row?.refreshedAt,
      error: row?.error,
      picks,
    };
  },
});

export const removeKey = userMutation({
  args: {},
  returns: v.null(),
  handler: async (ctx) => {
    const [key, row] = await Promise.all([keyFor(ctx, ctx.userId), suggestionsFor(ctx, ctx.userId)]);
    if (key) await ctx.db.delete(key._id);
    if (row) await ctx.db.delete(row._id);
    return null;
  },
});

/**
 * Marks the refresh as started here rather than when it runs. The app asks the moment the key's
 * saved, and if it heard "not refreshing" it would stop looking before the picks arrived.
 */
export const saveKey = internalMutation({
  args: { userId: v.id("users"), ciphertext: v.string(), ending: v.string() },
  returns: v.null(),
  handler: async (ctx, { userId, ciphertext, ending }) => {
    const now = Date.now();
    const existing = await keyFor(ctx, userId);
    if (existing) await ctx.db.patch(existing._id, { ciphertext, ending, updatedAt: now });
    else await ctx.db.insert("exaKeys", { userId, ciphertext, ending, updatedAt: now });
    const row = await suggestionsFor(ctx, userId);
    if (row) await ctx.db.patch(row._id, { refreshingSince: now, error: undefined });
    else await ctx.db.insert("suggestions", { userId, picks: [], refreshingSince: now });
    await ctx.scheduler.runAfter(0, internal.suggestionsActions.refreshFor, { userId, claimed: true });
    return null;
  },
});

export const encryptedKey = internalQuery({
  args: { userId: v.id("users") },
  returns: v.union(v.string(), v.null()),
  handler: async (ctx, { userId }) => (await keyFor(ctx, userId))?.ciphertext ?? null,
});

async function isPrivate(ctx: QueryCtx, userId: Id<"users">, show: Doc<"podcasts">): Promise<boolean> {
  const sub = await ctx.db
    .query("subscriptions")
    .withIndex("by_user_podcast", (q) => q.eq("userId", userId).eq("podcastId", show._id))
    .unique();
  return sub?.isPrivate ?? show.isPrivate;
}

/**
 * What to search around: recent stars, then what they've really listened to lately, then (for
 * someone new) the shows they follow. These titles go to Exa, so private shows are never in here.
 */
export const seedsFor = internalQuery({
  args: { userId: v.id("users") },
  returns: v.array(v.object({ title: v.string(), showTitle: v.string(), why: v.union(v.literal("starred"), v.literal("listened"), v.literal("follows")) })),
  handler: async (ctx, { userId }) => {
    const now = Date.now();
    const seeds: Seed[] = [];
    const perShow = new Map<string, number>();
    const add = async (episodeId: Id<"episodes">, why: Seed["why"]) => {
      if (seeds.length >= MAX_SEEDS) return;
      const episode = await ctx.db.get(episodeId);
      const show = episode && (await ctx.db.get(episode.podcastId));
      if (!episode || !show || (perShow.get(show._id) ?? 0) >= MAX_SEEDS_PER_SHOW) return;
      // An old favourite says little about what they'd like now, and finds old-news neighbours.
      if (episode.pubDate !== undefined && now - episode.pubDate > MAX_AGE_MS) return;
      if (seeds.some((s) => s.title === episode.title) || (await isPrivate(ctx, userId, show))) return;
      perShow.set(show._id, (perShow.get(show._id) ?? 0) + 1);
      seeds.push({ title: episode.title, showTitle: show.title, why });
    };

    const starred = await ctx.db
      .query("episodeStates")
      .withIndex("by_user_starred", (q) => q.eq("userId", userId).eq("starred", true))
      .order("desc")
      .take(10);
    for (const s of starred.slice(0, 5)) {
      if (seeds.length < 2) await add(s.episodeId, "starred");
    }

    const sessions = await ctx.db
      .query("listeningSessions")
      .withIndex("by_user_startedAt", (q) => q.eq("userId", userId).gte("startedAt", now - RECENT))
      .order("desc")
      .take(2000);
    const heard = new Map<Id<"episodes">, number>();
    for (const s of sessions) {
      // Overcast imports backdate plays into this window, and say nothing about right now.
      if (!s.isEstimated) heard.set(s.episodeId, (heard.get(s.episodeId) ?? 0) + (s.endedAt - s.startedAt));
    }
    for (const [episodeId] of [...heard].sort((a, b) => b[1] - a[1]).slice(0, 30)) await add(episodeId, "listened");

    if (seeds.length < 3) {
      const follows = await ctx.db
        .query("subscriptions")
        .withIndex("by_user_subscribed", (q) => q.eq("userId", userId).eq("subscribed", true))
        .take(100);
      for (const f of follows.sort((a, b) => (b.subscribedAt ?? 0) - (a.subscribedAt ?? 0))) {
        if (seeds.length >= 4) break;
        const show = await ctx.db.get(f.podcastId);
        if (show && !(await isPrivate(ctx, userId, show))) seeds.push({ title: show.title, showTitle: show.title, why: "follows" });
      }
    }
    return seeds;
  },
});

/** False if one's already running, so two can't spend their money at once. */
export const startRefresh = internalMutation({
  args: { userId: v.id("users") },
  returns: v.boolean(),
  handler: async (ctx, { userId }) => {
    const now = Date.now();
    const row = await suggestionsFor(ctx, userId);
    if (row?.refreshingSince !== undefined && now - row.refreshingSince < REFRESH_TIMEOUT) return false;
    if (row) await ctx.db.patch(row._id, { refreshingSince: now });
    else await ctx.db.insert("suggestions", { userId, picks: [], refreshingSince: now });
    return true;
  },
});

export const finishRefresh = internalMutation({
  args: { userId: v.id("users"), picks: v.optional(v.array(vSuggestion)), error: v.optional(v.string()) },
  returns: v.null(),
  handler: async (ctx, { userId, picks, error }) => {
    const row = await suggestionsFor(ctx, userId);
    if (!row) return null; // They removed their key part way through.
    // A failure keeps the last good picks, and leaves refreshedAt so tomorrow's cron tries again.
    await ctx.db.patch(row._id, {
      refreshingSince: undefined,
      error,
      ...(picks ? { picks, refreshedAt: Date.now() } : {}),
    });
    return null;
  },
});

/** Daily: everyone with a key whose picks are a week old, spread out so they don't all hit Exa together. */
export const refreshDue = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const now = Date.now();
    let scheduled = 0;
    for (const key of await ctx.db.query("exaKeys").take(1000)) {
      if (!key.userId) continue;
      const row = await suggestionsFor(ctx, key.userId);
      if (row?.refreshedAt !== undefined && now - row.refreshedAt < REFRESH_EVERY) continue;
      await ctx.scheduler.runAfter(scheduled * 20_000, internal.suggestionsActions.refreshFor, { userId: key.userId });
      scheduled++;
    }
    return scheduled;
  },
});
