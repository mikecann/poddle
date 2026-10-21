// Pure stats maths. No Convex imports, so it's easy to test.

export const STREAK_MIN_SECONDS = 10 * 60;
export const STARTED_MIN_CONTENT = 5 * 60;

export type SessionLike = {
  startedAt: number;
  endedAt: number;
  contentStart: number;
  contentEnd: number;
  rate: number;
  smartRemovedContent: number;
  utcOffsetMinutes: number;
};

export type Metrics = {
  wall: number;
  content: number;
  speedSaved: number;
  smartSaved: number;
  rateContent: number;
};

/**
 * Spec §2.4: speed saving = content × (1 − 1/rate); Smart Speed saving = removed / rate.
 * Both are wall-clock seconds. Wall time is the measured session length.
 */
export function sessionMetrics(s: SessionLike): Metrics {
  const content = Math.max(0, s.contentEnd - s.contentStart);
  const rate = s.rate > 0 ? s.rate : 1;
  return {
    wall: Math.max(0, (s.endedAt - s.startedAt) / 1000),
    content,
    speedSaved: content * (1 - 1 / rate),
    smartSaved: Math.max(0, s.smartRemovedContent) / rate,
    rateContent: content * rate,
  };
}

export function scaleMetrics(m: Metrics, f: number): Metrics {
  return {
    wall: m.wall * f,
    content: m.content * f,
    speedSaved: m.speedSaved * f,
    smartSaved: m.smartSaved * f,
    rateContent: m.rateContent * f,
  };
}

export type Bucket = {
  day: string; // YYYY-MM-DD local
  month: string; // YYYY-MM local
  hour: number; // 0–23 local
  weekday: number; // 0 = Monday
  fraction: number; // share of the session in this hour
};

/** Split a session across local hour boundaries, proportionally by wall time. */
export function splitIntoHours(startedAt: number, endedAt: number, utcOffsetMinutes: number): Bucket[] {
  const off = utcOffsetMinutes * 60_000;
  const start = startedAt + off;
  const end = Math.max(endedAt, startedAt) + off;
  const total = end - start;
  if (total <= 0) return [{ ...localParts(start), fraction: 1 }];
  const buckets: Bucket[] = [];
  let cursor = start;
  while (cursor < end) {
    const nextHour = Math.floor(cursor / 3_600_000) * 3_600_000 + 3_600_000;
    const segEnd = Math.min(end, nextHour);
    buckets.push({ ...localParts(cursor), fraction: (segEnd - cursor) / total });
    cursor = segEnd;
  }
  return buckets;
}

/** `localMs` is already shifted into local time; read it with UTC getters. */
function localParts(localMs: number): Omit<Bucket, "fraction"> {
  const d = new Date(localMs);
  const day = isoDay(d);
  return {
    day,
    month: day.slice(0, 7),
    hour: d.getUTCHours(),
    weekday: (d.getUTCDay() + 6) % 7,
  };
}

function isoDay(d: Date): string {
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

export function localDay(ms: number, utcOffsetMinutes: number): string {
  return isoDay(new Date(ms + utcOffsetMinutes * 60_000));
}

/** UTC offset of an IANA zone at an instant, in minutes. Falls back to 0. */
export function zoneOffsetMinutes(timeZone: string, ms: number): number {
  try {
    const dtf = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    const parts: Record<string, number> = {};
    for (const p of dtf.formatToParts(new Date(ms))) {
      if (p.type !== "literal") parts[p.type] = Number(p.value);
    }
    const asUtc = Date.UTC(parts.year!, parts.month! - 1, parts.day!, parts.hour! % 24, parts.minute!, parts.second!);
    return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 60_000);
  } catch {
    return 0;
  }
}

// ---- Day strings ----

export function dayToUtcMs(day: string): number {
  const [y, m, d] = day.split("-").map(Number);
  return Date.UTC(y!, (m ?? 1) - 1, d ?? 1);
}

export function addDays(day: string, n: number): string {
  return isoDay(new Date(dayToUtcMs(day) + n * 86_400_000));
}

export function weekdayOf(day: string): number {
  return (new Date(dayToUtcMs(day)).getUTCDay() + 6) % 7;
}

