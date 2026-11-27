import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id, TableNames } from "./_generated/dataModel";
import { internalAction, internalMutation, internalQuery, type MutationCtx } from "./_generated/server";
import { asUser, type UserMutationCtx, type UserQueryCtx } from "./lib/auth";
import { userByEmail } from "./lib/identity";
import { addToQueue, orderedQueue, queueItemFor } from "./lib/queue";
import { resolveGlobalSettings } from "./lib/settings";
import { globalSettingsDoc } from "./lib/settingsDb";
import { systemAt } from "./lib/state";
import { dayToUtcMs, localDay, longestStreak, sessionMetrics } from "./lib/statsMath";
import { asMutationCtx, importBatch, machines } from "./machines";

// The accounts migration (docs/runbooks/accounts-prod.md). Everything that
// existed before accounts is Mike's, so this makes his user and gives it every
// personal row, and moves the old per-show subscription fields off the shared
// `podcasts` rows into his `subscriptions`. Safe to run again: it only touches
// rows that still have no owner, and a show that already has his subscription.
//
//   npx convex run migrations:report            counts, before and after
//   npx convex run migrations:run               starts it (runs in the background)
//
// When he first signs in with Apple or Google using this (verified) email, he
// lands in this user (users.ts, existingUser).

export const OWNER_EMAIL = "mike.cann@gmail.com";

export const PERSONAL_TABLES = [
  "episodeStates",
  "queueItems",
  "deletions",
  "podcastSettings",
  "globalSettings",
  "listeningSessions",
  "libraryEvents",
  "devices",
  "importBatches",
  "statsDays",
  "statsMonths",
  "statsShowDays",
  "statsShowMonths",
  "episodeTotals",
] as const satisfies TableNames[];
type PersonalTable = (typeof PERSONAL_TABLES)[number];
const vPersonalTable = v.union(...PERSONAL_TABLES.map((t) => v.literal(t)));

const BATCH = 400;

/** Mike's user, made if it isn't there yet. */
export const ensureOwner = internalMutation({
  args: { email: v.optional(v.string()) },
  returns: v.id("users"),
  handler: async (ctx, { email = OWNER_EMAIL }) => {
    const existing = await userByEmail(ctx, email);
    if (existing) {
      if (!existing.emailVerified) await ctx.db.patch("users", existing._id, { emailVerified: true });
      return existing._id;
    }
    return await ctx.db.insert("users", { email: email.trim().toLowerCase(), emailVerified: true, name: "Mike Cann" });
  },
});

/** Kicks off the whole migration in the background. */
export const run = internalMutation({
  args: { email: v.optional(v.string()) },
  returns: v.id("users"),
  handler: async (ctx, { email }): Promise<Id<"users">> => {
    const ownerId: Id<"users"> = await ctx.runMutation(internal.migrations.ensureOwner, { email });
    await ctx.scheduler.runAfter(0, internal.migrations.moveSubscriptions, { ownerId, cursor: null });
    for (const table of PERSONAL_TABLES) {
      await ctx.scheduler.runAfter(0, internal.migrations.assignOwner, { table, ownerId, cursor: null });
    }
    return ownerId;
  },
});

/** One page of a personal table: rows with no owner get Mike. */
export const assignOwner = internalMutation({
  args: { table: vPersonalTable, ownerId: v.id("users"), cursor: v.union(v.string(), v.null()) },
  returns: v.object({ patched: v.number(), isDone: v.boolean() }),
  handler: async (ctx, { table, ownerId, cursor }) => {
    const page = await ctx.db.query(table as PersonalTable).paginate({ cursor, numItems: BATCH });
    let patched = 0;
    for (const row of page.page) {
      if (row.userId !== undefined) continue;
      await ctx.db.patch(row._id, { userId: ownerId });
      patched++;
    }
    if (!page.isDone) {
      await ctx.scheduler.runAfter(0, internal.migrations.assignOwner, { table, ownerId, cursor: page.continueCursor });
    }
    return { patched, isDone: page.isDone };
  },
});

