import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { userQuery, type UserQueryCtx as QueryCtx } from "./lib/auth";
import { showCache } from "./lib/library";
import { podcastSummary } from "./lib/rows";
import { resolveGlobalSettings } from "./lib/settings";
import { globalSettingsDoc } from "./lib/settingsDb";
import {
  addDays,
  currentStreak,
  dayToUtcMs,
  listeningPersonality,
  localDay,
  longestStreak,
  type Period,
  periodRange,
  sessionMetrics,
  weekdayOf,
  zoneOffsetMinutes,
} from "./lib/statsMath";
import { vPodcastSummary } from "./lib/validators";

// Your stats screens (spec §2.9) and year in review. Reads the rollups kept by
// lib/rollups.ts; only "top episodes" for a bounded period reads raw sessions.
// All seconds are wall-clock unless named `content`.

const vPeriod = v.union(v.literal("week"), v.literal("month"), v.literal("year"), v.literal("all"));
const vStreak = v.object({ length: v.number(), startDay: v.optional(v.string()), endDay: v.optional(v.string()) });
const vTotals = v.object({
  wall: v.number(),
  content: v.number(),
  speedSaved: v.number(),
  smartSaved: v.number(),
  timeSaved: v.number(),
  estimatedWall: v.number(),
  sessions: v.number(),
  /** Content-weighted. Null if nothing was played. */
  averageSpeed: v.union(v.number(), v.null()),
});
const vTopShow = v.object({ podcast: vPodcastSummary, wall: v.number(), content: v.number(), sessions: v.number() });
const vTopEpisode = v.object({
  episodeId: v.id("episodes"),
  title: v.string(),
  artworkUrl: v.optional(v.string()),
  podcast: vPodcastSummary,
  wall: v.number(),
  sessions: v.number(),
  starred: v.boolean(),
});
const vSummary = v.object({
  period: vPeriod,
  startDay: v.string(),
  endDay: v.string(),
  totals: vTotals,
  completion: v.object({ started: v.number(), completed: v.number(), rate: v.union(v.number(), v.null()) }),
  topShows: v.array(vTopShow),
  topEpisodes: v.array(vTopEpisode),
  longestStreak: vStreak,
  currentStreak: vStreak,
  /** 7 × 24 live wall seconds, Monday first: index = weekday * 24 + hour. */
  heatmap: v.array(v.number()),
  busiestDay: v.union(v.object({ day: v.string(), wall: v.number() }), v.null()),
  busiestMonth: v.union(v.object({ month: v.string(), wall: v.number() }), v.null()),
  /** Per-day wall seconds (week, month, year) for charts. */
  days: v.array(v.object({ day: v.string(), wall: v.number() })),
  /** Per-month wall seconds (year, all) for charts. */
  months: v.array(v.object({ month: v.string(), wall: v.number() })),
  includesEstimated: v.boolean(),
});

type Totalish = Pick<Doc<"statsDays">, "wall" | "content" | "speedSaved" | "smartSaved" | "rateContent" | "estimatedWall" | "sessions" | "episodesStarted" | "episodesCompleted">;

function sumTotals(rows: Totalish[]) {
  const t = { wall: 0, content: 0, speedSaved: 0, smartSaved: 0, rateContent: 0, estimatedWall: 0, sessions: 0, started: 0, completed: 0 };
  for (const r of rows) {
    t.wall += r.wall;
    t.content += r.content;
    t.speedSaved += r.speedSaved;
    t.smartSaved += r.smartSaved;
    t.rateContent += r.rateContent;
    t.estimatedWall += r.estimatedWall;
    t.sessions += r.sessions;
    t.started += r.episodesStarted;
    t.completed += r.episodesCompleted;
  }
  return t;
}

async function todayFor(ctx: QueryCtx): Promise<string> {
  const tz = resolveGlobalSettings(await globalSettingsDoc(ctx)).timeZone;
  const now = Date.now();
  return localDay(now, zoneOffsetMinutes(tz, now));
}

