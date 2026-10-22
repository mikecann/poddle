import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import { userMutation, userQuery } from "./lib/auth";
import { vDeviceDoc } from "./lib/validators";

// Devices and their APNs tokens. `deviceId` is a stable UUID the app keeps in the
// Keychain. A device belongs to whoever signed in on it last, so pushes for one
// person never reach a phone someone else has since signed in on.

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
    // A token belongs to one device; drop it from any other row, whoever's it is.
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
      .collect();
    const mine = existing.find((d) => d.userId === ctx.userId);
    // Signed in as someone else on this device: the old rows stop getting pushes.
    for (const d of existing) {
      if (d !== mine && d.apnsToken) await ctx.db.patch(d._id, { apnsToken: undefined, updatedAt: now });
    }
    if (mine) {
      await ctx.db.patch(mine._id, { ...args, lastSeenAt: now, updatedAt: now });
      return mine._id;
    }
    return await ctx.db.insert("devices", { ...args, userId: ctx.userId, lastSeenAt: now, updatedAt: now });
  },
});

export const list = userQuery({
  args: {},
  returns: v.array(vDeviceDoc),
  handler: async (ctx) =>
    await ctx.db
      .query("devices")
      .withIndex("by_user_updatedAt", (q) => q.eq("userId", ctx.userId))
      .collect(),
});

/** One person's devices with a push token. */
export const pushTargets = internalQuery({
  args: { userId: v.id("users") },
  returns: v.array(v.object({ token: v.string(), environment: v.optional(v.union(v.literal("sandbox"), v.literal("production"))) })),
  handler: async (ctx, { userId }) => {
    const devices = await ctx.db
      .query("devices")
      .withIndex("by_user_updatedAt", (q) => q.eq("userId", userId))
      .collect();
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