/**
 * One page of shows: each becomes a `subscriptions` row of Mike's, carrying
 * over subscribed, the dates, the LWW clock and the private switch, and the old
 * fields are cleared off the shared row. Every show that exists so far came from
 * his subscribes and imports, so every one is in his library.
 */
export const moveSubscriptions = internalMutation({
  args: { ownerId: v.id("users"), cursor: v.union(v.string(), v.null()) },
  returns: v.object({ created: v.number(), cleared: v.number(), isDone: v.boolean() }),
  handler: async (ctx, { ownerId, cursor }) => {
    const page = await ctx.db.query("podcasts").paginate({ cursor, numItems: BATCH });
    const now = Date.now();
    let created = 0;
    let cleared = 0;
    for (const p of page.page) {
      const existing = await ctx.db
        .query("subscriptions")
        .withIndex("by_user_podcast", (q) => q.eq("userId", ownerId).eq("podcastId", p._id))
        .unique();
      if (!existing) {
        await ctx.db.insert("subscriptions", {
          userId: ownerId,
          podcastId: p._id,
          subscribed: p.subscribed ?? false,
          subscribedAt: p.subscribedAt,
          unsubscribedAt: p.unsubscribedAt,
          subscriptionUpdatedAt: p.subscriptionUpdatedAt ?? 0,
          isPrivate: p.isPrivate,
          addedAt: now,
          updatedAt: now,
        });
        created++;
      }
      if (p.subscribed !== undefined || p.subscribedAt !== undefined || p.unsubscribedAt !== undefined || p.subscriptionUpdatedAt !== undefined) {
        await ctx.db.patch("podcasts", p._id, { subscribed: undefined, subscribedAt: undefined, unsubscribedAt: undefined, subscriptionUpdatedAt: undefined });
        cleared++;
      }
    }
    if (!page.isDone) {
      await ctx.scheduler.runAfter(0, internal.migrations.moveSubscriptions, { ownerId, cursor: page.continueCursor });
    }
    return { created, cleared, isDone: page.isDone };
  },
});

const vCountTable = v.union(vPersonalTable, v.literal("podcasts"), v.literal("subscriptions"), v.literal("users"));

/** Counts for one page of a table, for `report`. */
export const countPage = internalQuery({
  args: { table: vCountTable, cursor: v.union(v.string(), v.null()) },
  returns: v.object({ total: v.number(), unowned: v.number(), legacy: v.number(), isDone: v.boolean(), cursor: v.string() }),
  handler: async (ctx, { table, cursor }) => {
    const page = await ctx.db.query(table).paginate({ cursor, numItems: 4000 });
    let unowned = 0;
    let legacy = 0;
    for (const row of page.page as Record<string, unknown>[]) {
      if (table === "podcasts") {
        if (row.subscribed !== undefined || row.subscriptionUpdatedAt !== undefined) legacy++;
      } else if (table !== "users" && row.userId === undefined) unowned++;
    }
    return { total: page.page.length, unowned, legacy, isDone: page.isDone, cursor: page.continueCursor };
  },
});

/**
 * Row counts per table: `total`, rows still without an owner (`unowned`), and
 * shows still carrying the old subscription fields (`legacy`). All zeros in
 * `unowned` and `legacy` means the migration is done.
 */
export const report = internalAction({
  args: {},
  returns: v.record(v.string(), v.object({ total: v.number(), unowned: v.number(), legacy: v.number() })),
  handler: async (ctx) => {
    const out: Record<string, { total: number; unowned: number; legacy: number }> = {};
    for (const table of ["users", "podcasts", "subscriptions", ...PERSONAL_TABLES] as const) {
      const sum = { total: 0, unowned: 0, legacy: 0 };
      let cursor: string | null = null;
      for (;;) {
        const r: { total: number; unowned: number; legacy: number; isDone: boolean; cursor: string } = await ctx.runQuery(
          internal.migrations.countPage,
          { table, cursor },
        );
        sum.total += r.total;
        sum.unowned += r.unowned;
        sum.legacy += r.legacy;
        if (r.isDone) break;
        cursor = r.cursor;
      }
      out[table] = sum;
    }
    return out;
  },
});

