import type { Doc, Id } from "../_generated/dataModel";
import type { UserMutationCtx as MutationCtx } from "./auth";
import {
  type Metrics,
  type Streak,
  STARTED_MIN_CONTENT,
  STREAK_MIN_SECONDS,
  addDays,
  longestStreak,
  scaleMetrics,
  sessionMetrics,
  splitIntoHours,
} from "./statsMath";

// Stats rollups for the person in `ctx.userId`, kept in step with every listening-session write so stat queries
// read a few hundred small docs instead of a year of sessions.

export type RollupSession = Pick<
  Doc<"listeningSessions">,
  | "episodeId"
  | "podcastId"
  | "startedAt"
  | "endedAt"
  | "contentStart"
  | "contentEnd"
  | "rate"
  | "smartRemovedContent"
  | "utcOffsetMinutes"
  | "isEstimated"
>;

type Acc = Metrics & { estimatedWall: number; sessions: number; started: number; liveHours?: number[]; heatmap?: number[] };

const zeroAcc = (): Acc => ({
  wall: 0,
  content: 0,
  speedSaved: 0,
  smartSaved: 0,
  rateContent: 0,
  estimatedWall: 0,
  sessions: 0,
  started: 0,
});

function addInto(acc: Acc, m: Metrics, sign: number) {
  acc.wall += sign * m.wall;
  acc.content += sign * m.content;
  acc.speedSaved += sign * m.speedSaved;
  acc.smartSaved += sign * m.smartSaved;
  acc.rateContent += sign * m.rateContent;
}

const clean = (x: number) => (Math.abs(x) < 1e-6 ? 0 : x);

export async function applySessionToRollups(
  ctx: MutationCtx,
  s: RollupSession,
  sign: 1 | -1,
  opts: { deferStreak?: boolean; deferStreakInto?: Map<string, boolean> } = {},
): Promise<void> {
  const metrics = sessionMetrics(s);
  const buckets = splitIntoHours(s.startedAt, s.endedAt, s.utcOffsetMinutes);
  const days = new Map<string, Acc>();
  const months = new Map<string, Acc>();
  const get = (map: Map<string, Acc>, key: string) => {
    let acc = map.get(key);
    if (!acc) map.set(key, (acc = zeroAcc()));
    return acc;
  };

  for (const b of buckets) {
    const part = scaleMetrics(metrics, b.fraction);
    const day = get(days, b.day);
    const month = get(months, b.month);
    for (const acc of [day, month]) {
      addInto(acc, part, sign);
      if (s.isEstimated) acc.estimatedWall += sign * part.wall;
    }
    if (!s.isEstimated) {
      day.liveHours ??= new Array(24).fill(0);
      day.liveHours[b.hour]! += sign * part.wall;
      month.heatmap ??= new Array(7 * 24).fill(0);
      month.heatmap[b.weekday * 24 + b.hour]! += sign * part.wall;
    }
  }
  const first = buckets[0]!;
  get(days, first.day).sessions += sign;
  get(months, first.month).sessions += sign;

  const maintainExtended = await ensureExtendedRollupsReady(ctx, first.day.slice(0, 4));

  // An episode counts as started once 5 min of content has been heard in total.
  const startedDelta = await applyEpisodeTotals(ctx, s, metrics, sign);
  get(days, first.day).started += startedDelta;
  get(months, first.month).started += startedDelta;

  if (maintainExtended) {
    await applyEpisodeYearTotals(ctx, first.day.slice(0, 4), s, metrics, sign);
    await bumpShowTotal(ctx, s.podcastId, metrics, sign);
  }

  const defer = opts.deferStreak || opts.deferStreakInto !== undefined;
  const beforeQualifies = opts.deferStreakInto ?? new Map<string, boolean>();
  for (const [day, acc] of days) {
    const beforeWall = await bumpDay(ctx, day, acc);
    if (opts.deferStreakInto) {
      if (!opts.deferStreakInto.has(day)) opts.deferStreakInto.set(day, beforeWall >= STREAK_MIN_SECONDS);
    } else if (!opts.deferStreak) {
      beforeQualifies.set(day, beforeWall >= STREAK_MIN_SECONDS);
    }
    await bumpShowDay(ctx, day, s.podcastId, acc);
  }
  for (const [month, acc] of months) {
    await bumpMonth(ctx, month, acc);
    await bumpShowMonth(ctx, month, s.podcastId, acc);
  }
  if (!defer && maintainExtended) {
    await syncStreakAfterChanges(ctx, beforeQualifies);
  }
}

/**
 * Replace an existing session's contribution to rollups, checking streak threshold
 * crossings only across the net day change (never on the transient -1 state).
 */