async function topShows(ctx: QueryCtx, period: Period, startDay: string, endDay: string, limit: number) {
  const byShow = new Map<Id<"podcasts">, { wall: number; content: number; sessions: number }>();
  const rows =
    period === "week"
      ? await ctx.db
          .query("statsShowDays")
          .withIndex("by_user_day_podcast", (q) => q.eq("userId", ctx.userId).gte("day", startDay).lte("day", endDay))
          .collect()
      : await ctx.db
          .query("statsShowMonths")
          .withIndex("by_user_month_podcast", (q) =>
            q.eq("userId", ctx.userId).gte("month", startDay.slice(0, 7)).lte("month", endDay.slice(0, 7)),
          )
          .collect();
  for (const r of rows) {
    const acc = byShow.get(r.podcastId) ?? { wall: 0, content: 0, sessions: 0 };
    acc.wall += r.wall;
    acc.content += r.content;
    acc.sessions += r.sessions;
    byShow.set(r.podcastId, acc);
  }
  const ranked = [...byShow.entries()].filter(([, a]) => a.wall > 0.5).sort((a, b) => b[1].wall - a[1].wall);
  const out = [];
  const show = showCache(ctx);
  for (const [podcastId, acc] of ranked) {
    if (out.length >= limit) break;
    const podcast = await show(podcastId);
    if (podcast) out.push({ podcast: podcastSummary(podcast), ...acc });
  }
  return out;
}

const MAX_SESSIONS_READ = 8000;

async function sessionsInRange(ctx: QueryCtx, startDay: string, endDay: string) {
  const pad = 14 * 3600_000;
  const sessions = await ctx.db
    .query("listeningSessions")
    .withIndex("by_user_startedAt", (q) =>
      q.eq("userId", ctx.userId).gte("startedAt", dayToUtcMs(startDay) - pad).lt("startedAt", dayToUtcMs(addDays(endDay, 1)) + pad),
    )
    .take(MAX_SESSIONS_READ);
  return sessions.filter((s) => {
    const d = localDay(s.startedAt, s.utcOffsetMinutes);
    return d >= startDay && d <= endDay;
  });
}

async function topEpisodes(ctx: QueryCtx, period: Period, startDay: string, endDay: string, limit: number) {
  let ranked: { episodeId: Id<"episodes">; wall: number; sessions: number }[];
  if (period === "all") {
    const totals = await ctx.db
      .query("episodeTotals")
      .withIndex("by_user_wall", (q) => q.eq("userId", ctx.userId))
      .order("desc")
      .take(limit * 2);
    ranked = totals.map((t) => ({ episodeId: t.episodeId, wall: t.wall, sessions: t.sessions }));
  } else {
    const byEpisode = new Map<Id<"episodes">, { wall: number; sessions: number }>();
    for (const s of await sessionsInRange(ctx, startDay, endDay)) {
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
      .withIndex("by_user_episode", (q) => q.eq("userId", ctx.userId).eq("episodeId", r.episodeId))
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
  // Wall time first; stars break near-ties (within a minute).
  rows.sort((a, b) => (Math.abs(b.wall - a.wall) < 60 ? Number(b.starred) - Number(a.starred) : 0) || b.wall - a.wall);
  return rows.slice(0, limit);
}

async function currentStreakFrom(ctx: QueryCtx, today: string) {
  const recent = await ctx.db
    .query("statsDays")
    .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).lte("day", today))
    .order("desc")
    .take(400);
  return currentStreak(recent, today);
}

