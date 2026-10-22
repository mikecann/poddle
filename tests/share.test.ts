import { afterEach, describe, expect, test, vi } from "vitest";
import { api } from "../convex/_generated/api";
import type { Id } from "../convex/_generated/dataModel";
import { appSiteAssociation } from "../convex/http";
import { FALLBACK_INDEX_HTML, LANDING_END, LANDING_START, META_END, META_START, escapeHtml, renderSharePage } from "../convex/lib/meta";
import { BASE, seedShow } from "./seed";
import { setup, type T } from "./helpers";

// The website's public pages (convex/share.ts, lib/sharePages.ts, http.ts):
// shared catalogue data only, private feeds never.

afterEach(() => {
  vi.restoreAllMocks();
  delete process.env.PODDLE_SITE_URL;
});

/** A show with one episode (and notes), not in anyone's library. */
async function seedLooseShow(t: T, show: { feedUrl: string; isPrivate?: boolean; title?: string }, enclosureUrl = "https://cdn.example.com/a/1.mp3") {
  return await t.run(async (ctx) => {
    const podcastId = await ctx.db.insert("podcasts", {
      feedUrl: show.feedUrl,
      title: show.title ?? "Loose",
      author: "Someone",
      description: "<p>A show about <b>things</b>.</p>",
      artworkUrl: "https://img.example.com/a.jpg",
      isPrivate: show.isPrivate ?? false,
      episodeCount: 1,
      createdAt: BASE,
      updatedAt: BASE,
    });
    const episodeId = await ctx.db.insert("episodes", {
      podcastId,
      title: "Episode one",
      enclosureUrl,
      enclosureType: "audio/mpeg",
      summary: "What happens in it.",
      pubDate: BASE,
      duration: 1800,
      transcripts: [],
      isGhost: false,
      firstSeenAt: BASE,
      updatedAt: BASE,
    });
    await ctx.db.insert("episodeNotes", { episodeId, html: "<p>Notes at 12:34</p>", updatedAt: BASE });
    return { podcastId, episodeId };
  });
}

describe("share:episode and share:show", () => {
  test("work signed out and return only the page's fields", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await seedShow(t, 3, { title: "pub" });
    const episodeId = episodeIds[2]!;
    // Mike has state and a queue entry for it; none of it may come back.
    await t.mutation(api.queue.add, { episodeId, position: "bottom", at: BASE });
    await t.mutation(api.episodes.updatePosition, { episodeId, position: 600, positionUpdatedAt: BASE, deviceId: "d" });

    const episode = await t.raw.query(api.share.episode, { episodeId });
    expect(episode).not.toBeNull();
    expect(Object.keys(episode!).sort()).toEqual(
      ["_id", "audioUrl", "duration", "podcast", "pubDate", "title"].sort(),
    );
    expect(episode!.podcast).toEqual({ _id: podcastId, title: "pub" });
    expect(JSON.stringify(episode)).not.toMatch(/position|queue|userId|played|feedUrl/);

    const show = await t.raw.query(api.share.show, { podcastId });
    expect(show!.show.feedUrl).toBe("https://feeds.example.com/pub.xml");
    expect(show!.episodes.map((e) => e.title)).toEqual(["Ep 2", "Ep 1", "Ep 0"]);
    expect(Object.keys(show!.show).sort()).toEqual(["_id", "episodeCount", "feedUrl", "title"].sort());
    expect(JSON.stringify(show)).not.toMatch(/subscribed|userId|isPrivate/);
  });

  test("strip HTML from the description and take the summary from the episode", async () => {
    const t = setup();
    const { podcastId, episodeId } = await seedLooseShow(t, { feedUrl: "https://feeds.example.com/loose.xml" });
    const show = await t.raw.query(api.share.show, { podcastId });
    expect(show!.show.description).toBe("A show about things.");
    const episode = await t.raw.query(api.share.episode, { episodeId });
    expect(episode!.summary).toBe("What happens in it.");
    expect(episode!.showNotesHtml).toBe("<p>Notes at 12:34</p>");
    expect(episode!.artworkUrl).toBe("https://img.example.com/a.jpg");
  });

  test("a show flagged private has no pages, nor do its episodes", async () => {
    const t = setup();
    const { podcastId, episodeId } = await seedLooseShow(t, { feedUrl: "https://feeds.example.com/p.xml", isPrivate: true });
    expect(await t.raw.query(api.share.show, { podcastId })).toBeNull();
    expect(await t.raw.query(api.share.episode, { episodeId })).toBeNull();
  });

  test.each([
    ["a Patreon token", "https://www.patreon.com/rss/aidaily?auth=abc123&show=1"],
    ["Basic auth", "https://user:pass@feeds.example.com/premium.xml"],
    ["a Supercast key", "https://show.supercast.com/feeds/xyz?key=s3cret"],
    ["a /private/ path", "https://feeds.example.com/private/feed.xml"],
  ])("a feed URL with %s is private even if not flagged", async (_label, feedUrl) => {
    const t = setup();
    const { podcastId, episodeId } = await seedLooseShow(t, { feedUrl });
    expect(await t.raw.query(api.share.show, { podcastId })).toBeNull();
    expect(await t.raw.query(api.share.episode, { episodeId })).toBeNull();
  });

  test("anyone switching a show to private takes it off the web", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await seedShow(t, 1, { title: "mine" });
    expect(await t.raw.query(api.share.show, { podcastId })).not.toBeNull();
    await t.mutation(api.podcasts.setPrivate, { podcastId, isPrivate: true });
    expect(await t.raw.query(api.share.show, { podcastId })).toBeNull();
    expect(await t.raw.query(api.share.episode, { episodeId: episodeIds[0]! })).toBeNull();
  });

  test("an episode whose enclosure URL carries a token is not found, and isn't listed", async () => {
    const t = setup();
    const { podcastId, episodeId } = await seedLooseShow(
      t,
      { feedUrl: "https://feeds.example.com/mixed.xml" },
      "https://cdn.example.com/ep.mp3?token=abc",
    );
    expect(await t.raw.query(api.share.episode, { episodeId })).toBeNull();
    const show = await t.raw.query(api.share.show, { podcastId });
    expect(show!.episodes).toEqual([]);
    expect(JSON.stringify(show)).not.toContain("token=abc");
  });

  test("junk and wrong-table ids are not found rather than errors", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await seedShow(t, 1);
    expect(await t.raw.query(api.share.episode, { episodeId: "nope" })).toBeNull();
    expect(await t.raw.query(api.share.episode, { episodeId: podcastId })).toBeNull();
    expect(await t.raw.query(api.share.show, { podcastId: episodeIds[0]! })).toBeNull();
  });

  test("ghost episodes have no player and aren't listed", async () => {
    const t = setup();
    const { podcastId, episodeIds } = await seedShow(t, 2);
    await t.run(async (ctx) => ctx.db.patch(episodeIds[1]!, { isGhost: true }));
    const episode = await t.raw.query(api.share.episode, { episodeId: episodeIds[1]! });
    expect(episode!.audioUrl).toBeUndefined();
    const show = await t.raw.query(api.share.show, { podcastId });
    expect(show!.episodes.map((e) => e._id)).toEqual([episodeIds[0]]);
  });
});

