"use node";

import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalAction, type ActionCtx } from "./_generated/server";
import { userAction } from "./lib/auth";
import { exaBase } from "./lib/e2e";
import { fetchWithTimeout, USER_AGENT } from "./lib/feedFetch";
import {
  type Candidate,
  choosePicks,
  isWorthShowing,
  parseEpisodeHeader,
  parseShowPage,
  rankScore,
  reasonFor,
  type Seed,
  type Suggestion,
} from "./lib/suggestions";

// The network side of "For you" (suggestions.ts). Exa's podcast index is searched with the person's
// own key; a trial on Mike's history cost about $0.11 a refresh.

const PODCASTS = ["exa.ai/library/podcast"];
/** How many of the best candidates get their show looked up ($0.001 each) to find a feed. */
const SHOWS_TO_RESOLVE = 25;
const GUEST_LOOKUPS = 4;
const MAX_GUESTS = 2;
const CHART_COUNTRIES = ["au", "us"];

// People's keys are their money, so they're kept encrypted: a data export or dashboard look doesn't
// show them. Only these actions can read one. PODDLE_KEY_SECRET is any long random string.
function cipherKey(): Buffer {
  const secret = process.env.PODDLE_KEY_SECRET;
  if (!secret) throw new ConvexError({ code: "unconfigured", message: "Suggestions aren't set up on this server." });
  return createHash("sha256").update(secret).digest();
}

export function encryptKey(plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", cipherKey(), iv);
  const body = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return [iv, cipher.getAuthTag(), body].map((b) => b.toString("base64")).join(".");
}

export function decryptKey(stored: string): string {
  const [iv, tag, body] = stored.split(".").map((p) => Buffer.from(p, "base64"));
  const decipher = createDecipheriv("aes-256-gcm", cipherKey(), iv!);
  decipher.setAuthTag(tag!);
  return Buffer.concat([decipher.update(body!), decipher.final()]).toString("utf8");
}

class ExaError extends Error {}

type ExaResult = { url: string; title?: string; text?: string; image?: string };

async function exa(key: string, path: string, body: unknown): Promise<ExaResult[]> {
  const res = await fetchWithTimeout(
    `${exaBase()}${path}`,
    { method: "POST", headers: { "x-api-key": key, "Content-Type": "application/json", "User-Agent": USER_AGENT }, body: JSON.stringify(body) },
    20_000,
  );
  if (res.status === 401 || res.status === 403) throw new ExaError("Exa didn't accept that key. Check it in Profile.");
  if (res.status === 402 || res.status === 429) throw new ExaError("Your Exa account is out of credits or over its limit.");
  if (!res.ok) throw new ExaError("Exa isn't answering right now. We'll try again tomorrow.");
  return ((await res.json()) as { results?: ExaResult[] }).results ?? [];
}

const search = (key: string, query: string, numResults: number, startPublishedDate?: string) =>
  exa(key, "/search", { query, includeDomains: PODCASTS, numResults, startPublishedDate, contents: { text: { maxCharacters: 500 } } });

/** Apple's top shows, best place across countries. It's only a nudge, so failing just means no nudge. */
async function chartPositions(): Promise<Map<number, number>> {
  const positions = new Map<number, number>();
  for (const country of CHART_COUNTRIES) {
    try {
      // 50 is the most Apple's feed reliably gives: 100 and 200 answered 5xx when tried.
      const res = await fetchWithTimeout(`https://rss.marketingtools.apple.com/api/v2/${country}/podcasts/top/50/podcasts.json`, {}, 10_000);
      const body = (await res.json()) as { feed?: { results?: { id: string }[] } };
      (body.feed?.results ?? []).forEach((show, i) => {
        const id = Number(show.id);
        positions.set(id, Math.min(positions.get(id) ?? Infinity, i + 1));
      });
    } catch {
      // Carry on without this country.
    }
  }
  return positions;
}