// ---- Retiring the Inbox (decisions.md, 22 Oct 2026; runbook step 3b) ----
//
// There's no Inbox any more. For each person, every episode still in their Inbox
// that isn't archived, played or already queued goes to the bottom of their Up
// Next, oldest `pubDate` first, and leaves the Inbox. Stored `inbox` rules become
// `upNextBottom`; a show override that then matches the global rule is cleared
// back to "use default". Safe to run again: a second run finds nothing to do.
//
//   npx convex run migrations:inboxReport       counts, before and after
//   npx convex run migrations:retireInbox       starts it (runs in the background)

const INBOX_BATCH = 200;

/** Kicks off `retireInboxFor` for everyone. Returns how many people. */
export const retireInbox = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    let n = 0;
    for (const user of await ctx.db.query("users").collect()) {
      if (user.mergedInto) continue;
      await ctx.scheduler.runAfter(0, internal.migrations.retireInboxFor, { userId: user._id });
      n++;
    }
    return n;
  },
});

/**
 * One person, one batch: rewrites their `inbox` rules, then moves their oldest
 * `INBOX_BATCH` Inbox episodes to the bottom of Up Next through the same queue
 * helper the app's mutations use (fractional keys, `updatedAt`, LWW), and takes
 * them out of the Inbox. Schedules itself again until the Inbox is empty.
 */
export const retireInboxFor = internalMutation({
  args: { userId: v.id("users") },
  returns: v.object({
    moved: v.number(),
    cleared: v.number(),
    globalRewritten: v.boolean(),
    overridesRewritten: v.number(),
    overridesCleared: v.number(),
    isDone: v.boolean(),
  }),
  handler: async (rawCtx, { userId }) => {
    const ctx = asUser(rawCtx, userId);
    const now = Date.now();
    const rules = await retireInboxRules(ctx, now);

    const states = await inboxStates(ctx);
    const entries = [];
    for (const state of states) entries.push({ state, episode: await ctx.db.get("episodes", state.episodeId) });
    // Oldest first, so the oldest ends up highest in Up Next. Each batch goes
    // after the last, and the next batch is the oldest of what's left.
    entries.sort(
      (a, b) =>
        (a.episode?.pubDate ?? a.state.inboxAt ?? 0) - (b.episode?.pubDate ?? b.state.inboxAt ?? 0) ||
        a.state._creationTime - b.state._creationTime,
    );

    const at = systemAt(now);
    let moved = 0;
    const batch = entries.slice(0, INBOX_BATCH);
    for (const { state, episode } of batch) {
      if (episode && !state.archived && !state.played && !(await queueItemFor(ctx, episode._id))) {
        if (await addToQueue(ctx, episode, "bottom", at, "auto")) moved++;
      }
      await ctx.db.patch("episodeStates", state._id, {
        inInbox: false,
        inboxAt: undefined,
        inboxUpdatedAt: Math.max(state.inboxUpdatedAt, at),
        updatedAt: Date.now(),
      });
    }
    const isDone = entries.length <= INBOX_BATCH;
    if (!isDone) await ctx.scheduler.runAfter(0, internal.migrations.retireInboxFor, { userId });
    return { moved, cleared: batch.length, ...rules, isDone };
  },
});

async function inboxStates(ctx: UserQueryCtx) {
  return await ctx.db
    .query("episodeStates")
    .withIndex("by_user_inbox", (q) => q.eq("userId", ctx.userId).eq("inInbox", true))
    .collect();
}