export async function computeSummary(ctx: QueryCtx, period: Period, anchorDay: string | undefined, limit = 10) {
  const today = await todayFor(ctx);
  const { startDay, endDay } = periodRange(period, anchorDay ?? today);
  const days = await ctx.db
    .query("statsDays")
    .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).gte("day", startDay).lte("day", endDay))
    .collect();
  const months = await ctx.db
    .query("statsMonths")
    .withIndex("by_user_month", (q) => q.eq("userId", ctx.userId).gte("month", startDay.slice(0, 7)).lte("month", endDay.slice(0, 7)))
    .collect();
  const t = sumTotals(period === "week" || period === "month" ? days : months);

  let heatmap = new Array<number>(7 * 24).fill(0);
  if (period === "week" || period === "month") {
    for (const d of days) {
      const wd = weekdayOf(d.day);
      d.liveHours.forEach((secs, h) => (heatmap[wd * 24 + h]! += secs));
    }
  } else {
    for (const m of months) heatmap = heatmap.map((x, i) => x + (m.heatmap[i] ?? 0));
  }

  const busiestDay = days.reduce<{ day: string; wall: number } | null>(
    (best, d) => (d.wall > (best?.wall ?? 0) ? { day: d.day, wall: d.wall } : best),
    null,
  );
  const busiestMonth =
    period === "year" || period === "all"
      ? months.reduce<{ month: string; wall: number } | null>(
          (best, m) => (m.wall > (best?.wall ?? 0) ? { month: m.month, wall: m.wall } : best),
          null,
        )
      : null;

  return {
    period,
    startDay,
    endDay,
    totals: {
      wall: t.wall,
      content: t.content,
      speedSaved: t.speedSaved,
      smartSaved: t.smartSaved,
      timeSaved: t.speedSaved + t.smartSaved,
      estimatedWall: t.estimatedWall,
      sessions: t.sessions,
      averageSpeed: t.content > 0 ? t.rateContent / t.content : null,
    },
    completion: { started: t.started, completed: t.completed, rate: t.started > 0 ? Math.min(1, t.completed / t.started) : null },
    topShows: await topShows(ctx, period, startDay, endDay, limit),
    topEpisodes: await topEpisodes(ctx, period, startDay, endDay, limit),
    longestStreak: longestStreak(days),
    currentStreak: await currentStreakFrom(ctx, today),
    heatmap,
    busiestDay,
    busiestMonth,
    days: period === "all" ? [] : days.map((d) => ({ day: d.day, wall: d.wall })),
    months: period === "year" || period === "all" ? months.map((m) => ({ month: m.month, wall: m.wall })) : [],
    includesEstimated: t.estimatedWall > 0,
  };
}

/**
 * Stats for a calendar period containing `anchorDay` (local YYYY-MM-DD,
 * default today in the global time zone). Weeks start on Monday.
 */
export const summary = userQuery({
  args: { period: vPeriod, anchorDay: v.optional(v.string()) },
  returns: vSummary,
  handler: async (ctx, { period, anchorDay }) => await computeSummary(ctx, period, anchorDay),
});

/** One show's all-time and per-month listening. */
export const forPodcast = userQuery({
  args: { podcastId: v.id("podcasts") },
  returns: v.object({
    wall: v.number(),
    content: v.number(),
    timeSaved: v.number(),
    sessions: v.number(),
    months: v.array(v.object({ month: v.string(), wall: v.number() })),
  }),
  handler: async (ctx, { podcastId }) => {
    const months = await ctx.db
      .query("statsShowMonths")
      .withIndex("by_user_podcast_month", (q) => q.eq("userId", ctx.userId).eq("podcastId", podcastId))
      .collect();
    return {
      wall: months.reduce((a, m) => a + m.wall, 0),
      content: months.reduce((a, m) => a + m.content, 0),
      timeSaved: months.reduce((a, m) => a + m.speedSaved + m.smartSaved, 0),
      sessions: months.reduce((a, m) => a + m.sessions, 0),
      months: months.map((m) => ({ month: m.month, wall: m.wall })),
    };
  },
});

const vEpisodeRef = v.object({
  episodeId: v.id("episodes"),
  title: v.string(),
  podcast: vPodcastSummary,
  at: v.number(),
});

/**
 * Everything the year-in-review cards need. Private shows are left out of the
 * show lists unless `includePrivate` is true.
 */
