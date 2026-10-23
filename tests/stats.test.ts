import { describe, expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import {
  currentStreak,
  listeningPersonality,
  localDay,
  longestStreak,
  periodRange,
  sessionMetrics,
  splitIntoHours,
  zoneOffsetMinutes,
} from "../convex/lib/statsMath";
import { upsertSession } from "../convex/sessions";
import { computeSummary, computeTotals } from "../convex/stats";
import { asUser } from "../convex/lib/auth";
import { showCache } from "../convex/lib/library";
import { podcastSummary } from "../convex/lib/rows";
import { setup, type T } from "./helpers";
import { BASE, seedShow } from "./seed";

const H = 3600_000;
const AEDT = 660;
/** Local Sydney (AEDT) wall time as UTC ms. */
const syd = (y: number, m: number, d: number, h = 0, min = 0) => Date.UTC(y, m - 1, d, h, min) - AEDT * 60_000;

describe("time saved", () => {
  test("speed saving = content × (1 − 1/rate); Smart Speed saving = removed / rate", () => {
    const content = 3600;
    const rate = 2;
    const removed = 300;
    const wallSecs = (content - removed) / rate; // what the engine actually plays
    const m = sessionMetrics({
      startedAt: 0,
      endedAt: wallSecs * 1000,
      contentStart: 100,
      contentEnd: 100 + content,
      rate,
      smartRemovedContent: removed,
      utcOffsetMinutes: 0,
    });
    expect(m.speedSaved).toBe(1800);
    expect(m.smartSaved).toBe(150);
    expect(m.wall).toBe(1650);
    expect(m.speedSaved + m.smartSaved).toBeCloseTo(m.content - m.wall, 9);
  });

  test("1× with Smart Speed only saves the removed silence", () => {
    const m = sessionMetrics({ startedAt: 0, endedAt: 1_000_000, contentStart: 0, contentEnd: 1100, rate: 1, smartRemovedContent: 100, utcOffsetMinutes: 0 });
    expect(m.speedSaved).toBe(0);
    expect(m.smartSaved).toBe(100);
  });
});

describe("bucketing", () => {
  test("a session over local midnight splits across days and hours by wall time", () => {
    const b = splitIntoHours(syd(2025, 10, 14, 23, 30), syd(2025, 10, 15, 0, 30), AEDT);
    expect(b.map((x) => [x.day, x.hour, x.fraction])).toEqual([
      ["2025-10-14", 23, 0.5],
      ["2025-10-15", 0, 0.5],
    ]);
    expect(b[0]!.weekday).toBe(1); // Tuesday
  });

  test("Sydney offset follows DST", () => {
    expect(zoneOffsetMinutes("Australia/Sydney", Date.UTC(2025, 6, 1))).toBe(600);
    expect(zoneOffsetMinutes("Australia/Sydney", Date.UTC(2025, 11, 1))).toBe(660);
  });

  test("calendar periods, weeks starting Monday", () => {
    expect(periodRange("week", "2025-10-15")).toEqual({ startDay: "2025-10-13", endDay: "2025-10-19" });
    expect(periodRange("month", "2024-02-10")).toEqual({ startDay: "2024-02-01", endDay: "2024-02-29" });
    expect(periodRange("year", "2025-10-15")).toEqual({ startDay: "2025-01-01", endDay: "2025-12-31" });
  });
});

describe("streaks and personality", () => {
  const days = [
    { day: "2025-10-01", wall: 700 },
    { day: "2025-10-02", wall: 601 },
    { day: "2025-10-03", wall: 599 }, // under 10 min breaks it
    { day: "2025-10-04", wall: 3000 },
    { day: "2025-10-05", wall: 3000 },
    { day: "2025-10-06", wall: 3000 },
  ];
  test("longest and current", () => {
    expect(longestStreak(days)).toEqual({ length: 3, startDay: "2025-10-04", endDay: "2025-10-06" });
    expect(currentStreak(days, "2025-10-07").length).toBe(3); // today not reached yet: counts to yesterday
    expect(currentStreak(days, "2025-10-08").length).toBe(0);
  });
  test("night owl", () => {
    const heat = new Array(168).fill(0);
    heat[0 * 24 + 22] = 41;
    heat[2 * 24 + 12] = 59;
    expect(listeningPersonality(heat)).toEqual({ key: "nightOwl", label: "Night owl: 41% after 9 pm", percent: 41 });
  });
});

async function record(t: T, s: { id: string; ep: Id<"episodes">; start: number; mins: number; rate: number; removed?: number; contentStart?: number }) {
  const wall = s.mins * 60;
  const content = wall * s.rate + (s.removed ?? 0);
  return await t.mutation(api.sessions.record, {
    sessions: [
      {
        sessionId: s.id,
        episodeId: s.ep,
        deviceId: "phone",
        startedAt: s.start,
        endedAt: s.start + wall * 1000,
        contentStart: s.contentStart ?? 0,
        contentEnd: (s.contentStart ?? 0) + content,
        rate: s.rate,
        smartSpeed: true,
        smartRemovedContent: s.removed ?? 0,
        voiceBoost: true,
        utcOffsetMinutes: AEDT,
      },
    ],
  });
}

describe("stats queries", () => {
  test("week totals, savings split, average speed, top shows, heatmap and completion", async () => {
    const t = setup();
    const a = await seedShow(t, 2, { title: "alpha" });
    const b = await seedShow(t, 1, { title: "beta" });
    // Tue 14 Oct 08:00 local, 30 min at 2× with 60 s removed.
    await record(t, { id: "s1", ep: a.episodeIds[0]!, start: syd(2025, 10, 14, 8), mins: 30, rate: 2, removed: 60 });
    // Wed 15 Oct 21:00, 20 min at 1×.
    await record(t, { id: "s2", ep: b.episodeIds[0]!, start: syd(2025, 10, 15, 21), mins: 20, rate: 1 });
    // Previous week: excluded.
    await record(t, { id: "s3", ep: a.episodeIds[1]!, start: syd(2025, 10, 8, 8), mins: 10, rate: 1 });
    await t.mutation(api.episodes.setPlayedState, { episodeId: a.episodeIds[0]!, played: true, at: syd(2025, 10, 14, 9) });

    const s = await t.query(api.stats.summary, { period: "week", anchorDay: "2025-10-15" });
    expect(s.startDay).toBe("2025-10-13");
    expect(s.totals.wall).toBeCloseTo(50 * 60, 6);
    // s1 content = 1800×2 + 60 = 3660; s2 content = 1200.
    expect(s.totals.content).toBeCloseTo(4860, 6);
    expect(s.totals.speedSaved).toBeCloseTo(3660 * 0.5, 6);
    expect(s.totals.smartSaved).toBeCloseTo(30, 6);
    expect(s.totals.timeSaved).toBeCloseTo(s.totals.content - s.totals.wall, 6);
    expect(s.totals.averageSpeed).toBeCloseTo((3660 * 2 + 1200) / 4860, 6);
    expect(s.topShows.map((x) => x.podcast.title)).toEqual(["alpha", "beta"]);
    expect(s.topEpisodes[0]).toMatchObject({ title: "Ep 0", sessions: 1 });
    expect(s.heatmap[1 * 24 + 8]).toBeCloseTo(1800, 6); // Tuesday 8am
    expect(s.heatmap[2 * 24 + 21]).toBeCloseTo(1200, 6); // Wednesday 9pm
    // Both episodes passed 5 min; one was completed.
    expect(s.completion).toEqual({ started: 2, completed: 1, rate: 0.5 });
    expect(s.busiestDay).toEqual({ day: "2025-10-14", wall: 1800 });
    expect(s.longestStreak.length).toBe(2);
  });

  test("re-sending a session id replaces it; stale or identical copies are no-ops", async () => {
    const t = setup();
    const a = await seedShow(t, 1);
    const start = syd(2025, 10, 14, 8);
    expect(await record(t, { id: "s1", ep: a.episodeIds[0]!, start, mins: 10, rate: 1 })).toMatchObject({ inserted: 1 });
    expect(await record(t, { id: "s1", ep: a.episodeIds[0]!, start, mins: 25, rate: 1 })).toMatchObject({ updated: 1 });
    expect(await record(t, { id: "s1", ep: a.episodeIds[0]!, start, mins: 25, rate: 1 })).toMatchObject({ unchanged: 1 });
    expect(await record(t, { id: "s1", ep: a.episodeIds[0]!, start, mins: 15, rate: 1 })).toMatchObject({ unchanged: 1 });
    const s = await t.query(api.stats.summary, { period: "month", anchorDay: "2025-10-01" });
    expect(s.totals.wall).toBeCloseTo(25 * 60, 6);
    expect(s.totals.sessions).toBe(1);
    expect(s.completion.started).toBe(1);
  });

  test("estimated sessions count in totals and streaks but not the heatmap", async () => {
    const t = setup();
    const a = await seedShow(t, 1);
    const userId = await t.userId();
    await t.run(async (ctx) => {
      await upsertSession(asUser(ctx, userId), {
        sessionId: "overcast:1",
        episodeId: a.episodeIds[0]!,
        podcastId: a.podcastId,
        startedAt: syd(2025, 3, 1, 12),
        endedAt: syd(2025, 3, 1, 13),
        contentStart: 0,
        contentEnd: 5400,
        rate: 1.5,
        smartSpeed: false,
        smartRemovedContent: 0,
        voiceBoost: false,
        source: "overcastImport",
        isEstimated: true,
        utcOffsetMinutes: AEDT,
        updatedAt: 0,
      });
    });
    const y = await t.query(api.stats.yearInReview, { year: 2025 });
    expect(y.totals.wall).toBe(3600);
    expect(y.totals.estimatedWall).toBe(3600);
    expect(y.includesEstimated).toBe(true);
    expect(y.heatmap.every((x) => x === 0)).toBe(true);
    expect(y.longestStreak.length).toBe(1);
    expect(y.topShows[0]?.podcast.title).toBe("Show");
    expect(y.firstEpisode?.title).toBe("Ep 0");
    expect(y.busiestMonth).toEqual({ month: "2025-03", wall: 3600 });
    expect(y.newShows.map((p) => p.title)).toEqual(["Show"]);
  });

  test("year in review leaves private shows out", async () => {
    const t = setup();
    const a = await seedShow(t, 1, { title: "secret" });
    await t.run(async (ctx) => ctx.db.patch(a.podcastId, { isPrivate: true }));
    await record(t, { id: "p1", ep: a.episodeIds[0]!, start: syd(2025, 10, 14, 8), mins: 30, rate: 1 });
    const y = await t.query(api.stats.yearInReview, { year: 2025 });
    expect(y.topShows).toEqual([]);
    expect(y.topEpisode).toBeNull();
    expect(y.firstEpisode).toBeNull();
    expect(y.totals.wall).toBe(1800);
    const withPrivate = await t.query(api.stats.yearInReview, { year: 2025, includePrivate: true });
    expect(withPrivate.topShows).toHaveLength(1);
  });
});

// ---- Top episodes: rank first, look up only what can make the list ----

type Plan = {
  /** Wall seconds heard, one session per entry. */
  wall: number | number[];
  /** Give it an episode state, starred or not. No state row when left out. */
  starred?: boolean;
  /** Delete the episode, or its show, after listening. */
  gone?: "episode" | "show";
};

/**
 * One episode per plan, listened to in 2025 (and kept in `episodeTotals` for
 * all time), straight into the tables: top episodes reads raw sessions, so
 * this skips the rollups `sessions:record` keeps. `startOf` places session `k`
 * of plan `i`.
 */
async function heard(t: T, plans: Plan[], startOf = (i: number, k: number) => syd(2025, 3, 1) + (i * 4 + k) * H) {
  const userId = await t.userId();
  return await t.run(async (ctx) => {
    const newShow = (title: string) =>
      ctx.db.insert("podcasts", { feedUrl: `https://feeds.example.com/${title}.xml`, title, isPrivate: false, episodeCount: 0, createdAt: BASE, updatedAt: BASE });
    const main = await newShow("main");
    const episodeIds: Id<"episodes">[] = [];
    const stateIds: (Id<"episodeStates"> | null)[] = [];
    for (const [i, p] of plans.entries()) {
      const podcastId = p.gone === "show" ? await newShow(`gone-${i}`) : main;
      const episodeId = await ctx.db.insert("episodes", {
        podcastId,
        title: `E${i}`,
        guid: `e-${i}`,
        transcripts: [],
        isGhost: false,
        firstSeenAt: BASE,
        updatedAt: BASE,
      });
      const walls = typeof p.wall === "number" ? [p.wall] : p.wall;
      for (const [k, wall] of walls.entries()) {
        const start = startOf(i, k);
        await ctx.db.insert("listeningSessions", {
          userId,
          sessionId: `s-${i}-${k}`,
          episodeId,
          podcastId,
          startedAt: start,
          endedAt: start + wall * 1000,
          contentStart: 0,
          contentEnd: wall,
          rate: 1,
          smartSpeed: false,
          smartRemovedContent: 0,
          voiceBoost: false,
          source: "live",
          isEstimated: false,
          utcOffsetMinutes: AEDT,
          updatedAt: start,
        });
      }
      const total = walls.reduce((a, w) => a + w, 0);
      await ctx.db.insert("episodeTotals", { userId, episodeId, podcastId, wall: total, content: total, sessions: walls.length });
      stateIds.push(
        p.starred === undefined
          ? null
          : await ctx.db.insert("episodeStates", {
              userId,
              episodeId,
              podcastId,
              position: 0,
              positionUpdatedAt: 0,
              played: false,
              playedUpdatedAt: 0,
              starred: p.starred,
              starredUpdatedAt: 0,
              archived: false,
              archivedUpdatedAt: 0,
              inInbox: false,
              inboxUpdatedAt: 0,
              updatedAt: 0,
            }),
      );
      if (p.gone === "episode") await ctx.db.delete(episodeId);
      if (p.gone === "show") await ctx.db.delete(podcastId);
      episodeIds.push(episodeId);
    }
    return { episodeIds, stateIds };
  });
}

/**
 * `topEpisodes` as it was before it ranked first: every episode in the period
 * looked up, then sorted and cut. The new one must give the same answer.
 */
async function oldTopEpisodes(t: T, period: "year" | "all", anchorDay: string, limit = 10) {
  const userId = await t.userId();
  const { startDay, endDay } = periodRange(period, anchorDay);
  return await t.run(async (raw) => {
    const ctx = asUser(raw, userId);
    let ranked: { episodeId: Id<"episodes">; wall: number; sessions: number }[];
    if (period === "all") {
      const totals = await ctx.db
        .query("episodeTotals")
        .withIndex("by_user_wall", (q) => q.eq("userId", userId))
        .order("desc")
        .take(limit * 2);
      ranked = totals.map((x) => ({ episodeId: x.episodeId, wall: x.wall, sessions: x.sessions }));
    } else {
      const sessions = await ctx.db
        .query("listeningSessions")
        .withIndex("by_user_startedAt", (q) => q.eq("userId", userId))
        .collect();
      const byEpisode = new Map<Id<"episodes">, { wall: number; sessions: number }>();
      for (const s of sessions) {
        const d = localDay(s.startedAt, s.utcOffsetMinutes);
        if (d < startDay || d > endDay) continue;
        const acc = byEpisode.get(s.episodeId) ?? { wall: 0, sessions: 0 };
        acc.wall += sessionMetrics(s).wall;
        acc.sessions += 1;
        byEpisode.set(s.episodeId, acc);
      }
      ranked = [...byEpisode.entries()].map(([episodeId, a]) => ({ episodeId, ...a }));
    }
    const rows = [];
    const show = showCache(ctx);
    for (const r of ranked) {
      const episode = await ctx.db.get(r.episodeId);
      const podcast = episode && (await show(episode.podcastId));
      if (!episode || !podcast || r.wall <= 0.5) continue;
      const state = await ctx.db
        .query("episodeStates")
        .withIndex("by_user_episode", (q) => q.eq("userId", userId).eq("episodeId", r.episodeId))
        .unique();
      rows.push({
        episodeId: episode._id,
        title: episode.title,
        artworkUrl: episode.artworkUrl ?? podcast.artworkUrl,
        podcast: podcastSummary(podcast),
        wall: r.wall,
        sessions: r.sessions,
        starred: state?.starred ?? false,
      });
    }
    rows.sort((a, b) => (Math.abs(b.wall - a.wall) < 60 ? Number(b.starred) - Number(a.starred) : 0) || b.wall - a.wall);
    return rows.slice(0, limit);
  });
}

/**
 * Wraps `ctx.db` to note every table queried and every document read: what a
 * subscription to the query would depend on.
 */
function readTracker<C extends { db: object }>(ctx: C) {
  const tables: string[] = [];
  const ids = new Set<string>();
  const note = (out: unknown) => {
    for (const d of Array.isArray(out) ? out : [out]) if (d) ids.add((d as { _id: string })._id);
    return out;
  };
  // Builder calls (withIndex, order) return more builders; the terminal ones
  // (collect, take, first, unique) return promises of documents.
  const wrap = (target: object): object =>
    new Proxy(target, {
      get(t, prop) {
        const value = Reflect.get(t, prop);
        if (typeof value !== "function") return value;
        return (...args: unknown[]) => {
          const out = value.apply(t, args);
          if (out instanceof Promise) return out.then(note);
          return typeof out === "object" && out !== null ? wrap(out) : out;
        };
      },
    });
  const db = new Proxy(ctx.db, {
    get(t, prop) {
      const value = Reflect.get(t, prop);
      if (prop === "query") return (table: string) => (tables.push(table), wrap(value.call(t, table)));
      if (prop === "get") return async (...args: unknown[]) => note(await value.apply(t, args));
      return typeof value === "function" ? value.bind(t) : value;
    },
  });
  return { ctx: { ...ctx, db } as C, tables, ids };
}

/** A small seeded PRNG (mulberry32), so a failing case can be replayed. */
function prng(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let x = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

describe("top episodes", () => {
  const titles = (rows: { title: string }[]) => rows.map((r) => r.title);
  const far = (n: number) => Array.from({ length: n }, (_, i): Plan => ({ wall: 9000 - i * 300, starred: false }));

  test("more episodes than the limit: the ten with the most wall time, most first", async () => {
    const t = setup();
    await heard(t, Array.from({ length: 15 }, (_, i): Plan => ({ wall: 1000 + i * 120 })));
    const s = await t.query(api.stats.summary, { period: "year", anchorDay: "2025-06-01" });
    expect(titles(s.topEpisodes)).toEqual(["E14", "E13", "E12", "E11", "E10", "E9", "E8", "E7", "E6", "E5"]);
    expect(s.topEpisodes).toEqual(await oldTopEpisodes(t, "year", "2025-06-01"));
  });

  test("a starred episode just under the cut-off can still take the last places", async () => {
    const t = setup();
    // E0–E7 are far ahead. Then, a minute apart or less: E8 and E9 unstarred
    // (the 9th and 10th by wall time), E10 unstarred, and E11–E13 starred.
    await heard(t, [
      ...far(8),
      { wall: 5000, starred: false },
      { wall: 4990, starred: false },
      { wall: 4980, starred: false }, // unstarred, so never passes E8 or E9
      { wall: 4950, starred: true }, // within a minute of E8 and E9: passes both
      { wall: 4935, starred: true }, // passes E9 (55 s) but not E8 (65 s)
      { wall: 4930, starred: true }, // exactly a minute under E9: passes neither
    ]);
    const s = await t.query(api.stats.summary, { period: "year", anchorDay: "2025-06-01" });
    expect(titles(s.topEpisodes)).toEqual(["E0", "E1", "E2", "E3", "E4", "E5", "E6", "E7", "E11", "E8"]);
    expect(s.topEpisodes.find((e) => e.title === "E11")?.starred).toBe(true);
    expect(s.topEpisodes).toEqual(await oldTopEpisodes(t, "year", "2025-06-01"));
  });

  test("missing episodes, missing shows and blips are skipped, and the list still fills", async () => {
    const t = setup();
    await heard(t, [
      { wall: 20000, gone: "episode" },
      { wall: 19000, gone: "show" },
      { wall: 18000, starred: true, gone: "episode" },
      { wall: 0.3 },
      { wall: [0.2, 0.2] }, // two blips still under half a second in total
      ...Array.from({ length: 12 }, (_, i): Plan => ({ wall: 10000 - i * 500 })),
    ]);
    const s = await t.query(api.stats.summary, { period: "year", anchorDay: "2025-06-01" });
    expect(titles(s.topEpisodes)).toEqual(["E5", "E6", "E7", "E8", "E9", "E10", "E11", "E12", "E13", "E14"]);
    expect(s.topEpisodes).toEqual(await oldTopEpisodes(t, "year", "2025-06-01"));
  });

  test("matches the old look-everything-up ranking on random near-ties, stars and gaps", async () => {
    let starsChangedTheTen = 0;
    for (let seed = 1; seed <= 25; seed++) {
      const rand = prng(seed);
      const pick = (n: number) => Math.floor(rand() * n);
      // Walls bunched into a few minutes, in 20 s steps, so near-ties and
      // exact ties are common around the cut-off.
      const plans = Array.from({ length: 30 }, (): Plan => {
        const total = rand() < 0.05 ? 0.4 : 1800 + 20 * pick(16);
        const split = rand() < 0.3 ? [total - 300, 300] : [total];
        const r = rand();
        return {
          wall: split,
          starred: r < 0.3 ? true : r < 0.6 ? false : undefined,
          gone: rand() < 0.08 ? "episode" : rand() < 0.04 ? "show" : undefined,
        };
      });
      const t = setup();
      // Sessions land anywhere from late 2024 to the end of 2025, so the year
      // has to filter, and the order episodes are first heard is shuffled.
      await heard(t, plans, () => syd(2024, 12, 27) + pick(370 * 24) * H);
      for (const period of ["year", "all"] as const) {
        const s = await t.query(api.stats.summary, { period, anchorDay: "2025-06-01" });
        const old = await oldTopEpisodes(t, period, "2025-06-01");
        expect(s.topEpisodes, `seed ${seed}, ${period}`).toEqual(old);
        if (period === "year") {
          const byWall = [...old].sort((a, b) => b.wall - a.wall);
          if (old.some((r, i) => r.wall < byWall[i]!.wall)) starsChangedTheTen++;
        }
      }
      // Year in review asks for 30, more than there are.
      const y = await t.query(api.stats.yearInReview, { year: 2025, includePrivate: true });
      expect(y.topEpisode, `seed ${seed}, year in review`).toEqual((await oldTopEpisodes(t, "year", "2025-06-01", 30))[0] ?? null);
    }
    // The random cases did exercise the star tie-break.
    expect(starsChangedTheTen).toBeGreaterThan(0);
  });

  test("regression: a year's summary only reads the state of episodes that can make the top ten", async () => {
    // Every Stats subscription used to read the state of every episode heard in
    // the period, including the one playing, whose position is saved every few
    // seconds. So each save re-ran it over thousands of documents.
    const t = setup();
    const userId = await t.userId();
    const { episodeIds, stateIds } = await heard(t, Array.from({ length: 40 }, (_, i): Plan => ({ wall: 30000 - i * 600, starred: false })));
    const reads = await t.run(async (ctx) => {
      const r = readTracker(ctx);
      await computeSummary(asUser(r.ctx, userId), "year", "2025-06-01");
      return [...r.ids];
    });
    expect(stateIds.filter((id) => reads.includes(id!))).toEqual(stateIds.slice(0, 10));
    expect(episodeIds.filter((id) => reads.includes(id))).toEqual(episodeIds.slice(0, 10));
  });

  test("regression: past the cut-off, only starred episodes within a minute are looked up", async () => {
    const t = setup();
    const userId = await t.userId();
    const { episodeIds, stateIds } = await heard(t, [
      ...far(8),
      { wall: 5000, starred: false },
      { wall: 4990, starred: false }, // the 10th: the cut-off is 4930
      { wall: 4980, starred: false }, // state checked, not starred: episode not read
      { wall: 4950, starred: true }, // read in full
      { wall: 4930, starred: true }, // a minute under: the walk stops here
      { wall: 3000, starred: true },
    ]);
    const reads = await t.run(async (ctx) => {
      const r = readTracker(ctx);
      await computeSummary(asUser(r.ctx, userId), "year", "2025-06-01");
      return [...r.ids];
    });
    expect(stateIds.filter((id) => reads.includes(id!))).toEqual(stateIds.slice(0, 12));
    expect(episodeIds.filter((id) => reads.includes(id))).toEqual([...episodeIds.slice(0, 10), episodeIds[11]]);
  });
});

describe("stats totals (the website's stat cards)", () => {
  async function listened(t: T) {
    const a = await seedShow(t, 3, { title: "alpha" });
    await record(t, { id: "w1", ep: a.episodeIds[0]!, start: syd(2025, 10, 14, 8), mins: 30, rate: 2, removed: 60 });
    await record(t, { id: "w2", ep: a.episodeIds[1]!, start: syd(2025, 10, 15, 21), mins: 20, rate: 1 });
    await record(t, { id: "m1", ep: a.episodeIds[1]!, start: syd(2025, 10, 2, 7), mins: 15, rate: 1.5 });
    await record(t, { id: "y1", ep: a.episodeIds[2]!, start: syd(2025, 3, 3, 12), mins: 45, rate: 1.2, removed: 30 });
    await record(t, { id: "old", ep: a.episodeIds[2]!, start: syd(2024, 7, 1, 12), mins: 10, rate: 1 });
    await t.mutation(api.episodes.setPlayedState, { episodeId: a.episodeIds[0]!, played: true, at: syd(2025, 10, 14, 9) });
    return a;
  }

  test("the same totals and completion as the summary, for every period", async () => {
    const t = setup();
    await listened(t);
    for (const period of ["week", "month", "year", "all"] as const) {
      const s = await t.query(api.stats.summary, { period, anchorDay: "2025-10-15" });
      const totals = await t.query(api.stats.totals, { period, anchorDay: "2025-10-15" });
      expect(totals, period).toEqual({ totals: s.totals, completion: s.completion });
    }
    const week = await t.query(api.stats.totals, { period: "week", anchorDay: "2025-10-15" });
    expect(week.totals.wall).toBeCloseTo(50 * 60, 6);
    expect(week.totals.timeSaved).toBeCloseTo(3660 * 0.5 + 30, 6);
    expect(week.completion).toEqual({ started: 2, completed: 1, rate: 0.5 });
    expect((await t.query(api.stats.totals, { period: "all" })).totals.sessions).toBe(5);
  });

  test("nothing played: zero totals, no average speed or completion rate", async () => {
    const t = setup();
    expect(await t.query(api.stats.totals, { period: "year", anchorDay: "2025-10-15" })).toEqual({
      totals: { wall: 0, content: 0, speedSaved: 0, smartSaved: 0, timeSaved: 0, estimatedWall: 0, sessions: 0, averageSpeed: null },
      completion: { started: 0, completed: 0, rate: null },
    });
  });

  test("reads only the rollups, never sessions, episodes or episode state", async () => {
    const t = setup();
    const userId = await t.userId();
    await listened(t);
    for (const period of ["week", "month", "year", "all"] as const) {
      const tables = await t.run(async (ctx) => {
        const r = readTracker(ctx);
        await computeTotals(asUser(r.ctx, userId), period, undefined);
        return r.tables;
      });
      expect(new Set(tables), period).toEqual(new Set(["globalSettings", period === "week" || period === "month" ? "statsDays" : "statsMonths"]));
    }
  });
});