/** `inbox` rules become `upNextBottom`; overrides that then match the global rule go back to "use default". */
async function retireInboxRules(ctx: UserMutationCtx, now: number) {
  let globalRewritten = false;
  let overridesRewritten = 0;
  let overridesCleared = 0;
  const global = await globalSettingsDoc(ctx);
  if (global?.newEpisodes === "inbox") {
    await ctx.db.patch("globalSettings", global._id, { newEpisodes: "upNextBottom", updatedAt: now });
    globalRewritten = true;
  }
  const globalRule = resolveGlobalSettings(global).newEpisodes;
  const shows = await ctx.db
    .query("podcastSettings")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId))
    .collect();
  for (const show of shows) {
    if (show.newEpisodes !== "inbox") continue;
    if (globalRule === "upNextBottom") {
      await ctx.db.patch("podcastSettings", show._id, { newEpisodes: undefined, updatedAt: now });
      overridesCleared++;
    } else {
      await ctx.db.patch("podcastSettings", show._id, { newEpisodes: "upNextBottom", updatedAt: now });
      overridesRewritten++;
    }
  }
  return { globalRewritten, overridesRewritten, overridesCleared };
}

/**
 * Per person: what's in the Inbox (`inbox`), how much of it the migration would
 * move (`toMove`: not archived, played or queued), Up Next's length, and stored
 * `inbox` rules (global and per show). Done means zeros in all but `upNext`.
 */
export const inboxReport = internalQuery({
  args: {},
  returns: v.array(
    v.object({
      userId: v.id("users"),
      email: v.optional(v.string()),
      inbox: v.number(),
      toMove: v.number(),
      upNext: v.number(),
      globalInboxRule: v.boolean(),
      showInboxRules: v.number(),
    }),
  ),
  handler: async (rawCtx) => {
    const out = [];
    for (const user of await rawCtx.db.query("users").collect()) {
      if (user.mergedInto) continue;
      const ctx = asUser(rawCtx, user._id);
      const queue = await orderedQueue(ctx);
      const queued = new Set(queue.map((i) => i.episodeId));
      const inbox = await inboxStates(ctx);
      const shows = await ctx.db
        .query("podcastSettings")
        .withIndex("by_user_podcast", (q) => q.eq("userId", user._id))
        .collect();
      out.push({
        userId: user._id,
        email: user.email,
        inbox: inbox.length,
        toMove: inbox.filter((s) => !s.archived && !s.played && !queued.has(s.episodeId)).length,
        upNext: queue.length,
        globalInboxRule: (await globalSettingsDoc(ctx))?.newEpisodes === "inbox",
        showInboxRules: shows.filter((s) => s.newEpisodes === "inbox").length,
      });
    }
    return out;
  },
});

// ---- State machines: the import's tables ----
//
// The switch put the importBatch machine on importBatches.state, filled by a
// backfill that wrote it directly. A batch it left parsing or fetching has none
// of its state's timers (the 15-minute read deadline, the 5-minute CHECK), so
// this arms them, as if it had just entered that state. Run once after the switch:
//
//   npx convex run migrations:armImportTimers

export const armImportTimers = machines.internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    let armed = 0;
    for (const kind of ["parsing", "fetching"] as const) {
      const rows = await asMutationCtx(ctx).db.query("importBatches").withIndex("by_state", (q) => q.eq("state.kind", kind)).collect();
      for (const row of rows) {
        if (row.stateTimers?.length) continue;
        await importBatch.armTimers(ctx, row._id);
        armed++;
      }
    }
    return armed;
  },
});

// ---- Extended stats rollups backfill (statsEpisodeYears, statsShowTotals, statsAllTime) ----
//
// Populates per-year episode totals, all-time show totals and longest-streak summary so
// `stats:summary` stops scanning raw listeningSessions / statsShowMonths / statsDays.
// Safe to run again: clears and rebuilds each user's extended rollups, with the latest year,
// show totals and `rollupsReady: true` committed atomically in the final mutation.
//
//   npx convex run migrations:backfillStatsRollups

const ROLLUP_PAD_MS = 14 * 3600_000;
const ROLLUP_CLEAR_BATCH = 500;
const ROLLUP_SESSION_PAGE = 2000;
const MAX_BACKFILL_ROUNDS = 5;
const clean = (x: number) => (Math.abs(x) < 1e-6 ? 0 : x);

