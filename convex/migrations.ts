import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id, TableNames } from "./_generated/dataModel";
import { internalAction, internalMutation, internalQuery } from "./_generated/server";
import { userByEmail } from "./lib/identity";

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
      if (!existing.emailVerified) await ctx.db.patch(existing._id, { emailVerified: true });
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
        await ctx.db.patch(p._id, { subscribed: undefined, subscribedAt: undefined, unsubscribedAt: undefined, subscriptionUpdatedAt: undefined });
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
