import { v, type Infer } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { userMutation, type UserMutationCtx as MutationCtx } from "./lib/auth";
import { ensureLibraryRow } from "./lib/library";
import { applySessionToRollups } from "./lib/rollups";
import { userUtcOffset } from "./lib/state";

// Listening sessions (spec §2.9): an append-only log keyed by client UUID.
// The app re-sends an open session every 30 s with the same id and a later end;
// that replaces the stored copy and its rollup contribution. Resending an
// identical or older copy is a no-op, so the outbox can replay freely.

export const vSessionInput = v.object({
  sessionId: v.string(),
  episodeId: v.id("episodes"),
  deviceId: v.optional(v.string()),
  startedAt: v.number(),
  endedAt: v.number(),
  contentStart: v.number(),
  contentEnd: v.number(),
  rate: v.number(),
  smartSpeed: v.boolean(),
  smartRemovedContent: v.number(),
  voiceBoost: v.boolean(),
  route: v.optional(v.string()),
  /** Device's UTC offset when the session started. Defaults to the global time zone. */
  utcOffsetMinutes: v.optional(v.number()),
});
export type SessionInput = Infer<typeof vSessionInput>;

type Stored = Omit<Doc<"listeningSessions">, "_id" | "_creationTime" | "userId">;

/** Insert or replace a session by id, keeping the stats rollups in step. */
export async function upsertSession(ctx: MutationCtx, s: Stored): Promise<"inserted" | "updated" | "unchanged"> {
  const existing = await ctx.db
    .query("listeningSessions")
    .withIndex("by_user_sessionId", (q) => q.eq("userId", ctx.userId).eq("sessionId", s.sessionId))
    .unique();
  const stored = { ...s, userId: ctx.userId };
  if (existing) {
    const same =
      existing.endedAt === s.endedAt &&
      existing.contentEnd === s.contentEnd &&
      existing.startedAt === s.startedAt &&
      existing.contentStart === s.contentStart &&
      existing.smartRemovedContent === s.smartRemovedContent &&
      existing.rate === s.rate;
    // An older snapshot of a session we already have (out-of-order replay).
    if (same || s.endedAt < existing.endedAt) return "unchanged";
    await applySessionToRollups(ctx, existing, -1);
    await ctx.db.replace(existing._id, stored);
    await applySessionToRollups(ctx, s, 1);
    return "updated";
  }
  await ensureLibraryRow(ctx, s.podcastId);
  await ctx.db.insert("listeningSessions", stored);
  await applySessionToRollups(ctx, s, 1);
  return "inserted";
}

/** Append (or extend) listening sessions. Returns how many were new or changed. */
export const record = userMutation({
  args: { sessions: v.array(vSessionInput) },
  returns: v.object({ inserted: v.number(), updated: v.number(), unchanged: v.number() }),
  handler: async (ctx, { sessions }) => {
    const counts = { inserted: 0, updated: 0, unchanged: 0 };
    const shows = new Map<Id<"episodes">, Id<"podcasts">>();
    for (const input of sessions) {
      let podcastId = shows.get(input.episodeId);
      if (!podcastId) {
        const episode = await ctx.db.get(input.episodeId);
        if (!episode) throw new Error(`Episode ${input.episodeId} not found`);
        podcastId = episode.podcastId;
        shows.set(input.episodeId, podcastId);
      }
      const { utcOffsetMinutes, ...rest } = input;
      const result = await upsertSession(ctx, {
        ...rest,
        endedAt: Math.max(input.endedAt, input.startedAt),
        podcastId,
        source: "live",
        isEstimated: false,
        utcOffsetMinutes: utcOffsetMinutes ?? (await userUtcOffset(ctx, input.startedAt)),
        updatedAt: Date.now(),
      });
      counts[result]++;
    }
    return counts;
  },
});