export const statsBackfillTargets = internalQuery({
  args: {},
  returns: v.array(v.id("users")),
  handler: async (ctx) => {
    const out: Id<"users">[] = [];
    for await (const user of ctx.db.query("users")) {
      if (user.mergedInto || user.deletedAt !== undefined) continue;
      out.push(user._id);
    }
    return out;
  },
});

async function isActiveUser(ctx: MutationCtx, userId: Id<"users">): Promise<boolean> {
  const user = await ctx.db.get("users", userId);
  return Boolean(user && !user.mergedInto && user.deletedAt === undefined);
}

export const clearStatsRollupsBatch = internalMutation({
  args: { userId: v.id("users") },
  returns: v.object({
    deleted: v.number(),
    isDone: v.boolean(),
    snapshotMaxUpdatedAt: v.number(),
    years: v.array(v.string()),
  }),
  handler: async (ctx, { userId }) => {
    if (!(await isActiveUser(ctx, userId))) return { deleted: 0, isDone: true, snapshotMaxUpdatedAt: 0, years: [] };
    let deleted = 0;
    // Keep one `rollupsReady: false` marker in place while clearing so concurrent sessions on
    // empty accounts cannot race to insert a second `statsAllTime` row before finalization,
    // and any session written mid-backfill records its touched years in `backfillDirtyYears`.
    const existingAllTime = await ctx.db
      .query("statsAllTime")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .take(10);
    if (existingAllTime.length === 0) {
      await ctx.db.insert("statsAllTime", {
        userId,
        longestStreakLength: 0,
        rollupsReady: false,
      });
    } else {
      const [keep, ...extras] = existingAllTime;
      await ctx.db.patch("statsAllTime", keep!._id, {
        longestStreakLength: 0,
        longestStreakStartDay: undefined,
        longestStreakEndDay: undefined,
        rollupsReady: false,
        backfillDirtyYears: undefined,
      });
      for (const extra of extras) {
        await ctx.db.delete("statsAllTime", extra._id);
        deleted++;
      }
    }
    for (const row of await ctx.db
      .query("statsEpisodeYears")
      .withIndex("by_user_year_episode", (q) => q.eq("userId", userId))
      .take(ROLLUP_CLEAR_BATCH - deleted)) {
      await ctx.db.delete("statsEpisodeYears", row._id);
      deleted++;
    }
    if (deleted < ROLLUP_CLEAR_BATCH) {
      for (const row of await ctx.db
        .query("statsShowTotals")
        .withIndex("by_user_podcast", (q) => q.eq("userId", userId))
        .take(ROLLUP_CLEAR_BATCH - deleted)) {
        await ctx.db.delete("statsShowTotals", row._id);
        deleted++;
      }
    }
    const isDone = deleted < ROLLUP_CLEAR_BATCH;
    if (!isDone) return { deleted, isDone: false, snapshotMaxUpdatedAt: 0, years: [] };

    // Capture the year range and change watermark in the same atomic transaction after clearing.
    const [latest, first, last] = await Promise.all([
      ctx.db
        .query("listeningSessions")
        .withIndex("by_user_updatedAt", (q) => q.eq("userId", userId))
        .order("desc")
        .first(),
      ctx.db
        .query("listeningSessions")
        .withIndex("by_user_startedAt", (q) => q.eq("userId", userId))
        .order("asc")
        .first(),
      ctx.db
        .query("listeningSessions")
        .withIndex("by_user_startedAt", (q) => q.eq("userId", userId))
        .order("desc")
        .first(),
    ]);
    const years: string[] = [];
    if (first && last) {
      // Pad UTC timestamps by ±14 h so timezone shifts around New Year never invert or omit a local year.
      const minY = new Date(first.startedAt - ROLLUP_PAD_MS).getUTCFullYear();
      const maxY = new Date(last.startedAt + ROLLUP_PAD_MS).getUTCFullYear();
      for (let y = minY; y <= maxY; y++) years.push(String(y));
    }
    return { deleted, isDone: true, snapshotMaxUpdatedAt: latest?.updatedAt ?? 0, years };
  },
});

