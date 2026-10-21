import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import { userMutation, userQuery } from "./lib/auth";
import { vDeviceDoc } from "./lib/validators";

// Devices and their APNs tokens. `deviceId` is a stable UUID the app keeps in the Keychain.

export const register = userMutation({
  args: {
    deviceId: v.string(),
    name: v.string(),
    platform: v.string(),
    apnsToken: v.optional(v.string()),
    apnsEnvironment: v.optional(v.union(v.literal("sandbox"), v.literal("production"))),
  },
  returns: v.id("devices"),
  handler: async (ctx, args) => {
    const now = Date.now();
    // A token belongs to one device; drop it from any other row.
    if (args.apnsToken) {
      const holders = await ctx.db
        .query("devices")
        .withIndex("by_apnsToken", (q) => q.eq("apnsToken", args.apnsToken))
        .collect();
      for (const h of holders) {
        if (h.deviceId !== args.deviceId) await ctx.db.patch(h._id, { apnsToken: undefined, updatedAt: now });
      }
    }
    const existing = await ctx.db
      .query("devices")
      .withIndex("by_deviceId", (q) => q.eq("deviceId", args.deviceId))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { ...args, lastSeenAt: now, updatedAt: now });
      return existing._id;
    }
    return await ctx.db.insert("devices", { ...args, lastSeenAt: now, updatedAt: now });
  },
});

export const list = userQuery({
  args: {},
  returns: v.array(vDeviceDoc),
  handler: async (ctx) => await ctx.db.query("devices").collect(),
});

export const pushTargets = internalQuery({
  args: {},
  returns: v.array(v.object({ token: v.string(), environment: v.optional(v.union(v.literal("sandbox"), v.literal("production"))) })),
  handler: async (ctx) => {
    const devices = await ctx.db.query("devices").collect();
    return devices.flatMap((d) => (d.apnsToken ? [{ token: d.apnsToken, environment: d.apnsEnvironment }] : []));
  },
});

/** APNs said the token is dead (410 / BadDeviceToken). */
export const dropToken = internalMutation({
  args: { token: v.string() },
  returns: v.null(),
  handler: async (ctx, { token }) => {
    const holders = await ctx.db
      .query("devices")
      .withIndex("by_apnsToken", (q) => q.eq("apnsToken", token))
      .collect();
    for (const h of holders) await ctx.db.patch(h._id, { apnsToken: undefined, updatedAt: Date.now() });
    return null;
  },
});

export const alertForEpisode = internalQuery({
  args: { episodeId: v.id("episodes") },
  returns: v.union(v.null(), v.object({ title: v.string(), body: v.string(), podcastId: v.id("podcasts") })),
  handler: async (ctx, { episodeId }) => {
    const episode = await ctx.db.get(episodeId);
    const podcast = episode && (await ctx.db.get(episode.podcastId));
    if (!episode || !podcast) return null;
    return { title: podcast.title, body: episode.title, podcastId: podcast._id };
  },
});