describe("share pages over HTTP", () => {
  test("/e/<id> serves the page with its Open Graph and Twitter tags", async () => {
    const t = setup();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { episodeId } = await seedLooseShow(t, { feedUrl: "https://feeds.example.com/loose.xml", title: "Loose & Co" });
    process.env.PODDLE_SITE_URL = "https://poddle.mikecann.app";
    const res = await t.raw.fetch(`/e/${episodeId}?t=90`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/html; charset=utf-8");
    const html = await res.text();
    expect(html).toContain(`<title>Episode one · Loose &amp; Co · Poddle</title>`);
    expect(html).toContain(`<meta property="og:title" content="Episode one">`);
    expect(html).toContain(`<meta property="og:description" content="What happens in it.">`);
    expect(html).toContain(`<meta property="og:image" content="https://img.example.com/a.jpg">`);
    expect(html).toContain(`<meta property="og:url" content="https://poddle.mikecann.app/e/${episodeId}">`);
    expect(html).toContain(`<meta name="twitter:card" content="summary">`);
    expect(html).toContain(`<script id="poddle-page" type="application/json">`);
    // The notes' HTML is escaped inside the JSON so it can't close the script.
    expect(html).not.toContain("<p>Notes at 12:34</p>");
  });

  test("/s/<id> serves the show's tags", async () => {
    const t = setup();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { podcastId } = await seedLooseShow(t, { feedUrl: "https://feeds.example.com/loose.xml" });
    const html = await (await t.raw.fetch(`/s/${podcastId}`)).text();
    expect(html).toContain(`<meta property="og:title" content="Loose">`);
    expect(html).toContain(`<meta property="og:description" content="A show about things.">`);
    expect(html).toContain(`<meta property="og:type" content="music.album">`);
  });

  test("pages without artwork use the branded preview at the site's origin", async () => {
    const t = setup();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { podcastId, episodeIds } = await seedShow(t, 1);
    process.env.PODDLE_SITE_URL = "https://poddle.mikecann.app";
    for (const path of [`/e/${episodeIds[0]}`, `/s/${podcastId}`, "/e/missing"]) {
      const html = await (await t.raw.fetch(path)).text();
      expect(html).toContain(`<meta property="og:image" content="https://poddle.mikecann.app/og-default.png">`);
      expect(html).toContain(`<meta name="twitter:image" content="https://poddle.mikecann.app/og-default.png">`);
      expect(html).toContain(`<meta name="twitter:card" content="summary_large_image">`);
    }
  });

  test("a private feed's episode page is a 404 that gives nothing away", async () => {
    const t = setup();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { podcastId, episodeId } = await seedLooseShow(
      t,
      { feedUrl: "https://www.patreon.com/rss/x?auth=SECRET", title: "Secret Show" },
      "https://c10.patreonusercontent.com/ep.mp3?token-hash=SECRET",
    );
    for (const path of [`/e/${episodeId}`, `/s/${podcastId}`]) {
      const res = await t.raw.fetch(path);
      expect(res.status).toBe(404);
      const html = await res.text();
      expect(html).toContain(`<meta name="robots" content="noindex">`);
      expect(html).not.toMatch(/SECRET|Secret Show|Episode one|patreon/);
    }
  });

  test("the apple-app-site-association file links /e/* and /s/* to the app", async () => {
    const t = setup();
    const res = await t.raw.fetch("/.well-known/apple-app-site-association");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    const body = await res.json();
    expect(body).toEqual(appSiteAssociation);
    expect(body.applinks.details[0]).toEqual({
      appIDs: ["4DTAZSZL6B.com.mikecann.poddle"],
      components: [{ "/": "/e/*" }, { "/": "/s/*" }],
    });
    expect(body.webcredentials.apps).toEqual(["4DTAZSZL6B.com.mikecann.poddle"]);
  });
});

describe("renderSharePage", () => {
  const episode = {
    _id: "e1" as Id<"episodes">,
    title: `"Quotes" <and> tags`,
    summary: "x".repeat(400),
    podcast: { _id: "p1" as Id<"podcasts">, title: "Show", artworkUrl: "https://img.example.com/s.jpg" },
  };
  const built = `<!doctype html><html><head><meta charset="UTF-8">${META_START}<title>Poddle</title><meta name="description" content="default">${META_END}<script type="module" src="/assets/index-abc.js"></script></head><body><div id="root"></div></body></html>`;

  test("replaces the default block, escapes everything and keeps the rest of the page", () => {
    const html = renderSharePage(built, { kind: "episode", episode }, "https://poddle.mikecann.app");
    expect(html).not.toContain(`content="default"`);
    expect(html).toContain(`<meta property="og:title" content="&quot;Quotes&quot; &lt;and&gt; tags">`);
    expect(html).toContain(`<meta property="og:image" content="https://img.example.com/s.jpg">`);
    expect(html).toContain(`<script type="module" src="/assets/index-abc.js"></script>`);
    expect(html.match(/<title>/g)).toHaveLength(1);
    const description = /og:description" content="([^"]*)"/.exec(html)![1]!;
    expect(description.length).toBeLessThanOrEqual(200);
    expect(description.endsWith("…")).toBe(true);
  });

  test("the embedded page data can't break out of its script tag", () => {
    const sneaky = { ...episode, showNotesHtml: "</script><script>alert(1)</script>" };
    const html = renderSharePage(built, { kind: "episode", episode: sneaky }, "https://x.test");
    expect(html).not.toContain("</script><script>alert(1)");
    const json = /<script id="poddle-page" type="application\/json">([\s\S]*?)<\/script>/.exec(html)![1]!;
    expect(JSON.parse(json).episode.showNotesHtml).toBe(sneaky.showNotesHtml);
  });

  test("works on a page without the markers", () => {
    const html = renderSharePage("<html><head><title>Old</title></head><body></body></html>", { kind: "notFound", what: "show" }, "https://x.test");
    expect(html).toContain("<title>Show not found · Poddle</title>");
    expect(html).not.toContain("<title>Old</title>");
    expect(renderSharePage(FALLBACK_INDEX_HTML, { kind: "notFound", what: "episode" }, "https://x.test")).toContain("Episode not found");
  });

  test("leaves out the prerendered home page", () => {
    const withLanding = built.replace(`<div id="root"></div>`, `<div id="root">${LANDING_START}<h1>Faster podcasts</h1>${LANDING_END}</div>`);
    const html = renderSharePage(withLanding, { kind: "episode", episode }, "https://x.test");
    expect(html).not.toContain("Faster podcasts");
    expect(html).toContain(`<div id="root">${LANDING_START}${LANDING_END}</div>`);
  });

  test("escapeHtml", () => {
    expect(escapeHtml(`<a href="x">'&'</a>`)).toBe("&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  });
});

describe("sessions:recent", () => {
  test("lists recently listened episodes, newest first, once each, for the caller only", async () => {
    const t = setup();
    const { episodeIds } = await seedShow(t, 3, { title: "rec" });
    const session = (id: string, episodeId: Id<"episodes">, startedAt: number) => ({
      sessionId: id, episodeId, startedAt, endedAt: startedAt + 60_000, contentStart: 0, contentEnd: 60,
      rate: 1, smartSpeed: false, smartRemovedContent: 0, voiceBoost: false, utcOffsetMinutes: 0,
    });
    await t.mutation(api.sessions.record, {
      sessions: [
        session("a", episodeIds[0]!, BASE),
        session("b", episodeIds[1]!, BASE + 1000),
        session("c", episodeIds[0]!, BASE + 2000),
      ],
    });
    const recent = await t.query(api.sessions.recent, {});
    expect(recent.map((r) => r.row.episode._id)).toEqual([episodeIds[0], episodeIds[1]]);
    expect(recent[0]!.lastListenedAt).toBe(BASE + 2000 + 60_000);

    expect(await t.as("someone@else.test").query(api.sessions.recent, {})).toEqual([]);
    await expect(t.raw.query(api.sessions.recent, {})).rejects.toThrow(/Sign in first/);
  });
});