export const clearShowTotalsBatch = internalMutation({
  args: { userId: v.id("users") },
  returns: v.object({ deleted: v.number(), isDone: v.boolean() }),
  handler: async (ctx, { userId }) => {
    if (!(await isActiveUser(ctx, userId))) return { deleted: 0, isDone: true };
    const rows = await ctx.db
      .query("statsShowTotals")
      .withIndex("by_user_podcast", (q) => q.eq("userId", userId))
      .take(ROLLUP_CLEAR_BATCH);
    for (const row of rows) await ctx.db.delete("statsShowTotals", row._id);
    return { deleted: rows.length, isDone: rows.length < ROLLUP_CLEAR_BATCH };
  },
});

export const backfillShowTotalsPage = internalMutation({
  args: { userId: v.id("users"), cursor: v.union(v.string(), v.null()) },
  returns: v.object({ upserted: v.number(), isDone: v.boolean(), continueCursor: v.string() }),
  handler: async (ctx, { userId, cursor }) => {
    if (!(await isActiveUser(ctx, userId))) return { upserted: 0, isDone: true, continueCursor: "" };
    const page = await ctx.db
      .query("statsShowMonths")
      .withIndex("by_user_month_podcast", (q) => q.eq("userId", userId))
      .paginate({ cursor, numItems: ROLLUP_SESSION_PAGE });
    const byShow = new Map<
      Id<"podcasts">,
      { wall: number; content: number; speedSaved: number; smartSaved: number; sessions: number }
    >();
    for (const r of page.page) {
      const acc = byShow.get(r.podcastId) ?? { wall: 0, content: 0, speedSaved: 0, smartSaved: 0, sessions: 0 };
      acc.wall = clean(acc.wall + r.wall);
      acc.content = clean(acc.content + r.content);
      acc.speedSaved = clean(acc.speedSaved + r.speedSaved);
      acc.smartSaved = clean(acc.smartSaved + r.smartSaved);
      acc.sessions += r.sessions;
      byShow.set(r.podcastId, acc);
    }
    for (const [podcastId, acc] of byShow) {
      const existing = await ctx.db
        .query("statsShowTotals")
        .withIndex("by_user_podcast", (q) => q.eq("userId", userId).eq("podcastId", podcastId))
        .unique();
      if (existing) {
        await ctx.db.patch("statsShowTotals", existing._id, {
          wall: clean(existing.wall + acc.wall),
          content: clean(existing.content + acc.content),
          speedSaved: clean(existing.speedSaved + acc.speedSaved),
          smartSaved: clean(existing.smartSaved + acc.smartSaved),
          sessions: existing.sessions + acc.sessions,
        });
      } else {
        await ctx.db.insert("statsShowTotals", { userId, podcastId, ...acc });
      }
    }
    return { upserted: byShow.size, isDone: page.isDone, continueCursor: page.continueCursor };
  },
});

export const clearEpisodeYearBatch = internalMutation({
  args: { userId: v.id("users"), year: v.string() },
  returns: v.object({ deleted: v.number(), isDone: v.boolean() }),
  handler: async (ctx, { userId, year }) => {
    if (!(await isActiveUser(ctx, userId))) return { deleted: 0, isDone: true };
    const rows = await ctx.db
      .query("statsEpisodeYears")
      .withIndex("by_user_year_episode", (q) => q.eq("userId", userId).eq("year", year))
      .take(ROLLUP_CLEAR_BATCH);
    for (const row of rows) await ctx.db.delete("statsEpisodeYears", row._id);
    return { deleted: rows.length, isDone: rows.length < ROLLUP_CLEAR_BATCH };
  },
});

