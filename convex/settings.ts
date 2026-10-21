import { v } from "convex/values";
import { userMutation, userQuery } from "./lib/auth";
import {
  globalSettingFields,
  globalSettingsPatch,
  podcastSettingsPatch,
  resolveGlobalSettings,
  resolveShowSettings,
  showSettingFields,
} from "./lib/settings";
import { globalSettingsDoc, overridesOf, podcastSettingsDoc } from "./lib/settingsDb";

// Global defaults plus per-show overrides (spec §2.5). Writes are
// last-writer-wins per field on the client time `at`.

const vResolvedShow = v.object({ ...showSettingFields, inherited: v.array(v.string()) });
const vOverrides = v.object(Object.fromEntries(Object.entries(showSettingFields).map(([k, val]) => [k, v.optional(val)])));

/** Every global setting, with defaults filled in. */
export const getGlobal = userQuery({
  args: {},
  returns: v.object(globalSettingFields),
  handler: async (ctx) => resolveGlobalSettings(await globalSettingsDoc(ctx)),
});

/** A show's explicit overrides (absent = use default) and the effective values. */
export const forPodcast = userQuery({
  args: { podcastId: v.id("podcasts") },
  returns: v.object({ overrides: vOverrides, resolved: vResolvedShow }),
  handler: async (ctx, { podcastId }) => {
    const overrides = overridesOf(await podcastSettingsDoc(ctx, podcastId));
    return { overrides, resolved: resolveShowSettings(resolveGlobalSettings(await globalSettingsDoc(ctx)), overrides) };
  },
});

/** Effective settings for a show: `override ?? global`, resolved now. */
export const resolved = userQuery({
  args: { podcastId: v.id("podcasts") },
  returns: vResolvedShow,
  handler: async (ctx, { podcastId }) => {
    const overrides = overridesOf(await podcastSettingsDoc(ctx, podcastId));
    return resolveShowSettings(resolveGlobalSettings(await globalSettingsDoc(ctx)), overrides);
  },
});

/** Keep only fields whose `at` beats the stored per-field time. */
function lwwPatch(patch: Record<string, unknown>, fieldTimes: Record<string, number>, at: number) {
  const values: Record<string, unknown> = {};
  const times = { ...fieldTimes };
  for (const [k, val] of Object.entries(patch)) {
    if (val === undefined || at < (fieldTimes[k] ?? 0)) continue;
    // null means "use default": store as absent.
    values[k] = val === null ? undefined : val;
    times[k] = at;
  }
  return { values, times, applied: Object.keys(values) };
}

/** Change global defaults. Only the fields given are touched. Returns the fields applied. */
export const updateGlobal = userMutation({
  args: { patch: globalSettingsPatch, at: v.number() },
  returns: v.array(v.string()),
  handler: async (ctx, { patch, at }) => {
    const existing = await globalSettingsDoc(ctx);
    const { values, times, applied } = lwwPatch(patch, existing?.fieldTimes ?? {}, at);
    const now = Date.now();
    if (existing) await ctx.db.patch(existing._id, { ...values, fieldTimes: times, updatedAt: now });
    else await ctx.db.insert("globalSettings", { ...stripUndefined(values), fieldTimes: times, updatedAt: now });
    return applied;
  },
});

/** Change a show's overrides. A value sets it; null resets it to "use default". */
export const updatePodcast = userMutation({
  args: { podcastId: v.id("podcasts"), patch: podcastSettingsPatch, at: v.number() },
  returns: v.array(v.string()),
  handler: async (ctx, { podcastId, patch, at }) => {
    const existing = await podcastSettingsDoc(ctx, podcastId);
    const { values, times, applied } = lwwPatch(patch, existing?.fieldTimes ?? {}, at);
    const now = Date.now();
    if (existing) await ctx.db.patch(existing._id, { ...values, fieldTimes: times, updatedAt: now });
    else await ctx.db.insert("podcastSettings", { podcastId, ...stripUndefined(values), fieldTimes: times, updatedAt: now });
    return applied;
  },
});

function stripUndefined(o: Record<string, unknown>) {
  return Object.fromEntries(Object.entries(o).filter(([, val]) => val !== undefined));
}
