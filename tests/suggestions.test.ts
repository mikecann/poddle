import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { choosePicks, isWorthShowing, parseDuration, parseEpisodeHeader, parseShowPage, rankScore } from "../convex/lib/suggestions";
import { mockFetch, setup, type T } from "./helpers";
import { seedShow } from "./seed";

const DAY = 86_400_000;
const KEY = "exa-key-0123456789abcd";
const ago = (days: number) => new Date(Date.now() - days * DAY).toISOString();

const episodeText = (o: { show: string; slug?: string; published?: string; duration?: string; language?: string; guests?: string }) =>
  [
    "# Title",
    "",
    `- **Podcast:** [${o.show}](https://exa.ai/library/podcast/${o.slug ?? o.show.toLowerCase().replace(/\W/g, "")})`,
    `- **Published:** ${o.published ?? ago(10)}`,
    `- **Duration:** ${o.duration ?? "45:00.000"}`,
    `- **Language:** ${o.language ?? "en"}`,
    ...(o.guests ? [`- **Guests:** ${o.guests}`] : []),
    "",
    "## Transcript",
  ].join("\n");

const result = (id: string, title: string, o: Parameters<typeof episodeText>[0]) => ({
  url: `https://exa.ai/library/podcast/${o.slug ?? o.show.toLowerCase().replace(/\W/g, "")}/episode/${id}`,
  title,
  image: `https://cdn.example.com/${id}.jpg`,
  text: episodeText(o),
});

/** A fake Exa: `search` decides what each query finds, and every show page has a feed. */
function fakeExa(search: (query: string) => unknown[] = () => [], status = 200) {
  const queries: string[] = [];
  const fetchMock = mockFetch({
    "https://api.exa.ai/search": (init) => {
      const body = JSON.parse(String(init?.body));
      queries.push(body.query);
      return { status, body: JSON.stringify({ results: search(body.query) }) };
    },
    "https://api.exa.ai/contents": (init) => {
      const { urls } = JSON.parse(String(init?.body)) as { urls: string[] };
      return {
        body: JSON.stringify({
          results: urls.map((url) => ({
            url,
            text: `# Show\n\n[Apple Podcasts](https://podcasts.apple.com/podcast/id${url.length}) · [RSS feed](https://feeds.example.com/${url.split("/").pop()}.xml)\n`,
          })),
        }),
      };
    },
    "https://rss.marketingtools.apple.com/": { body: JSON.stringify({ feed: { results: [] } }) },
  });
  return { queries, fetchMock };
}

async function listenTo(t: T, episodeId: Id<"episodes">, podcastId: Id<"podcasts">, estimated = false) {
  const userId = await t.userId();
  const startedAt = Date.now() - DAY;
  await t.run(async (ctx) => {
    await ctx.db.insert("listeningSessions", {
      userId, sessionId: `${episodeId}`, episodeId, podcastId, startedAt, endedAt: startedAt + 3_600_000, contentStart: 0, contentEnd: 3600,
      rate: 1, smartSpeed: false, smartRemovedContent: 0, voiceBoost: false, source: "live", isEstimated: estimated, utcOffsetMinutes: 0, updatedAt: startedAt,
    });
  });
}

/** A show they've listened to, with an episode new enough to search around. */
async function heard(t: T, showTitle: string, opts: { private?: boolean; estimated?: boolean } = {}) {
  const { podcastId, episodeIds } = await seedShow(t, 1, { title: showTitle });
  const episodeId = episodeIds[0]!;
  await t.run(async (ctx) => {
    await ctx.db.patch(episodeId, { title: `${showTitle} ep`, pubDate: Date.now() - 5 * DAY });
    if (opts.private) await ctx.db.patch(podcastId, { isPrivate: true });
  });
  await listenTo(t, episodeId, podcastId, opts.estimated);
  return { podcastId, episodeId };
}


beforeEach(() => {
  process.env.PODDLE_KEY_SECRET = "test-secret";
});
afterEach(() => {
  delete process.env.PODDLE_KEY_SECRET;
  vi.unstubAllGlobals();
});