export const yearInReview = userQuery({
  args: { year: v.number(), includePrivate: v.optional(v.boolean()) },
  returns: v.object({
    year: v.number(),
    /** 1 December of that year (local), when the app should start offering it. */
    availableFrom: v.string(),
    totals: vTotals,
    episodesCompleted: v.number(),
    topShows: v.array(vTopShow),
    topEpisode: v.union(vTopEpisode, v.null()),
    longestStreak: vStreak,
    biggestDay: v.union(v.object({ day: v.string(), wall: v.number() }), v.null()),
    busiestMonth: v.union(v.object({ month: v.string(), wall: v.number() }), v.null()),
    personality: v.union(v.object({ key: v.string(), label: v.string(), percent: v.number() }), v.null()),
    firstEpisode: v.union(vEpisodeRef, v.null()),
    lastEpisode: v.union(vEpisodeRef, v.null()),
    newShows: v.array(vPodcastSummary),
    heatmap: v.array(v.number()),
    months: v.array(v.object({ month: v.string(), wall: v.number() })),
    includesEstimated: v.boolean(),
    /** When the most recent import finished, for "includes estimated history before …". */
    estimatedBefore: v.union(v.number(), v.null()),
  }),
  handler: async (ctx, { year, includePrivate }) => {
    const anchor = `${year}-06-01`;
    const s = await computeSummary(ctx, "year", anchor, 30);
    const keep = (p: { isPrivate: boolean }) => includePrivate || !p.isPrivate;

    const yearSessions = await sessionsInRange(ctx, s.startDay, s.endDay);
    const show = showCache(ctx);
    const ref = async (sess: Doc<"listeningSessions"> | undefined) => {
      if (!sess) return null;
      const episode = await ctx.db.get(sess.episodeId);
      const podcast = episode && (await show(episode.podcastId));
      if (!episode || !podcast) return null;
      return { episodeId: episode._id, title: episode.title, podcast: podcastSummary(podcast), at: sess.startedAt };
    };
    const firstVisible = async (list: Doc<"listeningSessions">[]) => {
      for (const sess of list) {
        const p = await show(sess.podcastId);
        if (p && keep(p)) return sess;
      }
      return undefined;
    };

    const start = dayToUtcMs(s.startDay) - 14 * 3600_000;
    const end = dayToUtcMs(addDays(s.endDay, 1)) + 14 * 3600_000;
    const addedSubs = await ctx.db
      .query("subscriptions")
      .withIndex("by_user_subscribedAt", (q) => q.eq("userId", ctx.userId).gte("subscribedAt", start).lt("subscribedAt", end))
      .collect();
    const added = [];
    for (const sub of addedSubs) {
      const p = await show(sub.podcastId);
      if (p) added.push(p);
    }
    const lastImport = await ctx.db
      .query("importBatches")
      .withIndex("by_user_startedAt", (q) => q.eq("userId", ctx.userId))
      .order("desc")
      .first();

    return {
      year,
      availableFrom: `${year}-12-01`,
      totals: s.totals,
      episodesCompleted: s.completion.completed,
      topShows: s.topShows.filter((t) => keep(t.podcast)).slice(0, 5),
      topEpisode: s.topEpisodes.find((e) => keep(e.podcast)) ?? null,
      longestStreak: s.longestStreak,
      biggestDay: s.busiestDay,
      busiestMonth: s.busiestMonth,
      personality: listeningPersonality(s.heatmap),
      firstEpisode: await ref(await firstVisible(yearSessions)),
      lastEpisode: await ref(await firstVisible([...yearSessions].reverse())),
      newShows: added.filter((p) => keep(p)).map(podcastSummary),
      heatmap: s.heatmap,
      months: s.months,
      includesEstimated: s.includesEstimated,
      estimatedBefore: s.includesEstimated ? (lastImport?.finishedAt ?? lastImport?.startedAt ?? null) : null,
    };
  },
});
