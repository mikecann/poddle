// Display formatting, matching the app's (PoddleKit's Format) where it can.

/** "1h 12m", "38m", "45s". */
export function duration(seconds: number | undefined): string {
  if (seconds === undefined || !Number.isFinite(seconds) || seconds <= 0) return "";
  const s = Math.round(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`;
  if (m > 0) return `${m}m`;
  return `${s}s`;
}

/** Hours and minutes for stats: "6h 12m", "0m". */
export function listened(seconds: number): string {
  return duration(seconds) || "0m";
}

/** "1:02:03", "12:34", "0:05". */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

/** "21 Oct 2026". */
export function date(ms: number | undefined): string {
  if (ms === undefined) return "";
  return new Date(ms).toLocaleDateString("en-AU", { day: "numeric", month: "short", year: "numeric" });
}

/** "Today", "Yesterday", "3 days ago", else the date. */
export function relativeDate(ms: number | undefined, now = Date.now()): string {
  if (ms === undefined) return "";
  const startOfDay = (t: number) => {
    const d = new Date(t);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  };
  const days = Math.round((startOfDay(now) - startOfDay(ms)) / 86_400_000);
  if (days <= 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return `${days} days ago`;
  return date(ms);
}

/**
 * A start time from `?t=`: seconds ("754"), a clock ("12:34", "1:02:03") or
 * YouTube style ("1h2m3s", "90s"). Null if it's none of those.
 */
export function parseStart(raw: string | null | undefined): number | null {
  if (!raw) return null;
  const t = raw.trim();
  if (/^\d+(\.\d+)?$/.test(t)) return Number(t);
  if (/^\d+(:\d{1,2}){1,2}$/.test(t)) return t.split(":").reduce((acc, part) => acc * 60 + Number(part), 0);
  const m = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/.exec(t);
  if (m && (m[1] || m[2] || m[3])) return Number(m[1] ?? 0) * 3600 + Number(m[2] ?? 0) * 60 + Number(m[3] ?? 0);
  return null;
}
