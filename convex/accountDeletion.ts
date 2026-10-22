import { v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { feedStateFor } from "./feeds";
import { hasSubscribers } from "./lib/library";

// Deleting an account (users:deleteAccount). The person is signed out at once
// (their user row becomes a tombstone, see lib/identity.ts), and their rows go
// here, in the background: a few hundred per step, each step scheduling the
// next. Progress lives in `accountDeletions`, so an interrupted run picks up
// where it left off (`resumeStalled`, hourly), and running a step twice only
// finds less to delete. Shared catalogue data (shows, episodes, notes) stays.

/** Rows deleted per step. Small rows, so well inside a mutation's limits. */
export const BATCH = 500;
/** Steps that haven't run for this long are restarted by the cron. */
export const STALL_MS = 10 * 60_000;
/** Extra passes allowed when rows turn up behind the sweep (a feed fanning out mid-delete). */
const MAX_PASSES = 5;

type Ctx = MutationCtx;
type UserId = Id<"users">;
/** Deletes up to `budget` of the person's rows in one stage. Returns how many it deleted. */
type Sweep = (ctx: Ctx, userId: UserId, budget: number) => Promise<number>;

/**
 * Every personal table, by an index that starts with `userId`. Keep this in
 * step with schema.ts: tests/accountDeletion.test.ts checks that every table
 * with a `userId` field is here.
 */
export const PERSONAL_INDEX = {
  subscriptions: "by_user_podcast",
  queueItems: "by_user_orderKey",
  episodeStates: "by_user_episode",
  podcastSettings: "by_user_podcast",
  globalSettings: "by_user_updatedAt",
  listeningSessions: "by_user_sessionId",
  libraryEvents: "by_user_eventId",
  devices: "by_user_updatedAt",
  deletions: "by_user_updatedAt",
  statsDays: "by_user_day",
  statsMonths: "by_user_month",
  statsShowDays: "by_user_day_podcast",
  statsShowMonths: "by_user_month_podcast",
  episodeTotals: "by_user_episode",
  importBatches: "by_user_startedAt",
} as const;
type PersonalTable = keyof typeof PERSONAL_INDEX;

/** The first `n` of someone's rows in a personal table. */
async function firstRows(ctx: QueryCtx, table: PersonalTable, userId: UserId, n: number): Promise<Doc<PersonalTable>[]> {
  // The index name and its leading `userId` field come from PERSONAL_INDEX, which
  // Convex's types can't check through a table-name variable.
  const query = ctx.db.query(table) as unknown as {
    withIndex(index: string, range: (q: { eq(field: "userId", value: UserId): unknown }) => unknown): {
      take(n: number): Promise<Doc<PersonalTable>[]>;
    };
  };
  return await query.withIndex(PERSONAL_INDEX[table], (q) => q.eq("userId", userId)).take(n);
}

/** Deletes up to `budget` of their rows in `table`. */
const plain = (table: PersonalTable): Sweep => async (ctx, userId, budget) => {
  const rows = await firstRows(ctx, table, userId, budget);
  for (const row of rows) await ctx.db.delete(row._id);
  return rows.length;
};

/**
 * The stages, in order. Subscriptions go first, so feed fan-out stops adding
 * rows for them; Chef's rows live in its component.
 */
const SWEEPS: Record<PersonalTable | "chefRequests", Sweep> = {
  subscriptions: async (ctx, userId, budget) => {
    const rows = await ctx.db
      .query("subscriptions")
      .withIndex("by_user_podcast", (q) => q.eq("userId", userId))
      .take(budget);
    for (const row of rows) {
      await ctx.db.delete(row._id);
      // Nobody else subscribes: stop polling the feed.
      if (row.subscribed && !(await hasSubscribers(ctx, row.podcastId))) {
        const state = await feedStateFor(ctx, row.podcastId);
        if (state?.active) await ctx.db.patch(state._id, { active: false });
      }
    }
    return rows.length;
  },
  queueItems: plain("queueItems"),
  episodeStates: plain("episodeStates"),
  podcastSettings: plain("podcastSettings"),
  globalSettings: plain("globalSettings"),
  listeningSessions: plain("listeningSessions"),
  libraryEvents: plain("libraryEvents"),
  devices: plain("devices"),
  deletions: plain("deletions"),
  statsDays: plain("statsDays"),
  statsMonths: plain("statsMonths"),
  statsShowDays: plain("statsShowDays"),
  statsShowMonths: plain("statsShowMonths"),
  episodeTotals: plain("episodeTotals"),
  // Each import batch's scratch rows (keyed by batch, not person) go before it.
  importBatches: async (ctx, userId, budget) => {
    let deleted = 0;
    while (deleted < budget) {
      const batch = await ctx.db
        .query("importBatches")
        .withIndex("by_user_startedAt", (q) => q.eq("userId", userId))
        .first();
      if (!batch) break;
      const left = budget - deleted;
      const scratch: { _id: Id<"importItems"> | Id<"importQueue"> | Id<"importUpNext"> }[] = await ctx.db
        .query("importItems")
        .withIndex("by_batch_podcast", (q) => q.eq("batchId", batch._id))
        .take(left);
      if (scratch.length < left) {
        scratch.push(
          ...(await ctx.db.query("importQueue").withIndex("by_batch_phase", (q) => q.eq("batchId", batch._id)).take(left - scratch.length)),
        );
      }
      if (scratch.length < left) {
        scratch.push(
          ...(await ctx.db.query("importUpNext").withIndex("by_batch", (q) => q.eq("batchId", batch._id)).take(left - scratch.length)),
        );
      }
      for (const row of scratch) await ctx.db.delete(row._id);
      deleted += scratch.length;
      if (deleted >= budget) break;
      // An import step that finds its batch gone stops (overcastImport.ts).
      await ctx.db.delete(batch._id);
      deleted++;
    }
    return deleted;
  },
  // Chef: their feature requests, with screenshots, voice notes, votes on
  // them, the dev log and notifications (the feedback component's items.remove).
  // Counts requests, not their rows; each one is a handful.
  chefRequests: async (ctx, userId, budget) => {
    let deleted = 0;
    while (deleted < budget) {
      const items = await ctx.runQuery(components.feedback.items.listByCreator, {
        userId,
        limit: Math.min(20, budget - deleted),
      });
      if (items.length === 0) break;
      for (const item of items) await ctx.runMutation(components.feedback.items.remove, { itemId: item._id });
      deleted += items.length;
    }
    return deleted;
  },
};

/** The order the stages run in. */
export const STAGES = Object.keys(SWEEPS) as (keyof typeof SWEEPS)[];

/**
 * Starts (or restarts) deleting someone's data. Idempotent: an unfinished
 * deletion is picked up again rather than started twice.
 */
export async function startDeletion(ctx: Ctx, userId: UserId): Promise<Id<"accountDeletions">> {
  const now = Date.now();
  const existing = await ctx.db
    .query("accountDeletions")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .order("desc")
    .first();
  if (existing && existing.finishedAt === undefined) {
    await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId: existing._id });
    return existing._id;
  }
  const deletionId = await ctx.db.insert("accountDeletions", {
    userId,
    requestedAt: now,
    stage: STAGES[0]!,
    passes: 0,
    deletedRows: 0,
    lastStepAt: now,
  });
  await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId });
  return deletionId;
}