async function withKey(t: T) {
  const userId = await t.userId();
  fakeExa();
  await t.action(api.suggestionsActions.setKey, { key: KEY });
  await t.finishAllScheduledFunctions(() => undefined);
  return userId;
}
const run = async (t: T, userId: Id<"users">) => await t.raw.action(internal.suggestionsActions.refreshFor, { userId });

describe("reading Exa's pages", () => {
  test("an episode's header", () => {
    const h = parseEpisodeHeader(episodeText({ show: "Hard Fork", published: "2026-10-16T04:00:00+00:00", duration: "73:06.482", guests: "[Caitlin Roper](https://x), John Carreyrou" }));
    expect(h).toMatchObject({ showTitle: "Hard Fork", showUrl: "https://exa.ai/library/podcast/hardfork", language: "en", guests: ["Caitlin Roper", "John Carreyrou"] });
    expect(h.pubDate).toBe(Date.parse("2026-10-16T04:00:00+00:00"));
    expect(h.duration).toBeCloseTo(4386.482);
  });

  test("a guest whose link the text cut off halfway", () => {
    expect(parseEpisodeHeader("- **Guests:** [Arvind Krishna](https://exa.ai/x), [Nikesh Arora](htt").guests).toEqual(["Arvind Krishna", "Nikesh Arora"]);
  });

  test("hours in a duration, and rubbish", () => {
    expect(parseDuration("1:30:00.000")).toBe(5400);
    expect(parseDuration("nope")).toBeUndefined();
    expect(parseDuration(undefined)).toBeUndefined();
  });

  test("a show page's feed and Apple ID", () => {
    const text = "[Apple Podcasts](https://podcasts.apple.com/podcast/id1695014346) · [Spotify](https://open.spotify.com/show/x) · [RSS feed](https://feeds.transistor.fm/talkingpostgres)";
    expect(parseShowPage(text)).toEqual({ feedUrl: "https://feeds.transistor.fm/talkingpostgres", appleId: 1695014346 });
    expect(parseShowPage("no links")).toEqual({ feedUrl: undefined, appleId: undefined });
  });
});

describe("what's worth showing", () => {
  const now = Date.now();
  const good = { showTitle: "Hard Fork", pubDate: now - 10 * DAY, duration: 3000, language: "en", guests: [] };
  const seeds = [{ title: "Mourning the Death of Code", showTitle: "Syntax" }];
  const ok = (title: string, header = good) => isWorthShowing({ title, header }, seeds, now);

  test("a recent, full-length episode", () => expect(ok("Something new")).toBe(true));
  test("nothing over a year old", () => expect(ok("Old", { ...good, pubDate: now - 400 * DAY })).toBe(false));
  test("no short clips", () => expect(ok("Clip", { ...good, duration: 300 })).toBe(false));
  test("no other languages", () => expect(ok("Hola", { ...good, language: "es" })).toBe(false));
  test("no AI summary shows", () => expect(ok("Ep", { ...good, showTitle: "AI Podcast Summaries" })).toBe(false));
  test("not the episode they heard", () => expect(ok("mourning the death of code")).toBe(false));
  test("not the episode they heard, worded differently", () => {
    const heard = [{ title: "Nikesh Arora & Arvind Krishna: SaaS Collapse, Quantum Threat and AI Cyber Warfare", showTitle: "All-In" }];
    expect(isWorthShowing({ title: "Arvind Krishna & Nikesh Arora: Quantum Threat, Open vs Frontier AI, AI Cyber Warfare & SaaS Collapse", header: { ...good, showTitle: "All-In" } }, heard, now)).toBe(false);
    expect(isWorthShowing({ title: "Nikesh Arora, CEO Palo Alto Networks", header: { ...good, showTitle: "Sourcery" } }, heard, now)).toBe(true);
  });
  test("not another show's write-up of it", () => expect(ok("Syntax: why code died")).toBe(false));
  test("nothing with missing details", () => expect(ok("Ep", { ...good, pubDate: undefined as never })).toBe(false));

  test("newer ranks above older, and charting shows get a nudge that can't beat a much better match", () => {
    expect(rankScore(0.3, now - 5 * DAY, undefined, now)).toBeGreaterThan(rankScore(0.3, now - 300 * DAY, undefined, now));
    expect(rankScore(0.3, now - 5 * DAY, 1, now)).toBeGreaterThan(rankScore(0.3, now - 5 * DAY, undefined, now));
    expect(rankScore(1, now - 5 * DAY, undefined, now)).toBeGreaterThan(rankScore(0.3, now - 5 * DAY, 1, now));
  });

  test("one story or one show can't fill the list", () => {
    const c = (seedIndex: number, showTitle: string, rank: number) => ({ seedIndex, showTitle, rank });
    const picks = choosePicks([c(0, "A", 9), c(0, "B", 8), c(0, "C", 7), c(1, "A", 6), c(1, "D", 5), c(2, "E", 4), c(3, "F", 3), c(4, "G", 2)]);
    expect(picks.map((p) => p.showTitle)).toEqual(["A", "B", "D", "E", "F"]);
  });
});