export async function replaceSessionInRollups(
  ctx: MutationCtx,
  existing: RollupSession,
  next: RollupSession,
  opts: { deferStreakInto?: Map<string, boolean> } = {},
): Promise<void> {
  const touchedDays = new Set<string>([
    ...splitIntoHours(existing.startedAt, existing.endedAt, existing.utcOffsetMinutes).map((b) => b.day),
    ...splitIntoHours(next.startedAt, next.endedAt, next.utcOffsetMinutes).map((b) => b.day),
  ]);
  const beforeQualifies = opts.deferStreakInto ?? new Map<string, boolean>();
  for (const day of touchedDays) {
    if (opts.deferStreakInto && beforeQualifies.has(day)) continue;
    const doc = await ctx.db
      .query("statsDays")
      .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).eq("day", day))
      .unique();
    beforeQualifies.set(day, (doc?.wall ?? 0) >= STREAK_MIN_SECONDS);
  }
  await applySessionToRollups(ctx, existing, -1, { deferStreak: true });
  await applySessionToRollups(ctx, next, 1, { deferStreak: true });
  if (!opts.deferStreakInto) {
    await syncStreakAfterChanges(ctx, beforeQualifies);
  }
}

/**
 * Whether extended rollups (`statsEpisodeYears`, `statsShowTotals`, `statsAllTime`)
 * should be maintained for this user. New users with no prior session history start ready
 * immediately (checking `episodeTotals`, never `statsDays`, because `setPlayed` writes a
 * completion-only `statsDays` row before an Overcast import records its first session);
 * existing users stay on the fallback path until `migrations:backfillStatsRollups`
 * marks them ready, so partial pre-backfill rows never shadow historical data.
 */
async function ensureExtendedRollupsReady(ctx: MutationCtx, touchedYear: string): Promise<boolean> {
  const allTime = await ctx.db
    .query("statsAllTime")
    .withIndex("by_user", (q) => q.eq("userId", ctx.userId))
    .unique();
  if (allTime) {
    if (!allTime.rollupsReady) {
      const existing = allTime.backfillDirtyYears ?? [];
      if (!existing.includes(touchedYear)) {
        await ctx.db.patch("statsAllTime", allTime._id, {
          backfillDirtyYears: [...existing, touchedYear],
        });
      }
    }
    return allTime.rollupsReady;
  }
  const hasPriorSessions =
    (await ctx.db
      .query("episodeTotals")
      .withIndex("by_user_episode", (q) => q.eq("userId", ctx.userId))
      .first()) !== null;
  if (hasPriorSessions) return false;
  await ctx.db.insert("statsAllTime", {
    userId: ctx.userId,
    longestStreakLength: 0,
    rollupsReady: true,
  });
  return true;
}

async function applyEpisodeYearTotals(ctx: MutationCtx, year: string, s: RollupSession, m: Metrics, sign: number): Promise<void> {
  const existing = await ctx.db
    .query("statsEpisodeYears")
    .withIndex("by_user_year_episode", (q) => q.eq("userId", ctx.userId).eq("year", year).eq("episodeId", s.episodeId))
    .unique();
  const next = {
    wall: clean((existing?.wall ?? 0) + sign * m.wall),
    content: clean((existing?.content ?? 0) + sign * m.content),
    sessions: (existing?.sessions ?? 0) + sign,
  };
  if (existing) await ctx.db.patch("statsEpisodeYears", existing._id, next);
  else await ctx.db.insert("statsEpisodeYears", { userId: ctx.userId, year, episodeId: s.episodeId, podcastId: s.podcastId, ...next });
}

async function bumpShowTotal(ctx: MutationCtx, podcastId: Id<"podcasts">, m: Metrics, sign: number): Promise<void> {
  const doc = await ctx.db
    .query("statsShowTotals")
    .withIndex("by_user_podcast", (q) => q.eq("userId", ctx.userId).eq("podcastId", podcastId))
    .unique();
  const next = {
    wall: clean((doc?.wall ?? 0) + sign * m.wall),
    content: clean((doc?.content ?? 0) + sign * m.content),
    speedSaved: clean((doc?.speedSaved ?? 0) + sign * m.speedSaved),
    smartSaved: clean((doc?.smartSaved ?? 0) + sign * m.smartSaved),
    sessions: (doc?.sessions ?? 0) + sign,
  };
  if (doc) await ctx.db.patch("statsShowTotals", doc._id, next);
  else await ctx.db.insert("statsShowTotals", { userId: ctx.userId, podcastId, ...next });
}