async function pickFor(ctx: ActionCtx, userId: Id<"users">, key: string): Promise<Suggestion[]> {
  const now = Date.now();
  const seeds: Seed[] = await ctx.runQuery(internal.suggestions.seedsFor, { userId });
  if (seeds.length === 0) return [];
  const since = new Date(now - 365 * 86_400_000).toISOString();
  const candidates = new Map<string, Candidate>();

  const collect = (results: ExaResult[], seedIndex: number, reason: string, mustMention?: string) => {
    results.forEach((r, i) => {
      if (!r.url.includes("/episode/") || !r.title) return;
      const header = parseEpisodeHeader(r.text ?? "");
      if (!isWorthShowing({ title: r.title, header }, seeds, now)) return;
      // A guest search also finds people talking about them. "Same guest" should mean that.
      if (mustMention && ![...header.guests, r.title].join(" ").toLowerCase().includes(mustMention.toLowerCase())) return;
      const found = candidates.get(r.url);
      if (found) found.score += 1 / (i + 3);
      else candidates.set(r.url, { url: r.url, title: r.title, header, artworkUrl: r.image, seedIndex, reason, score: 1 / (i + 3) });
    });
  };

  // Same topic.
  for (const [i, seed] of seeds.entries()) {
    const query = seed.why === "follows" ? `podcast episodes like ${seed.title}` : `podcast episodes about: ${seed.title}`;
    collect(await search(key, query, 10, since), i, reasonFor(seed));
  }

  // Same guest on other shows. Poddle doesn't know who's on an episode, but Exa's copy of it does.
  const guests: { name: string; seedIndex: number }[] = [];
  for (const [i, seed] of seeds.slice(0, GUEST_LOOKUPS).entries()) {
    if (seed.why === "follows" || guests.length >= MAX_GUESTS) continue;
    const hits = await search(key, `${seed.showTitle}: ${seed.title}`, 3);
    const same = hits.map((h) => parseEpisodeHeader(h.text ?? "")).find((h) => h.showTitle?.toLowerCase().includes(seed.showTitle.toLowerCase().slice(0, 12)));
    const name = same?.guests[0];
    if (name) guests.push({ name, seedIndex: i });
  }
  for (const { name, seedIndex } of guests) {
    collect(await search(key, `podcast interview with ${name}`, 10, since), seedIndex, reasonFor(seeds[seedIndex]!, name), name);
  }

  // Each show's page has the feed that opens the episode.
  const best = [...candidates.values()].sort((a, b) => b.score - a.score).slice(0, SHOWS_TO_RESOLVE);
  const showUrls = [...new Set(best.flatMap((c) => c.header.showUrl ?? []))];
  const pages = showUrls.length ? await exa(key, "/contents", { urls: showUrls, text: { maxCharacters: 500 } }) : [];
  const shows = new Map(pages.map((p) => [p.url, parseShowPage(p.text ?? "")]));

  const withFeeds = best.flatMap((c) => {
    const show = c.header.showUrl ? shows.get(c.header.showUrl) : undefined;
    return show?.feedUrl ? [{ c, feedUrl: show.feedUrl, appleId: show.appleId }] : [];
  });
  const matches = await ctx.runQuery(internal.directoryCache.libraryMatches, { userId, feedUrls: withFeeds.map((c) => c.feedUrl) });
  const followed = new Set(matches.filter((m) => m.subscribed).map((m) => m.feedUrl));
  const chart = await chartPositions();

  const ranked = withFeeds
    .filter(({ feedUrl }) => !followed.has(feedUrl))
    .map(({ c, feedUrl, appleId }) => {
      const chartPosition = appleId === undefined ? undefined : chart.get(appleId);
      return {
        seedIndex: c.seedIndex,
        showTitle: c.header.showTitle!,
        rank: rankScore(c.score, c.header.pubDate!, chartPosition, now),
        pick: {
          id: c.url.split("/").pop()!,
          title: c.title,
          showTitle: c.header.showTitle!,
          feedUrl,
          appleId,
          artworkUrl: c.artworkUrl,
          pubDate: c.header.pubDate!,
          duration: c.header.duration!,
          reason: c.reason,
          chartPosition,
        } satisfies Suggestion,
      };
    });
  return choosePicks(ranked).map((r) => r.pick);
}

export const refreshFor = internalAction({
  /** `claimed`: saveKey has already marked this refresh as started. */
  args: { userId: v.id("users"), claimed: v.optional(v.boolean()) },
  returns: v.null(),
  handler: async (ctx, { userId, claimed }) => {
    const stored = await ctx.runQuery(internal.suggestions.encryptedKey, { userId });
    if (!stored) return null;
    if (!claimed && !(await ctx.runMutation(internal.suggestions.startRefresh, { userId }))) return null;
    try {
      const picks = await pickFor(ctx, userId, decryptKey(stored));
      await ctx.runMutation(internal.suggestions.finishRefresh, { userId, picks });
    } catch (e) {
      // Never log the error's detail: a request can carry the key.
      console.warn(`[suggestions] refresh failed: ${e instanceof ExaError ? e.message : "unexpected"}`);
      const error = e instanceof ExaError ? e.message : "Couldn't get suggestions right now. We'll try again tomorrow.";
      await ctx.runMutation(internal.suggestions.finishRefresh, { userId, error });
    }
    return null;
  },
});

/** Saves someone's key (nothing else can read it back) and gets their first picks straight away. */
export const setKey = userAction({
  args: { key: v.string() },
  returns: v.null(),
  handler: async (ctx, { key }) => {
    const trimmed = key.trim();
    if (trimmed.length < 16 || /\s/.test(trimmed)) throw new ConvexError({ code: "badKey", message: "That doesn't look like an Exa key." });
    await ctx.runMutation(internal.suggestions.saveKey, { userId: ctx.userId, ciphertext: encryptKey(trimmed), ending: trimmed.slice(-4) });
    return null;
  },
});