describe("your key", () => {
  test("is kept encrypted and only its ending comes back", async () => {
    const t = setup();
    await withKey(t);
    const stored = await t.run(async (ctx) => await ctx.db.query("exaKeys").collect());
    expect(JSON.stringify(stored)).not.toContain(KEY);
    const you = await t.query(api.suggestions.forYou, {});
    expect(you).toMatchObject({ hasKey: true, keyEnding: "abcd" });
    expect(JSON.stringify(you)).not.toContain(KEY);
  });

  test("says it's refreshing the moment the key's saved, so the app keeps looking", async () => {
    const t = setup();
    fakeExa();
    await t.action(api.suggestionsActions.setKey, { key: KEY });
    expect((await t.query(api.suggestions.forYou, {})).refreshing).toBe(true);
    await t.finishAllScheduledFunctions(() => undefined);
    expect((await t.query(api.suggestions.forYou, {})).refreshing).toBe(false);
  });

  test("something that can't be a key is refused", async () => {
    const t = setup();
    await expect(t.action(api.suggestionsActions.setKey, { key: "short" })).rejects.toThrow(/look like/);
    expect((await t.query(api.suggestions.forYou, {})).hasKey).toBe(false);
  });

  test("removing it forgets the picks too", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    fakeExa((q) => (q.startsWith("podcast episodes about") ? [result("e1", "New one", { show: "Hard Fork" })] : []));
    await run(t, userId);
    expect((await t.query(api.suggestions.forYou, {})).picks).toHaveLength(1);
    await t.mutation(api.suggestions.removeKey, {});
    expect(await t.query(api.suggestions.forYou, {})).toMatchObject({ hasKey: false, picks: [] });
  });

  test("without a key nothing goes to Exa", async () => {
    const t = setup();
    const { fetchMock } = fakeExa();
    await run(t, await t.userId());
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("refreshing", () => {
  test("finds episodes around what you heard, each with its date and why", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    fakeExa((q) => (q.startsWith("podcast episodes about") ? [result("e1", "New one", { show: "Hard Fork", published: "2026-10-16T04:00:00+00:00", duration: "73:00.000" })] : []));
    vi.setSystemTime(Date.parse("2026-11-03T00:00:00Z"));
    await run(t, userId);
    vi.useRealTimers();
    const { picks, error, refreshing } = await t.query(api.suggestions.forYou, {});
    expect(error).toBeUndefined();
    expect(refreshing).toBe(false);
    expect(picks[0]).toMatchObject({
      id: "e1", title: "New one", showTitle: "Hard Fork", feedUrl: "https://feeds.example.com/hardfork.xml",
      pubDate: Date.parse("2026-10-16T04:00:00+00:00"), duration: 4380, reason: 'Because you heard "Syntax ep"', artworkUrl: "https://cdn.example.com/e1.jpg",
    });
  });

  test("never sends a private show, or imported plays, to Exa", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Secret Feed", { private: true });
    await heard(t, "Imported Show", { estimated: true });
    await heard(t, "Public Show");
    const { queries } = fakeExa();
    await run(t, userId);
    expect(queries.join("\n")).toContain("Public Show");
    expect(queries.join("\n")).not.toContain("Secret Feed");
    expect(queries.join("\n")).not.toContain("Imported Show ep");
  });

  test("someone's own private switch counts, even on a public show", async () => {
    const t = setup();
    const userId = await withKey(t);
    const { podcastId } = await heard(t, "My Hidden Show");
    await t.run(async (ctx) => {
      const sub = await ctx.db.query("subscriptions").withIndex("by_user_podcast", (q) => q.eq("userId", userId).eq("podcastId", podcastId)).unique();
      await ctx.db.patch(sub!._id, { isPrivate: true });
    });
    const { queries } = fakeExa();
    await run(t, userId);
    expect(queries.join("\n")).not.toContain("My Hidden Show");
  });

  test("finds the guest's other shows, only where they really are", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    fakeExa((q) => {
      if (q === "Syntax: Syntax ep") return [result("orig", "Syntax ep", { show: "Syntax", guests: "[Roman Mars](https://x)" })];
      if (q === "podcast interview with Roman Mars") {
        return [
          result("g1", "History in 100 objects", { show: "Sidedoor", guests: "Roman Mars" }),
          result("g2", "Talking about someone else", { show: "Elsewhere", guests: "Other Person" }),
        ];
      }
      return [];
    });
    await run(t, userId);
    const { picks } = await t.query(api.suggestions.forYou, {});
    expect(picks.map((p) => p.id)).toEqual(["g1"]);
    expect(picks[0]!.reason).toBe("Roman Mars, who you heard on Syntax");
  });

  test("leaves out shows you already follow, including ones followed since", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    await t.run(async (ctx) => {
      const podcastId = await ctx.db.insert("podcasts", { feedUrl: "https://feeds.example.com/followed.xml", title: "Followed", isPrivate: false, episodeCount: 1, createdAt: 1, updatedAt: 1 });
      await ctx.db.insert("subscriptions", { userId, podcastId, subscribed: true, subscriptionUpdatedAt: 1, addedAt: 1, updatedAt: 1 });
    });
    fakeExa((q) => (q.startsWith("podcast episodes about") ? [result("e1", "Theirs", { show: "Followed" }), result("e2", "New", { show: "Hard Fork" })] : []));
    await run(t, userId);
    expect((await t.query(api.suggestions.forYou, {})).picks.map((p) => p.id)).toEqual(["e2"]);
    await t.run(async (ctx) => {
      const podcastId = await ctx.db.insert("podcasts", { feedUrl: "https://feeds.example.com/hardfork.xml", title: "Hard Fork", isPrivate: false, episodeCount: 1, createdAt: 1, updatedAt: 1 });
      await ctx.db.insert("subscriptions", { userId, podcastId, subscribed: true, subscriptionUpdatedAt: 1, addedAt: 1, updatedAt: 1 });
    });
    expect((await t.query(api.suggestions.forYou, {})).picks).toEqual([]);
  });

  test("a new person with no history gets picks from what they follow", async () => {
    const t = setup();
    const userId = await withKey(t);
    await seedShow(t, 1, { title: "Syntax" });
    const { queries } = fakeExa();
    await run(t, userId);
    expect(queries).toContain("podcast episodes like Syntax");
  });

  test("a rejected key says so and keeps the last picks", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    fakeExa((q) => (q.startsWith("podcast episodes about") ? [result("e1", "New", { show: "Hard Fork" })] : []));
    await run(t, userId);
    fakeExa(() => [], 401);
    await run(t, userId);
    const you = await t.query(api.suggestions.forYou, {});
    expect(you.error).toMatch(/didn't accept that key/);
    expect(you.picks.map((p) => p.id)).toEqual(["e1"]);
    expect(you.refreshing).toBe(false);
  });

  test("running out of credits says so", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    fakeExa(() => [], 402);
    await run(t, userId);
    expect((await t.query(api.suggestions.forYou, {})).error).toMatch(/out of credits/);
  });

  test("the daily job only picks up people whose picks are a week old", async () => {
    const t = setup();
    const userId = await withKey(t);
    await heard(t, "Syntax");
    const due = () => t.raw.mutation(internal.suggestions.refreshDue, {});
    await run(t, userId);
    expect(await due()).toBe(0);
    await t.run(async (ctx) => {
      const row = await ctx.db.query("suggestions").first();
      await ctx.db.patch(row!._id, { refreshedAt: Date.now() - 8 * DAY });
    });
    expect(await due()).toBe(1);
  });
});
