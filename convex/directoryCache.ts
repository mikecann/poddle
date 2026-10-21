import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import { normalizeFeedUrl } from "./lib/parse";

// Storage helpers for directory.ts (Node actions can't touch the db directly).

const TTL_MS = 24 * 60 * 60 * 1000;

export const getCached = internalQuery({
  args: { key: v.string() },
  returns: v.union(v.string(), v.null()),
  handler: async (ctx, { key }) => {
    const hit = await ctx.db
      .query("directoryCache")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    return hit && Date.now() - hit.fetchedAt < TTL_MS ? hit.json : null;
  },
});

export const putCached = internalMutation({
  args: { key: v.string(), json: v.string() },
  returns: v.null(),
  handler: async (ctx, { key, json }) => {
    const hit = await ctx.db
      .query("directoryCache")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    if (hit) await ctx.db.patch(hit._id, { json, fetchedAt: Date.now() });
    else await ctx.db.insert("directoryCache", { key, json, fetchedAt: Date.now() });
    return null;
  },
});

/** Which of these feed URLs are already in the library. */
export const libraryMatches = internalQuery({
  args: { feedUrls: v.array(v.string()) },
  returns: v.array(
    v.object({ feedUrl: v.string(), podcastId: v.id("podcasts"), subscribed: v.boolean() }),
  ),
  handler: async (ctx, { feedUrls }) => {
    const out = [];
    for (const raw of feedUrls) {
      const feedUrl = normalizeFeedUrl(raw);
      const p = await ctx.db
        .query("podcasts")
        .withIndex("by_feedUrl", (q) => q.eq("feedUrl", feedUrl))
        .first();
      if (p) out.push({ feedUrl: raw, podcastId: p._id, subscribed: p.subscribed });
    }
    return out;
  },
});
