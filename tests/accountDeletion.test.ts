import { convexTest } from "convex-test";
import feedbackTest from "@convex-dev/feedback/test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api, components, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { BATCH, PERSONAL_INDEX, STALL_MS } from "../convex/accountDeletion";
import schema from "../convex/schema";
import { MIKE, TOKEN, modules, signedIn, type T } from "./helpers";
import { BASE } from "./seed";

// users:deleteAccount and the background deletion (convex/accountDeletion.ts).

const OTHER = "listener@example.com";
const TABLES = Object.keys(PERSONAL_INDEX) as (keyof typeof PERSONAL_INDEX)[];

function setupDeletion() {
  process.env.PODDLE_API_TOKEN = TOKEN;
  process.env.CONVEX_SITE_URL ??= "https://poddle-test.convex.site";
  vi.useFakeTimers();
  const raw = convexTest(schema, modules);
  feedbackTest.register(raw);
  return signedIn(raw, OTHER);
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

const drain = (t: T) => t.finishAllScheduledFunctions(() => vi.runAllTimers());

/** More library events than one step deletes, so a deletion takes several steps. */
async function seedHistory(t: T, podcastId: Id<"podcasts">, n = BATCH + 50) {
  const userId = await t.userId();
  await t.run(async (ctx) => {
    for (let i = 0; i < n; i++) {
      await ctx.db.insert("libraryEvents", { userId, eventId: `h${i}`, type: "completed", podcastId, at: i, updatedAt: i });
    }
  });
}

/** A shared show and episode, with its feed being polled. */
async function seedCatalogue(t: T) {
  return await t.run(async (ctx) => {
    const podcastId = await ctx.db.insert("podcasts", {
      feedUrl: "https://feeds.example.com/show.xml", title: "Show", isPrivate: false, episodeCount: 1,
      createdAt: BASE, updatedAt: BASE,
    });
    const episodeId = await ctx.db.insert("episodes", {
      podcastId, title: "Ep", transcripts: [], isGhost: false, firstSeenAt: BASE, updatedAt: BASE,
    });
    await ctx.db.insert("episodeNotes", { episodeId, html: "<p>hi</p>", updatedAt: BASE });
    await ctx.db.insert("feedStates", { podcastId, active: true, nextCheckAt: BASE, consecutiveErrors: 0 });
    return { podcastId, episodeId };
  });
}

/** `n` rows of this person's in every personal table (and an import's scratch rows), plus a Chef request. */
async function seedPerson(t: T, ids: { podcastId: Id<"podcasts">; episodeId: Id<"episodes"> }, n = 2) {
  const userId = await t.userId();
  const { podcastId, episodeId } = ids;
  await t.run(async (ctx) => {
    const at = BASE;
    for (let i = 0; i < n; i++) {
      await ctx.db.insert("subscriptions", {
        userId, podcastId, subscribed: true, subscriptionUpdatedAt: at, addedAt: at, updatedAt: at,
      });
      await ctx.db.insert("episodeStates", {
        userId, episodeId, podcastId, position: 10, positionUpdatedAt: at, played: false, playedUpdatedAt: at,
        starred: false, starredUpdatedAt: at, archived: false, archivedUpdatedAt: at, inInbox: false,
        inboxUpdatedAt: at, updatedAt: at,
      });
      await ctx.db.insert("queueItems", {
        userId, episodeId, podcastId, orderKey: `a${i}`, addedAt: at, addedBy: "manual", orderUpdatedAt: at, updatedAt: at,
      });
      await ctx.db.insert("deletions", { userId, table: "queueItems", docId: `x${i}`, deletedAt: at, updatedAt: at });
      await ctx.db.insert("podcastSettings", { userId, podcastId, fieldTimes: {}, updatedAt: at });
      await ctx.db.insert("globalSettings", { userId, fieldTimes: {}, updatedAt: at });
      await ctx.db.insert("listeningSessions", {
        userId, sessionId: `s${i}`, episodeId, podcastId, startedAt: at, endedAt: at + 60_000, contentStart: 0,
        contentEnd: 60, rate: 1, smartSpeed: false, smartRemovedContent: 0, voiceBoost: false, source: "live",
        isEstimated: false, utcOffsetMinutes: 480, updatedAt: at,
      });
      await ctx.db.insert("libraryEvents", { userId, eventId: `e${i}`, type: "subscribed", podcastId, at, updatedAt: at });
      await ctx.db.insert("devices", {
        userId, deviceId: `${userId}-d${i}`, name: "Phone", platform: "iOS", apnsToken: `${userId}-tok${i}`,
        lastSeenAt: at, updatedAt: at,
      });
      const stats = { wall: 60, content: 60, speedSaved: 0, smartSaved: 0, sessions: 1 };
      const rollup = { ...stats, rateContent: 60, estimatedWall: 0, episodesStarted: 1, episodesCompleted: 0 };
      await ctx.db.insert("statsDays", { userId, day: `2025-10-1${i}`, ...rollup, liveHours: [] });
      await ctx.db.insert("statsMonths", { userId, month: `2025-1${i}`, ...rollup, heatmap: [] });
      await ctx.db.insert("statsShowDays", { userId, day: `2025-10-1${i}`, podcastId, ...stats });
      await ctx.db.insert("statsShowMonths", { userId, month: `2025-1${i}`, podcastId, ...stats });
      await ctx.db.insert("episodeTotals", { userId, episodeId, podcastId, wall: 60, content: 60, sessions: 1 });
      const counts = {
        podcasts: 1, subscribedPodcasts: 1, podcastsProcessed: 0, feedsFailed: 0, episodes: 1, episodesMatched: 0,
        ghostEpisodes: 0, playedEpisodes: 0, inProgressEpisodes: 0, starredEpisodes: 0, sessions: 0,
        estimatedListenSeconds: 0,
      };
      const batchId = await ctx.db.insert("importBatches", {
        userId, source: "overcast", status: "fetching", assumedSpeed: 2, startedAt: at + i, counts, playlists: [], updatedAt: at,
      });
      await ctx.db.insert("importItems", {
        batchId, podcastId, overcastId: i, title: "Ep", played: false, userDeleted: false,
      });
      await ctx.db.insert("importQueue", { batchId, podcastId, phase: "fetch" });
      await ctx.db.insert("importUpNext", { batchId, episodeId, podcastId, at });
    }
    await ctx.runMutation(components.feedback.items.create, { userId, title: "Dark mode", description: "Please" });
  });
}

/** How many rows this person has in every personal table, plus their scratch import rows and Chef requests. */
async function counts(t: T, userId: Id<"users">) {
  return await t.run(async (ctx) => {
    const out: Record<string, number> = {};
    for (const table of TABLES) {
      out[table] = (await ctx.db.query(table).collect()).filter((r) => r.userId === userId).length;
    }
    // Scratch rows whose batch is gone count as theirs too.
    const batches = new Set((await ctx.db.query("importBatches").collect()).filter((b) => b.userId !== userId).map((b) => b._id));
    for (const table of ["importItems", "importQueue", "importUpNext"] as const) {
      out[table] = (await ctx.db.query(table).collect()).filter((r) => !batches.has(r.batchId)).length;
    }
    out.chefRequests = (await ctx.runQuery(components.feedback.items.listByCreator, { userId, limit: 100 })).length;
    return out;
  });
}

const allZero = (c: Record<string, number>) => Object.fromEntries(Object.keys(c).map((k) => [k, 0]));

describe("account deletion", { timeout: 60_000 }, () => {
  test("covers every personal table in the schema", () => {
    const tables = schema.tables as unknown as Record<string, { validator: { json: { value?: Record<string, unknown> } } }>;
    const owned = Object.entries(tables)
      .filter(([, def]) => "userId" in (def.validator.json.value ?? {}))
      .map(([name]) => name)
      .filter((name) => name !== "accountDeletions");
    expect(owned.sort()).toEqual([...TABLES].sort());
  });

  test("deletes everything of the caller's, signs them out, and leaves everyone else alone", async () => {
    const leaving = setupDeletion();
    const staying = leaving.as(MIKE);
    const ids = await seedCatalogue(leaving);
    await seedPerson(leaving, ids);
    await seedPerson(staying, ids);
    const leavingId = await leaving.userId();
    const stayingId = await staying.userId();
    const before = await counts(staying, stayingId);
    expect(Object.values(before).every((n) => n > 0)).toBe(true);
    expect(await counts(leaving, leavingId)).toEqual(before);

    await leaving.mutation(api.users.deleteAccount, {});
    // Signed out straight away, before any of the background work.
    expect(await leaving.query(api.users.me, {})).toBeNull();
    await expect(leaving.query(api.queue.upNext, {})).rejects.toThrow(/Sign in first/);
    const tomb = await leaving.run((ctx) => ctx.db.get(leavingId));
    expect(tomb).toMatchObject({ deletedAt: expect.any(Number) });
    expect(tomb?.email).toBeUndefined();
    expect(tomb?.name).toBeUndefined();

    await drain(leaving);
    expect(await counts(leaving, leavingId)).toEqual(allZero(before));
    expect(await counts(staying, stayingId)).toEqual(before);
    expect(await staying.query(api.users.me, {})).toMatchObject({ email: MIKE });
    const deletion = await leaving.run((ctx) => ctx.db.query("accountDeletions").first());
    expect(deletion).toMatchObject({ userId: leavingId, finishedAt: expect.any(Number), deletedRows: expect.any(Number) });
    // Shared catalogue data stays.
    await leaving.run(async (ctx) => {
      expect(await ctx.db.get(ids.podcastId)).not.toBeNull();
      expect(await ctx.db.get(ids.episodeId)).not.toBeNull();
      expect(await ctx.db.query("episodeNotes").collect()).toHaveLength(1);
    });
  });

  test("stops polling a feed nobody subscribes to any more", async () => {
    const t = setupDeletion();
    const ids = await seedCatalogue(t);
    await seedPerson(t, ids, 1);
    await t.mutation(api.users.deleteAccount, {});
    await drain(t);
    const state = await t.run((ctx) => ctx.db.query("feedStates").first());
    expect(state?.active).toBe(false);
  });

  test("works through a big library in batches", async () => {
    const t = setupDeletion();
    const ids = await seedCatalogue(t);
    const userId = await t.userId();
    const many = BATCH * 2 + 37;
    await seedHistory(t, ids.podcastId, many);
    await t.mutation(api.users.deleteAccount, {});
    // One step deletes at most BATCH rows.
    await t.run(async (ctx) => {
      const d = (await ctx.db.query("accountDeletions").first())!;
      await ctx.runMutation(internal.accountDeletion.step, { deletionId: d._id });
      expect((await ctx.db.query("libraryEvents").collect()).length).toBe(many - BATCH);
    });
    await drain(t);
    expect((await counts(t, userId)).libraryEvents).toBe(0);
  });

  test("picks up again after an interruption, and running again is harmless", async () => {
    const t = setupDeletion();
    const ids = await seedCatalogue(t);
    await seedPerson(t, ids, 3);
    await seedHistory(t, ids.podcastId);
    const userId = await t.userId();
    const before = await counts(t, userId);
    await t.mutation(api.users.deleteAccount, {});
    const deletionId = (await t.run((ctx) => ctx.db.query("accountDeletions").first()))!._id;

    // The chain stops partway: every pending step is cancelled.
    await t.run(async (ctx) => {
      await ctx.runMutation(internal.accountDeletion.step, { deletionId });
      for (const job of await ctx.db.system.query("_scheduled_functions").collect()) {
        if (job.state.kind === "pending") await ctx.scheduler.cancel(job._id);
      }
    });
    expect((await t.run((ctx) => ctx.db.get(deletionId)))?.finishedAt).toBeUndefined();

    // Nothing restarts it until it's been quiet for a while.
    expect(await t.run((ctx) => ctx.runMutation(internal.accountDeletion.resumeStalled, {}))).toBe(0);
    vi.advanceTimersByTime(STALL_MS + 1);
    expect(await t.run((ctx) => ctx.runMutation(internal.accountDeletion.resumeStalled, {}))).toBe(1);
    // A stray duplicate step at the same time does no harm.
    await t.run((ctx) => ctx.scheduler.runAfter(0, internal.accountDeletion.step, { deletionId }));
    await drain(t);
    expect(await counts(t, userId)).toEqual(allZero(before));
    expect((await t.run((ctx) => ctx.db.get(deletionId)))?.finishedAt).toEqual(expect.any(Number));

    // Steps on a finished deletion, or starting it all again, find nothing to do.
    await t.run((ctx) => ctx.runMutation(internal.accountDeletion.step, { deletionId }));
    await t.run(async (ctx) => {
      const { startDeletion } = await import("../convex/accountDeletion");
      await startDeletion(ctx, userId);
    });
    await drain(t);
    expect(await counts(t, userId)).toEqual(allZero(before));
  });

  test("rows written behind the sweep get another pass", async () => {
    const t = setupDeletion();
    const ids = await seedCatalogue(t);
    await seedPerson(t, ids, 1);
    await seedHistory(t, ids.podcastId);
    const userId = await t.userId();
    await t.mutation(api.users.deleteAccount, {});
    const deletionId = (await t.run((ctx) => ctx.db.query("accountDeletions").first()))!._id;
    await t.run(async (ctx) => {
      // The first step gets past Up Next, then a late fan-out adds a queue item.
      await ctx.runMutation(internal.accountDeletion.step, { deletionId });
      await ctx.db.insert("queueItems", {
        userId, episodeId: ids.episodeId, podcastId: ids.podcastId, orderKey: "z", addedAt: 1, addedBy: "auto", orderUpdatedAt: 1, updatedAt: 1,
      });
    });
    await drain(t);
    expect((await counts(t, userId)).queueItems).toBe(0);
    expect((await t.run((ctx) => ctx.db.get(deletionId)))?.passes).toBeGreaterThan(1);
  });

  test("only the person themselves can delete, signed in", async () => {
    const t = setupDeletion();
    await t.userId();
    await expect(t.raw.mutation(api.users.deleteAccount, {})).rejects.toThrow(/Sign in first/);
    // No admin path: a script can't delete someone.
    await expect(
      t.raw.mutation(api.users.deleteAccount, { admin: { token: TOKEN, email: OTHER } } as never),
    ).rejects.toThrow();
    expect(await t.run((ctx) => ctx.db.query("accountDeletions").collect())).toEqual([]);
  });
});

describe("signing in again after deleting", { timeout: 60_000 }, () => {
  const google = (email: string) => ({
    name: "google" as const,
    accountId: `g-${email}`,
    profile: { id: `g-${email}`, email, emailVerified: true, name: "Back Again", picture: "https://example.com/p.png" },
  });

  test("waits for the deletion, then comes back as an empty account if they could sign up", async () => {
    const t = setupDeletion();
    vi.stubEnv("PODDLE_ALLOWED_EMAILS", "");
    const ids = await seedCatalogue(t);
    await seedPerson(t, ids, 1);
    const userId = await t.userId();
    await t.mutation(api.users.deleteAccount, {});

    // Still deleting: not yet.
    await expect(t.raw.mutation(internal.users.onSignInGoogle, { provider: google(OTHER), userId })).rejects.toThrow(/still being deleted/);
    await drain(t);
    // Invite-only and not on the list: no.
    await expect(t.raw.mutation(internal.users.onSignInGoogle, { provider: google(OTHER), userId })).rejects.toThrow(/invite-only/);
    // Open sign-up: back, with nothing in it.
    vi.stubEnv("PODDLE_OPEN_SIGNUP", "1");
    await t.raw.mutation(internal.users.onSignInGoogle, { provider: google(OTHER), userId });
    expect(await t.query(api.users.me, {})).toMatchObject({ userId, email: OTHER, name: "Back Again" });
    expect(await t.query(api.queue.upNext, {})).toEqual([]);
  });
});