/** Measure the contiguous run of qualifying days containing `day`. */
async function streakAroundDay(ctx: MutationCtx, day: string): Promise<Streak> {
  let start = day;
  let need = addDays(day, -1);
  for await (const d of ctx.db
    .query("statsDays")
    .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).lte("day", need))
    .order("desc")) {
    if (d.day !== need || d.wall < STREAK_MIN_SECONDS) break;
    start = d.day;
    need = addDays(need, -1);
  }
  let end = day;
  need = addDays(day, 1);
  for await (const d of ctx.db
    .query("statsDays")
    .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).gte("day", need))
    .order("asc")) {
    if (d.day !== need || d.wall < STREAK_MIN_SECONDS) break;
    end = d.day;
    need = addDays(need, 1);
  }
  let length = 1;
  let cursor = start;
  while (cursor < end) {
    cursor = addDays(cursor, 1);
    length++;
  }
  return { length, startDay: start, endDay: end };
}

function isBetterStreak(candidate: Streak, current: Streak): boolean {
  if (candidate.length !== current.length) return candidate.length > current.length;
  if (candidate.length === 0) return false;
  return Boolean(candidate.startDay && (!current.startDay || candidate.startDay < current.startDay));
}

export async function syncStreakAfterChanges(ctx: MutationCtx, beforeQualifies: Map<string, boolean>): Promise<void> {
  const allTime = await ctx.db
    .query("statsAllTime")
    .withIndex("by_user", (q) => q.eq("userId", ctx.userId))
    .unique();
  if (!allTime?.rollupsReady) return;

  let anyDropped = false;
  const addedDays: string[] = [];
  for (const [day, wasQualifying] of beforeQualifies) {
    const doc = await ctx.db
      .query("statsDays")
      .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).eq("day", day))
      .unique();
    const isQualifying = (doc?.wall ?? 0) >= STREAK_MIN_SECONDS;
    if (wasQualifying === isQualifying) continue;
    if (wasQualifying) anyDropped = true;
    else addedDays.push(day);
  }
  if (!anyDropped && addedDays.length === 0) return;

  let best: Streak = {
    length: allTime.longestStreakLength,
    startDay: allTime.longestStreakStartDay,
    endDay: allTime.longestStreakEndDay,
  };
  let changed = false;
  if (anyDropped) {
    const allDays: { day: string; wall: number }[] = [];
    for await (const d of ctx.db.query("statsDays").withIndex("by_user_day", (q) => q.eq("userId", ctx.userId))) {
      allDays.push({ day: d.day, wall: d.wall });
    }
    const recomputed = longestStreak(allDays);
    changed =
      recomputed.length !== best.length ||
      recomputed.startDay !== best.startDay ||
      recomputed.endDay !== best.endDay;
    best = recomputed;
  } else {
    // Skip days already covered by an earlier contiguous run so batch imports walk each run once.
    const covered: { start: string; end: string }[] = [];
    for (const day of addedDays) {
      if (covered.some((r) => day >= r.start && day <= r.end)) continue;
      const candidate = await streakAroundDay(ctx, day);
      if (candidate.startDay && candidate.endDay) {
        covered.push({ start: candidate.startDay, end: candidate.endDay });
      }
      if (isBetterStreak(candidate, best)) {
        best = candidate;
        changed = true;
      }
    }
  }
  if (changed) {
    await ctx.db.patch("statsAllTime", allTime._id, {
      longestStreakLength: best.length,
      longestStreakStartDay: best.startDay,
      longestStreakEndDay: best.endDay,
    });
  }
}

async function applyEpisodeTotals(ctx: MutationCtx, s: RollupSession, m: Metrics, sign: number): Promise<number> {
  const existing = await ctx.db
    .query("episodeTotals")
    .withIndex("by_user_episode", (q) => q.eq("userId", ctx.userId).eq("episodeId", s.episodeId))
    .unique();
  const before = existing?.content ?? 0;
  const after = clean(before + sign * m.content);
  const next = {
    wall: clean((existing?.wall ?? 0) + sign * m.wall),
    content: after,
    sessions: (existing?.sessions ?? 0) + sign,
  };
  if (existing) await ctx.db.patch("episodeTotals", existing._id, next);
  else await ctx.db.insert("episodeTotals", { userId: ctx.userId, episodeId: s.episodeId, podcastId: s.podcastId, ...next });
  if (before < STARTED_MIN_CONTENT && after >= STARTED_MIN_CONTENT) return 1;
  if (before >= STARTED_MIN_CONTENT && after < STARTED_MIN_CONTENT) return -1;
  return 0;
}

const addArrays = (a: number[], b: number[] | undefined) => (b ? a.map((x, i) => clean(x + (b[i] ?? 0))) : a);

async function bumpDay(ctx: MutationCtx, day: string, acc: Acc): Promise<number> {
  const doc = await ctx.db
    .query("statsDays")
    .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).eq("day", day))
    .unique();
  const base = doc ?? emptyDay(day);
  const next = {
    ...totals(base, acc),
    liveHours: addArrays(base.liveHours, acc.liveHours),
  };
  if (doc) await ctx.db.patch("statsDays", doc._id, next);
  else await ctx.db.insert("statsDays", { ...base, ...next, userId: ctx.userId });
  return doc?.wall ?? 0;
}