export const backfillEpisodeYearPage = internalMutation({
  args: { userId: v.id("users"), year: v.string(), cursor: v.union(v.string(), v.null()) },
  returns: v.object({ upserted: v.number(), isDone: v.boolean(), continueCursor: v.string() }),
  handler: async (ctx, { userId, year, cursor }) => {
    if (!(await isActiveUser(ctx, userId))) return { upserted: 0, isDone: true, continueCursor: "" };
    const from = dayToUtcMs(`${year}-01-01`) - ROLLUP_PAD_MS;
    const to = dayToUtcMs(`${Number(year) + 1}-01-01`) + ROLLUP_PAD_MS;
    const page = await ctx.db
      .query("listeningSessions")
      .withIndex("by_user_startedAt", (q) => q.eq("userId", userId).gte("startedAt", from).lt("startedAt", to))
      .paginate({ cursor, numItems: ROLLUP_SESSION_PAGE });
    const byEpisode = new Map<Id<"episodes">, { podcastId: Id<"podcasts">; wall: number; content: number; sessions: number }>();
    for (const s of page.page) {
      if (localDay(s.startedAt, s.utcOffsetMinutes).slice(0, 4) !== year) continue;
      const m = sessionMetrics(s);
      const acc = byEpisode.get(s.episodeId) ?? { podcastId: s.podcastId, wall: 0, content: 0, sessions: 0 };
      acc.wall = clean(acc.wall + m.wall);
      acc.content = clean(acc.content + m.content);
      acc.sessions += 1;
      byEpisode.set(s.episodeId, acc);
    }
    for (const [episodeId, acc] of byEpisode) {
      const existing = await ctx.db
        .query("statsEpisodeYears")
        .withIndex("by_user_year_episode", (q) => q.eq("userId", userId).eq("year", year).eq("episodeId", episodeId))
        .unique();
      if (existing) {
        await ctx.db.patch("statsEpisodeYears", existing._id, {
          wall: clean(existing.wall + acc.wall),
          content: clean(existing.content + acc.content),
          sessions: existing.sessions + acc.sessions,
        });
      } else {
        await ctx.db.insert("statsEpisodeYears", { userId, year, episodeId, ...acc });
      }
    }
    return { upserted: byEpisode.size, isDone: page.isDone, continueCursor: page.continueCursor };
  },
});

export const finalizeUserStatsRollups = internalMutation({
  args: { userId: v.id("users"), snapshotMaxUpdatedAt: v.number() },
  returns: v.object({
    committed: v.boolean(),
    dirtyYears: v.array(v.string()),
    nextSnapshotMaxUpdatedAt: v.number(),
    showTotals: v.number(),
    longestStreak: v.number(),
  }),
  handler: async (ctx, { userId, snapshotMaxUpdatedAt }) => {
    if (!(await isActiveUser(ctx, userId))) {
      return { committed: true, dirtyYears: [], nextSnapshotMaxUpdatedAt: snapshotMaxUpdatedAt, showTotals: 0, longestStreak: 0 };
    }
    const existingAllTime = await ctx.db
      .query("statsAllTime")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();
    const dirty = new Set<string>(existingAllTime?.backfillDirtyYears ?? []);
    let nextWatermark = snapshotMaxUpdatedAt;
    for await (const s of ctx.db
      .query("listeningSessions")
      .withIndex("by_user_updatedAt", (q) => q.eq("userId", userId).gt("updatedAt", snapshotMaxUpdatedAt))) {
      dirty.add(localDay(s.startedAt, s.utcOffsetMinutes).slice(0, 4));
      if (s.updatedAt > nextWatermark) nextWatermark = s.updatedAt;
    }
    if (dirty.size > 0) {
      if (existingAllTime?.backfillDirtyYears?.length) {
        await ctx.db.patch("statsAllTime", existingAllTime._id, { backfillDirtyYears: undefined });
      }
      return {
        committed: false,
        dirtyYears: [...dirty].sort(),
        nextSnapshotMaxUpdatedAt: nextWatermark,
        showTotals: 0,
        longestStreak: 0,
      };
    }

    const days: { day: string; wall: number }[] = [];
    for await (const d of ctx.db.query("statsDays").withIndex("by_user_day", (q) => q.eq("userId", userId))) {
      days.push({ day: d.day, wall: d.wall });
    }
    const best = longestStreak(days);
    const marker = {
      longestStreakLength: best.length,
      longestStreakStartDay: best.startDay,
      longestStreakEndDay: best.endDay,
      rollupsReady: true,
      backfillDirtyYears: undefined,
    };
    if (existingAllTime) await ctx.db.patch("statsAllTime", existingAllTime._id, marker);
    else await ctx.db.insert("statsAllTime", { userId, ...marker });
    return {
      committed: true,
      dirtyYears: [],
      nextSnapshotMaxUpdatedAt: nextWatermark,
      showTotals: 0,
      longestStreak: best.length,
    };
  },
});

