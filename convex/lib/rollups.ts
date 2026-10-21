import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx } from "../_generated/server";
import {
  type Metrics,
  STARTED_MIN_CONTENT,
  scaleMetrics,
  sessionMetrics,
  splitIntoHours,
} from "./statsMath";

// Stats rollups, kept in step with every listening-session write so stat queries
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

export async function applySessionToRollups(ctx: MutationCtx, s: RollupSession, sign: 1 | -1): Promise<void> {
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

  // An episode counts as started once 5 min of content has been heard in total.
  const startedDelta = await applyEpisodeTotals(ctx, s, metrics, sign);
  get(days, first.day).started += startedDelta;
  get(months, first.month).started += startedDelta;

  for (const [day, acc] of days) {
    await bumpDay(ctx, day, acc);
    await bumpShowDay(ctx, day, s.podcastId, acc);
  }
  for (const [month, acc] of months) {
    await bumpMonth(ctx, month, acc);
    await bumpShowMonth(ctx, month, s.podcastId, acc);
  }
}

async function applyEpisodeTotals(ctx: MutationCtx, s: RollupSession, m: Metrics, sign: number): Promise<number> {
  const existing = await ctx.db
    .query("episodeTotals")
    .withIndex("by_episode", (q) => q.eq("episodeId", s.episodeId))
    .unique();
  const before = existing?.content ?? 0;
  const after = clean(before + sign * m.content);
  const next = {
    wall: clean((existing?.wall ?? 0) + sign * m.wall),
    content: after,
    sessions: (existing?.sessions ?? 0) + sign,
  };
  if (existing) await ctx.db.patch(existing._id, next);
  else await ctx.db.insert("episodeTotals", { episodeId: s.episodeId, podcastId: s.podcastId, ...next });
  if (before < STARTED_MIN_CONTENT && after >= STARTED_MIN_CONTENT) return 1;
  if (before >= STARTED_MIN_CONTENT && after < STARTED_MIN_CONTENT) return -1;
  return 0;
}

const addArrays = (a: number[], b: number[] | undefined) => (b ? a.map((x, i) => clean(x + (b[i] ?? 0))) : a);

async function bumpDay(ctx: MutationCtx, day: string, acc: Acc) {
  const doc = await ctx.db
    .query("statsDays")
    .withIndex("by_day", (q) => q.eq("day", day))
    .unique();
  const base = doc ?? emptyDay(day);
  const next = {
    ...totals(base, acc),
    liveHours: addArrays(base.liveHours, acc.liveHours),
  };
  if (doc) await ctx.db.patch(doc._id, next);
  else await ctx.db.insert("statsDays", { ...base, ...next });
}

async function bumpMonth(ctx: MutationCtx, month: string, acc: Acc) {
  const doc = await ctx.db
    .query("statsMonths")
    .withIndex("by_month", (q) => q.eq("month", month))
    .unique();
  const base = doc ?? emptyMonth(month);
  const next = { ...totals(base, acc), heatmap: addArrays(base.heatmap, acc.heatmap) };
  if (doc) await ctx.db.patch(doc._id, next);
  else await ctx.db.insert("statsMonths", { ...base, ...next });
}

async function bumpShowDay(ctx: MutationCtx, day: string, podcastId: Id<"podcasts">, acc: Acc) {
  const doc = await ctx.db
    .query("statsShowDays")
    .withIndex("by_day_podcast", (q) => q.eq("day", day).eq("podcastId", podcastId))
    .unique();
  const next = showTotals(doc, acc);
  if (doc) await ctx.db.patch(doc._id, next);
  else await ctx.db.insert("statsShowDays", { day, podcastId, ...next });
}

async function bumpShowMonth(ctx: MutationCtx, month: string, podcastId: Id<"podcasts">, acc: Acc) {
  const doc = await ctx.db
    .query("statsShowMonths")
    .withIndex("by_month_podcast", (q) => q.eq("month", month).eq("podcastId", podcastId))
    .unique();
  const next = showTotals(doc, acc);
  if (doc) await ctx.db.patch(doc._id, next);
  else await ctx.db.insert("statsShowMonths", { month, podcastId, ...next });
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
    .withIndex("by_day", (q) => q.eq("day", day))
    .unique();
  if (dayDoc) await ctx.db.patch(dayDoc._id, { episodesCompleted: dayDoc.episodesCompleted + sign });
  else await ctx.db.insert("statsDays", { ...emptyDay(day), episodesCompleted: sign });

  const month = day.slice(0, 7);
  const monthDoc = await ctx.db
    .query("statsMonths")
    .withIndex("by_month", (q) => q.eq("month", month))
    .unique();
  if (monthDoc) await ctx.db.patch(monthDoc._id, { episodesCompleted: monthDoc.episodesCompleted + sign });
  else await ctx.db.insert("statsMonths", { ...emptyMonth(month), episodesCompleted: sign });
}
