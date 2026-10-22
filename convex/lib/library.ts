import type { Doc, Id } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";
import type { UserMutationCtx, UserQueryCtx } from "./auth";

// Someone's library: one `subscriptions` row per show they've subscribed to or
// have any state for. Shows themselves are shared; the app still gets one
// Podcast document per show, with this person's subscription merged in.

export async function subscriptionFor(ctx: UserQueryCtx, podcastId: Id<"podcasts">) {
  return await ctx.db
    .query("subscriptions")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId).eq("podcastId", podcastId))
    .unique();
}

/** Make sure the show is in this person's library (unsubscribed if it's new). */
export async function ensureLibraryRow(ctx: UserMutationCtx, podcastId: Id<"podcasts">): Promise<Doc<"subscriptions">> {
  const existing = await subscriptionFor(ctx, podcastId);
  if (existing) return existing;
  const now = Date.now();
  const id = await ctx.db.insert("subscriptions", {
    userId: ctx.userId,
    podcastId,
    subscribed: false,
    subscriptionUpdatedAt: 0,
    addedAt: now,
    updatedAt: now,
  });
  return (await ctx.db.get(id))!;
}

/** Everyone subscribed to a show. */
export async function subscribersOf(ctx: QueryCtx, podcastId: Id<"podcasts">): Promise<Id<"users">[]> {
  const subs = await ctx.db
    .query("subscriptions")
    .withIndex("by_podcast_subscribed", (q) => q.eq("podcastId", podcastId).eq("subscribed", true))
    .collect();
  return subs.flatMap((s) => (s.userId ? [s.userId] : []));
}

export async function hasSubscribers(ctx: QueryCtx, podcastId: Id<"podcasts">): Promise<boolean> {
  const first = await ctx.db
    .query("subscriptions")
    .withIndex("by_podcast_subscribed", (q) => q.eq("podcastId", podcastId).eq("subscribed", true))
    .first();
  return first !== null;
}

/** Shared show fields only, without the single-user subscription leftovers. */
function catalog(p: Doc<"podcasts">) {
  const { subscribed: _s, subscribedAt: _sa, unsubscribedAt: _ua, subscriptionUpdatedAt: _su, ...rest } = p;
  return rest;
}

/** The Podcast document the app sees: the shared show plus this person's subscription. */
export function podcastView(p: Doc<"podcasts">, sub: Doc<"subscriptions"> | null) {
  return {
    ...catalog(p),
    subscribed: sub?.subscribed ?? false,
    subscribedAt: sub?.subscribedAt,
    unsubscribedAt: sub?.unsubscribedAt,
    subscriptionUpdatedAt: sub?.subscriptionUpdatedAt ?? 0,
    isPrivate: sub?.isPrivate ?? p.isPrivate,
    updatedAt: Math.max(p.updatedAt, sub?.updatedAt ?? 0),
  };
}
export type PodcastView = ReturnType<typeof podcastView>;

/** A show and this person's subscription, cached for a batch of lookups. */
export function showCache(ctx: UserQueryCtx) {
  const cache = new Map<Id<"podcasts">, Promise<PodcastView | null>>();
  return (podcastId: Id<"podcasts">) => {
    let hit = cache.get(podcastId);
    if (!hit) {
      hit = (async () => {
        const p = await ctx.db.get(podcastId);
        return p ? podcastView(p, await subscriptionFor(ctx, podcastId)) : null;
      })();
      cache.set(podcastId, hit);
    }
    return hit;
  };
}
