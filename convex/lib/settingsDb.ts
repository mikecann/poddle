import type { Id } from "../_generated/dataModel";
import type { UserQueryCtx } from "./auth";
import { resolveGlobalSettings, resolveShowSettings, showSettingKeys, type ShowOverrides } from "./settings";

export async function globalSettingsDoc(ctx: UserQueryCtx) {
  return await ctx.db
    .query("globalSettings")
    .withIndex("by_user_updatedAt", (q) => q.eq("userId", ctx.userId))
    .first();
}

export async function podcastSettingsDoc(ctx: UserQueryCtx, podcastId: Id<"podcasts">) {
  return await ctx.db
    .query("podcastSettings")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId).eq("podcastId", podcastId))
    .unique();
}

export function overridesOf(doc: Record<string, unknown> | null): ShowOverrides {
  const out: Record<string, unknown> = {};
  if (!doc) return out;
  for (const k of showSettingKeys) if (doc[k] !== undefined) out[k] = doc[k];
  return out as ShowOverrides;
}

export async function resolvedSettingsFor(ctx: UserQueryCtx, podcastId: Id<"podcasts">) {
  const [g, p] = await Promise.all([globalSettingsDoc(ctx), podcastSettingsDoc(ctx, podcastId)]);
  return resolveShowSettings(resolveGlobalSettings(g), overridesOf(p));
}