async function bumpMonth(ctx: MutationCtx, month: string, acc: Acc) {
  const doc = await ctx.db
    .query("statsMonths")
    .withIndex("by_user_month", (q) => q.eq("userId", ctx.userId).eq("month", month))
    .unique();
  const base = doc ?? emptyMonth(month);
  const next = { ...totals(base, acc), heatmap: addArrays(base.heatmap, acc.heatmap) };
  if (doc) await ctx.db.patch("statsMonths", doc._id, next);
  else await ctx.db.insert("statsMonths", { ...base, ...next, userId: ctx.userId });
}

async function bumpShowDay(ctx: MutationCtx, day: string, podcastId: Id<"podcasts">, acc: Acc) {
  const doc = await ctx.db
    .query("statsShowDays")
    .withIndex("by_user_day_podcast", (q) => q.eq("userId", ctx.userId).eq("day", day).eq("podcastId", podcastId))
    .unique();
  const next = showTotals(doc, acc);
  if (doc) await ctx.db.patch("statsShowDays", doc._id, next);
  else await ctx.db.insert("statsShowDays", { userId: ctx.userId, day, podcastId, ...next });
}

async function bumpShowMonth(ctx: MutationCtx, month: string, podcastId: Id<"podcasts">, acc: Acc) {
  const doc = await ctx.db
    .query("statsShowMonths")
    .withIndex("by_user_month_podcast", (q) => q.eq("userId", ctx.userId).eq("month", month).eq("podcastId", podcastId))
    .unique();
  const next = showTotals(doc, acc);
  if (doc) await ctx.db.patch("statsShowMonths", doc._id, next);
  else await ctx.db.insert("statsShowMonths", { userId: ctx.userId, month, podcastId, ...next });
}

type Totals = Pick<
  Doc<"statsDays">,
  "wall" | "content" | "speedSaved" | "smartSaved" | "rateContent" | "estimatedWall" | "sessions" | "episodesStarted" | "episodesCompleted"
>;

function totals(base: Totals, acc: Acc): Totals {
  return {
    wall: clean(base.wall + acc.wall),
    content: clean(base.content + acc.content),
    speedSaved: clean(base.speedSaved + acc.speedSaved),
    smartSaved: clean(base.smartSaved + acc.smartSaved),
    rateContent: clean(base.rateContent + acc.rateContent),
    estimatedWall: clean(base.estimatedWall + acc.estimatedWall),
    sessions: base.sessions + acc.sessions,
    episodesStarted: base.episodesStarted + acc.started,
    episodesCompleted: base.episodesCompleted,
  };
}

function showTotals(base: Pick<Doc<"statsShowDays">, "wall" | "content" | "speedSaved" | "smartSaved" | "sessions"> | null, acc: Acc) {
  return {
    wall: clean((base?.wall ?? 0) + acc.wall),
    content: clean((base?.content ?? 0) + acc.content),
    speedSaved: clean((base?.speedSaved ?? 0) + acc.speedSaved),
    smartSaved: clean((base?.smartSaved ?? 0) + acc.smartSaved),
    sessions: (base?.sessions ?? 0) + acc.sessions,
  };
}

function emptyTotals(): Totals {
  return {
    wall: 0,
    content: 0,
    speedSaved: 0,
    smartSaved: 0,
    rateContent: 0,
    estimatedWall: 0,
    sessions: 0,
    episodesStarted: 0,
    episodesCompleted: 0,
  };
}

const emptyDay = (day: string) => ({ day, ...emptyTotals(), liveHours: new Array<number>(24).fill(0) });
const emptyMonth = (month: string) => ({ month, ...emptyTotals(), heatmap: new Array<number>(7 * 24).fill(0) });

/** Count (or uncount) a completion on the local day it happened. */
export async function applyCompletion(ctx: MutationCtx, day: string, sign: 1 | -1): Promise<void> {
  const dayDoc = await ctx.db
    .query("statsDays")
    .withIndex("by_user_day", (q) => q.eq("userId", ctx.userId).eq("day", day))
    .unique();
  if (dayDoc) await ctx.db.patch("statsDays", dayDoc._id, { episodesCompleted: dayDoc.episodesCompleted + sign });
  else await ctx.db.insert("statsDays", { ...emptyDay(day), episodesCompleted: sign, userId: ctx.userId });

  const month = day.slice(0, 7);
  const monthDoc = await ctx.db
    .query("statsMonths")
    .withIndex("by_user_month", (q) => q.eq("userId", ctx.userId).eq("month", month))
    .unique();
  if (monthDoc) await ctx.db.patch("statsMonths", monthDoc._id, { episodesCompleted: monthDoc.episodesCompleted + sign });
  else await ctx.db.insert("statsMonths", { ...emptyMonth(month), episodesCompleted: sign, userId: ctx.userId });
}