/** Whether anything of theirs is left, in any stage. */
async function anythingLeft(ctx: Ctx, userId: UserId): Promise<boolean> {
  for (const table of Object.keys(PERSONAL_INDEX) as PersonalTable[]) {
    if ((await firstRows(ctx, table, userId, 1)).length > 0) return true;
  }
  const chef = await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: 1 });
  return chef.length > 0;
}

/** One step: up to BATCH rows, across as many stages as that reaches, then the next step. */
export const step = internalMutation({
  args: { deletionId: v.id("accountDeletions") },
  returns: v.null(),
  handler: async (ctx, { deletionId }) => {
    const deletion = await ctx.db.get(deletionId);
    if (!deletion || deletion.finishedAt !== undefined) return null;
    const { userId } = deletion;
    let stageIndex = Math.max(0, STAGES.indexOf(deletion.stage as (typeof STAGES)[number]));
    let budget = BATCH;
    let deleted = 0;
    while (budget > 0 && stageIndex < STAGES.length) {
      const n = await SWEEPS[STAGES[stageIndex]!](ctx, userId, budget);
      deleted += n;
      budget -= n;
      // Fewer than asked for: this stage is empty.
      if (budget > 0) stageIndex++;
    }
    const now = Date.now();
    const progress = { deletedRows: deletion.deletedRows + deleted, lastStepAt: now };
    if (stageIndex < STAGES.length) {
      await ctx.db.patch(deletionId, { ...progress, stage: STAGES[stageIndex]! });
      await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId });
      return null;
    }
    // Every stage came up empty. Something written behind the sweep (a feed
    // fan-out that was already running) gets another pass.
    if (deletion.passes + 1 < MAX_PASSES && (await anythingLeft(ctx, userId))) {
      await ctx.db.patch(deletionId, { ...progress, stage: STAGES[0]!, passes: deletion.passes + 1 });
      await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId });
      return null;
    }
    await ctx.db.patch(deletionId, { ...progress, stage: "done", passes: deletion.passes + 1, finishedAt: now });
    console.log(`Account deletion ${deletionId} finished: ${progress.deletedRows} rows`);
    return null;
  },
});

/** Cron, hourly: restarts deletions whose chain of steps stopped (a deploy, an error). */
export const resumeStalled = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const stalled = await ctx.db
      .query("accountDeletions")
      .withIndex("by_finishedAt_lastStepAt", (q) => q.eq("finishedAt", undefined).lt("lastStepAt", Date.now() - STALL_MS))
      .take(50);
    for (const d of stalled) {
      await ctx.db.patch(d._id, { lastStepAt: Date.now() });
      await ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId: d._id });
    }
    return stalled.length;
  },
});

/** Whether this person's data is still being deleted (they can't sign back in until it's done). */
export async function deletionInProgress(ctx: Ctx, userId: UserId): Promise<boolean> {
  const latest = await ctx.db
    .query("accountDeletions")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .order("desc")
    .first();
  return latest !== null && latest.finishedAt === undefined;
}

/**
 * How many rows someone has left in each personal table (capped at 1000 each),
 * plus their Chef requests and latest deletion, for checking a deletion by hand:
 * `npx convex run accountDeletion:remaining '{"userId":"…"}'`.
 */
export const remaining = internalQuery({
  args: { userId: v.id("users") },
  returns: v.object({
    counts: v.record(v.string(), v.number()),
    deletion: v.union(v.null(), v.object({ stage: v.string(), deletedRows: v.number(), finished: v.boolean() })),
  }),
  handler: async (ctx, { userId }) => {
    const counts: Record<string, number> = {};
    for (const table of Object.keys(PERSONAL_INDEX) as PersonalTable[]) {
      counts[table] = (await firstRows(ctx, table, userId, 1000)).length;
    }
    counts.chefRequests = (await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: 100 })).length;
    const latest = await ctx.db
      .query("accountDeletions")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .order("desc")
      .first();
    return {
      counts,
      deletion: latest && { stage: latest.stage, deletedRows: latest.deletedRows, finished: latest.finishedAt !== undefined },
    };
  },
});