/** Backfills `statsEpisodeYears`, `statsShowTotals` and `statsAllTime` for every active user. */
export const backfillStatsRollups = internalAction({
  args: {},
  returns: v.object({ users: v.number(), episodeYears: v.number(), showTotals: v.number() }),
  handler: async (ctx) => {
    const userIds: Id<"users">[] = await ctx.runQuery(internal.migrations.statsBackfillTargets, {});
    let episodeYears = 0;
    let showTotals = 0;

    const rebuildYear = async (userId: Id<"users">, year: string) => {
      for (;;) {
        const cleared: { deleted: number; isDone: boolean } = await ctx.runMutation(
          internal.migrations.clearEpisodeYearBatch,
          { userId, year },
        );
        if (cleared.isDone) break;
      }
      let cursor: string | null = null;
      for (;;) {
        const page: { upserted: number; isDone: boolean; continueCursor: string } = await ctx.runMutation(
          internal.migrations.backfillEpisodeYearPage,
          { userId, year, cursor },
        );
        episodeYears += page.upserted;
        if (page.isDone) break;
        cursor = page.continueCursor;
      }
    };

    const rebuildShowTotals = async (userId: Id<"users">) => {
      for (;;) {
        const cleared: { deleted: number; isDone: boolean } = await ctx.runMutation(
          internal.migrations.clearShowTotalsBatch,
          { userId },
        );
        if (cleared.isDone) break;
      }
      let count = 0;
      let cursor: string | null = null;
      for (;;) {
        const page: { upserted: number; isDone: boolean; continueCursor: string } = await ctx.runMutation(
          internal.migrations.backfillShowTotalsPage,
          { userId, cursor },
        );
        count += page.upserted;
        if (page.isDone) break;
        cursor = page.continueCursor;
      }
      return count;
    };

    for (const userId of userIds) {
      let snapshotMaxUpdatedAt = 0;
      let years: string[] = [];
      for (;;) {
        const cleared: { deleted: number; isDone: boolean; snapshotMaxUpdatedAt: number; years: string[] } =
          await ctx.runMutation(internal.migrations.clearStatsRollupsBatch, { userId });
        if (cleared.isDone) {
          snapshotMaxUpdatedAt = cleared.snapshotMaxUpdatedAt;
          years = cleared.years;
          break;
        }
      }
      for (const year of years) await rebuildYear(userId, year);
      let userShowTotals = await rebuildShowTotals(userId);

      let committed = false;
      for (let round = 0; round < MAX_BACKFILL_ROUNDS; round++) {
        const fin: {
          committed: boolean;
          dirtyYears: string[];
          nextSnapshotMaxUpdatedAt: number;
          showTotals: number;
          longestStreak: number;
        } = await ctx.runMutation(internal.migrations.finalizeUserStatsRollups, {
          userId,
          snapshotMaxUpdatedAt,
        });
        if (fin.committed) {
          showTotals += userShowTotals;
          committed = true;
          break;
        }
        snapshotMaxUpdatedAt = fin.nextSnapshotMaxUpdatedAt;
        for (const year of fin.dirtyYears) await rebuildYear(userId, year);
        userShowTotals = await rebuildShowTotals(userId);
      }
      if (!committed) {
        throw new Error(`backfillStatsRollups did not converge for user ${userId} after ${MAX_BACKFILL_ROUNDS} rounds`);
      }
    }
    return { users: userIds.length, episodeYears, showTotals };
  },
});
