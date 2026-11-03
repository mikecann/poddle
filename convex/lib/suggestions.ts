import { v, type Infer } from "convex/values";

// The parts of "For you" that need no network or database (suggestionsActions.ts runs them):
// reading Exa's podcast pages and choosing what's worth showing. Exa has no fields for most of this,
// so it comes from the markdown at the top of each episode and show page. docs/decisions.md, 3 Nov 2026.

const DAY = 86_400_000;
/** Mike: "I don't want to listen to podcasts that are super old." */
export const MAX_AGE_MS = 365 * DAY;
/** Under this is mostly news clips and trailers. */
const MIN_SECONDS = 20 * 60;
/** Other apps' AI digests of someone else's episode came up a lot and aren't worth a listen. */
const SUMMARY_SHOW = /summar|transcripted|recap|digest/i;
export const MAX_PICKS = 5;
/** Without this, one big story fills the list (3 of 10 picks were about Elizabeth Holmes in the trial). */
const MAX_PER_SEED = 2;

export const vSuggestion = v.object({
  id: v.string(),
  title: v.string(),
  showTitle: v.string(),
  feedUrl: v.string(),
  appleId: v.optional(v.number()),
  artworkUrl: v.optional(v.string()),
  pubDate: v.number(),
  duration: v.number(),
  /** Why it's here, in words for the row. */
  reason: v.string(),
  /** The show's best place on Apple's top shows, when it's there. */
  chartPosition: v.optional(v.number()),
});
export type Suggestion = Infer<typeof vSuggestion>;

export type Seed = {
  title: string;
  showTitle: string;
  why: "starred" | "listened" | "follows";
};

const field = (text: string, name: string) => text.match(new RegExp(`\\*\\*${name}:\\*\\* (.*)`))?.[1]?.trim();
// Exa's text is cut at a length, which can end it halfway through a link, so the closing bracket is optional.
const plain = (markdown: string) => markdown.replace(/\[([^\]]+)\]\([^)]*\)?/g, "$1").trim();

/** "90:42.000" or "1:30:42.000" to seconds. */
export function parseDuration(text: string | undefined): number | undefined {
  if (!text) return undefined;
  const parts = text.split(":").map(Number);
  if (parts.length < 2 || parts.some(Number.isNaN)) return undefined;
  return parts.reduce((total, part) => total * 60 + part, 0);
}

export type EpisodeHeader = {
  showTitle?: string;
  showUrl?: string;
  pubDate?: number;
  duration?: number;
  language?: string;
  guests: string[];
};

export function parseEpisodeHeader(text: string): EpisodeHeader {
  const podcast = field(text, "Podcast");
  const published = field(text, "Published");
  const pubDate = published ? Date.parse(published) : NaN;
  return {
    showTitle: podcast && plain(podcast),
    showUrl: podcast?.match(/\]\(([^)]+)\)/)?.[1],
    pubDate: Number.isNaN(pubDate) ? undefined : pubDate,
    duration: parseDuration(field(text, "Duration")),
    language: field(text, "Language"),
    guests: plain(field(text, "Guests") ?? "")
      .split(",")
      .map((g) => g.trim())
      .filter(Boolean),
  };
}

/** A show page's links: the feed is how the app opens an episode, the Apple ID how it finds the chart. */
export function parseShowPage(text: string): { feedUrl?: string; appleId?: number } {
  const apple = text.match(/podcasts\.apple\.com\/[^)\s]*id(\d+)/)?.[1];
  return { feedUrl: text.match(/\[RSS feed\]\(([^)]+)\)/)?.[1], appleId: apple ? Number(apple) : undefined };
}

export type Candidate = {
  url: string;
  title: string;
  header: EpisodeHeader;
  artworkUrl?: string;
  seedIndex: number;
  reason: string;
  /** Exa's order for the search that found it, added up if several did. */
  score: number;
};

/** Whether an episode is worth keeping at all, before anything's spent on looking up its show. */
export function isWorthShowing(c: Pick<Candidate, "title" | "header">, seeds: Pick<Seed, "title" | "showTitle">[], now: number): boolean {
  const { showTitle, pubDate, duration, language } = c.header;
  if (!showTitle || pubDate === undefined || duration === undefined) return false;
  if (now - pubDate > MAX_AGE_MS || duration < MIN_SECONDS) return false;
  if (language && language !== "en") return false;
  if (SUMMARY_SHOW.test(showTitle)) return false;
  const title = c.title.toLowerCase();
  // Another show's write-up of what you just heard, or the very episode.
  return !seeds.some((s) => title === s.title.toLowerCase() || (showTitle.toLowerCase() !== s.showTitle.toLowerCase() && title.includes(s.showTitle.toLowerCase())));
}

/**
 * Exa's match first, then newer and more popular shows move up. Popularity only nudges: Apple's
 * top 50 is all there is, and most good matches aren't on it.
 */
export function rankScore(score: number, pubDate: number, chartPosition: number | undefined, now: number): number {
  const age = (now - pubDate) / DAY;
  const fresh = age < 60 ? 1.25 : age < 180 ? 1 : 0.8;
  const popular = chartPosition === undefined ? 1 : 1.5 - (chartPosition - 1) / 100;
  return score * fresh * popular;
}

/** The best few, without letting one seed or one show take over. */
export function choosePicks<T extends { seedIndex: number; showTitle: string; rank: number }>(candidates: T[]): T[] {
  const perSeed = new Map<number, number>();
  const shows = new Set<string>();
  const picks: T[] = [];
  for (const c of [...candidates].sort((a, b) => b.rank - a.rank)) {
    const used = perSeed.get(c.seedIndex) ?? 0;
    const show = c.showTitle.toLowerCase();
    if (used >= MAX_PER_SEED || shows.has(show)) continue;
    perSeed.set(c.seedIndex, used + 1);
    shows.add(show);
    picks.push(c);
    if (picks.length === MAX_PICKS) break;
  }
  return picks;
}

const short = (title: string) => (title.length > 48 ? `${title.slice(0, 47).trimEnd()}…` : title);

export function reasonFor(seed: Seed, guest?: string): string {
  if (guest) return `${guest}, who you heard on ${seed.showTitle}`;
  if (seed.why === "starred") return `Because you starred "${short(seed.title)}"`;
  if (seed.why === "follows") return `Because you follow ${seed.showTitle}`;
  return `Because you heard "${short(seed.title)}"`;
}