export type Period = "week" | "month" | "year" | "all";

/** Inclusive local-day range for a calendar period containing `anchorDay`. Weeks start Monday. */
export function periodRange(period: Period, anchorDay: string): { startDay: string; endDay: string } {
  switch (period) {
    case "week": {
      const start = addDays(anchorDay, -weekdayOf(anchorDay));
      return { startDay: start, endDay: addDays(start, 6) };
    }
    case "month": {
      const [y, m] = anchorDay.split("-").map(Number);
      const last = new Date(Date.UTC(y!, m!, 0)).getUTCDate();
      return { startDay: `${y}-${pad(m!)}-01`, endDay: `${y}-${pad(m!)}-${pad(last)}` };
    }
    case "year": {
      const y = anchorDay.slice(0, 4);
      return { startDay: `${y}-01-01`, endDay: `${y}-12-31` };
    }
    case "all":
      return { startDay: "0000-01-01", endDay: "9999-12-31" };
  }
}

// ---- Streaks ----

export type Streak = { length: number; startDay?: string; endDay?: string };

/** Longest run of consecutive days with at least 10 min listening. `days` need not be sorted. */
export function longestStreak(days: { day: string; wall: number }[]): Streak {
  const qualifying = days
    .filter((d) => d.wall >= STREAK_MIN_SECONDS)
    .map((d) => d.day)
    .sort();
  let best: Streak = { length: 0 };
  let runStart: string | undefined;
  let prev: string | undefined;
  let len = 0;
  for (const day of qualifying) {
    if (prev && addDays(prev, 1) === day) {
      len += 1;
    } else {
      runStart = day;
      len = 1;
    }
    if (len > best.length) best = { length: len, startDay: runStart, endDay: day };
    prev = day;
  }
  return best;
}

/** The run ending today, or yesterday if today hasn't hit 10 min yet. */
export function currentStreak(days: { day: string; wall: number }[], today: string): Streak {
  const set = new Set(days.filter((d) => d.wall >= STREAK_MIN_SECONDS).map((d) => d.day));
  let end = set.has(today) ? today : addDays(today, -1);
  if (!set.has(end)) return { length: 0 };
  let start = end;
  let len = 1;
  while (set.has(addDays(start, -1))) {
    start = addDays(start, -1);
    len += 1;
  }
  return { length: len, startDay: start, endDay: end };
}

/** "Night owl: 41% after 9 pm" and friends, from a Monday-first 7×24 heatmap. */
export function listeningPersonality(heatmap: number[]): { key: string; label: string; percent: number } | null {
  const total = heatmap.reduce((a, b) => a + b, 0);
  if (total <= 0) return null;
  const hourShare = (pred: (h: number, wd: number) => boolean) => {
    let sum = 0;
    heatmap.forEach((v, i) => {
      if (pred(i % 24, Math.floor(i / 24))) sum += v;
    });
    return sum / total;
  };
  const candidates = [
    { key: "nightOwl", label: "Night owl", detail: "after 9 pm", share: hourShare((h) => h >= 21 || h < 3), threshold: 0.3 },
    { key: "earlyBird", label: "Early bird", detail: "before 8 am", share: hourShare((h) => h >= 4 && h < 8), threshold: 0.3 },
    {
      key: "commuter",
      label: "Commuter",
      detail: "on weekday commutes",
      share: hourShare((h, wd) => wd < 5 && ((h >= 7 && h < 9) || (h >= 17 && h < 19))),
      threshold: 0.35,
    },
    { key: "weekender", label: "Weekend warrior", detail: "at weekends", share: hourShare((_h, wd) => wd >= 5), threshold: 0.45 },
  ];
  const best = candidates
    .map((c) => ({ ...c, score: c.share / c.threshold }))
    .sort((a, b) => b.score - a.score)[0]!;
  if (best.score >= 1) {
    const percent = Math.round(best.share * 100);
    return { key: best.key, label: `${best.label}: ${percent}% ${best.detail}`, percent };
  }
  const daytime = hourShare((h) => h >= 9 && h < 17);
  return { key: "allDay", label: `All-day listener: ${Math.round(daytime * 100)}% between 9 and 5`, percent: Math.round(daytime * 100) };
}
