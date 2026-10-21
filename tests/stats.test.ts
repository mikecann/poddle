import { describe, expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import {
  currentStreak,
  listeningPersonality,
  longestStreak,
  periodRange,
  sessionMetrics,
  splitIntoHours,
  zoneOffsetMinutes,
} from "../convex/lib/statsMath";
import { upsertSession } from "../convex/sessions";
import { setup, TOKEN, type T } from "./helpers";
import { seedShow } from "./seed";

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
    token: TOKEN,
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
    await t.mutation(api.episodes.setPlayedState, { token: TOKEN, episodeId: a.episodeIds[0]!, played: true, at: syd(2025, 10, 14, 9) });

    const s = await t.query(api.stats.summary, { token: TOKEN, period: "week", anchorDay: "2025-10-15" });
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
    const s = await t.query(api.stats.summary, { token: TOKEN, period: "month", anchorDay: "2025-10-01" });
    expect(s.totals.wall).toBeCloseTo(25 * 60, 6);
    expect(s.totals.sessions).toBe(1);
    expect(s.completion.started).toBe(1);
  });

  test("estimated sessions count in totals and streaks but not the heatmap", async () => {
    const t = setup();
    const a = await seedShow(t, 1);
    await t.run(async (ctx) => {
      await upsertSession(ctx, {
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
    const y = await t.query(api.stats.yearInReview, { token: TOKEN, year: 2025 });
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
    const y = await t.query(api.stats.yearInReview, { token: TOKEN, year: 2025 });
    expect(y.topShows).toEqual([]);
    expect(y.topEpisode).toBeNull();
    expect(y.firstEpisode).toBeNull();
    expect(y.totals.wall).toBe(1800);
    const withPrivate = await t.query(api.stats.yearInReview, { token: TOKEN, year: 2025, includePrivate: true });
    expect(withPrivate.topShows).toHaveLength(1);
  });
});
