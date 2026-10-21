import type { Id } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";
import { resolveGlobalSettings, resolveShowSettings, showSettingKeys, type ShowOverrides } from "./settings";

export async function globalSettingsDoc(ctx: QueryCtx) {
  return await ctx.db.query("globalSettings").first();
}

export async function podcastSettingsDoc(ctx: QueryCtx, podcastId: Id<"podcasts">) {
  return await ctx.db
    .query("podcastSettings")
    .withIndex("by_podcast", (q) => q.eq("podcastId", podcastId))
    .unique();
}

export function overridesOf(doc: Record<string, unknown> | null): ShowOverrides {
  const out: Record<string, unknown> = {};
  if (!doc) return out;
  for (const k of showSettingKeys) if (doc[k] !== undefined) out[k] = doc[k];
  return out as ShowOverrides;
}

export async function resolvedSettingsFor(ctx: QueryCtx, podcastId: Id<"podcasts">) {
  const [g, p] = await Promise.all([globalSettingsDoc(ctx), podcastSettingsDoc(ctx, podcastId)]);
  return resolveShowSettings(resolveGlobalSettings(g), overridesOf(p));
}
