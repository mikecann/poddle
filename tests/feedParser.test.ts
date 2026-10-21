import { describe, expect, test } from "vitest";
import { discoverFeedLink, parseFeed } from "../convex/lib/feedParser";
import { enclosureKey, normalizeFeedUrl, parseAppleId, parseDate, parseDuration, snippet, truncate } from "../convex/lib/parse";
import { fixture } from "./helpers";

describe("parseDuration", () => {
  test.each([
    ["3600", 3600],
    ["2732", 2732],
    ["3600.5", 3600.5],
    ["45:30", 2730],
    ["1:05", 65],
    ["01:02:03", 3723],
    ["1:02:03.250", 3723.25],
    ["1h 2m 3s", 3723],
    ["45 min", 2700],
    ["PT1H2M", 3720],
    [" 00:45:00 ", 2700],
  ])("%s → %d", (raw, secs) => expect(parseDuration(raw)).toBe(secs));

  test.each(["", "0", "abc", "-5", undefined])("%s → undefined", (raw) => expect(parseDuration(raw)).toBeUndefined());
});

describe("parseDate", () => {
  test("RFC 822, ISO and Australian zone abbreviations", () => {
    expect(parseDate("Tue, 14 Oct 2025 18:00:00 +0000")).toBe(Date.UTC(2025, 9, 14, 18));
    expect(parseDate("2025-09-22T05:00:00Z")).toBe(Date.UTC(2025, 8, 22, 5));
    expect(parseDate("Mon, 29 Sep 2025 05:00:00 AEST")).toBe(Date.UTC(2025, 8, 28, 19));
    expect(parseDate("Thurs, 02 Jan 2025 00:00:00 GMT")).toBe(Date.UTC(2025, 0, 2));
    expect(parseDate("not a date")).toBeUndefined();
  });
});

describe("RSS with iTunes and Podcasting 2.0", () => {
  const feed = parseFeed(fixture("odd-feed.xml"), "https://feeds.example.com/odd.xml");

  test("show metadata, preferring itunes:image for artwork", () => {
    expect(feed).toMatchObject({
      format: "rss",
      title: "The Odd Show",
      author: "Odd Person",
      link: "https://odd.example.com",
      language: "en-au",
      artworkUrl: "https://cdn.example.com/odd-3000.jpg",
    });
    expect(feed.description).toContain("<b>odd</b>");
  });

  test("drops items without audio and duplicate GUIDs, newest first", () => {
    expect(feed.episodes.map((e) => e.title)).toEqual([
      "Episode 4: Chapters & Transcripts",
      "Episode 3: Seconds",
      "Episode 2: No GUID",
      "Episode 1: Minutes",
    ]);
  });

  test("chapters, transcripts, artwork, season and HH:MM:SS duration", () => {
    const ep = feed.episodes[0]!;
    expect(ep).toMatchObject({
      guid: "odd-ep-4",
      duration: 3723,
      season: 2,
      episodeNumber: 4,
      episodeType: "full",
      artworkUrl: "https://cdn.example.com/odd/ep4.jpg",
      chaptersUrl: "https://cdn.example.com/odd/ep4-chapters.json",
      chaptersType: "application/json+chapters",
      enclosureType: "audio/mpeg",
      enclosureLength: 58923000,
    });
    expect(ep.transcripts).toEqual([
      { url: "https://cdn.example.com/odd/ep4.vtt", type: "text/vtt", language: "en", rel: undefined },
      { url: "https://cdn.example.com/odd/ep4.json", type: "application/json", language: undefined, rel: "captions" },
    ]);
    expect(ep.showNotesHtml).toContain('<a href="https://example.com">show notes</a>');
    expect(ep.summary).toBe("Full show notes for episode 4.");
  });

  test("seconds and MM:SS durations, missing GUIDs, zero length", () => {
    const [, ep3, ep2, ep1] = feed.episodes;
    expect(ep3).toMatchObject({ duration: 2732, guid: "https://odd.example.com/episodes/3", enclosureLength: undefined });
    expect(ep2).toMatchObject({ duration: 2730, guid: undefined, explicit: true });
    expect(ep2!.pubDate).toBe(Date.UTC(2025, 8, 28, 19));
    expect(ep1).toMatchObject({ duration: 65, guid: undefined, pubDate: Date.UTC(2025, 8, 22, 5) });
  });
});

describe("Atom", () => {
  const feed = parseFeed(fixture("atom-feed.xml"), "https://atom.example.com/feed.atom");

  test("feed and entries with enclosure links", () => {
    expect(feed).toMatchObject({
      format: "atom",
      title: "Atom Cast",
      author: "Atom Author",
      description: "An Atom-only podcast",
      link: "https://atom.example.com/",
      artworkUrl: "https://atom.example.com/logo.png",
      language: "en",
    });
    expect(feed.episodes).toHaveLength(2);
    expect(feed.episodes[0]).toMatchObject({
      guid: "urn:uuid:entry-2",
      title: "Second entry",
      enclosureUrl: "https://atom.example.com/2.mp3",
      link: "https://atom.example.com/2",
      duration: 1800,
      pubDate: Date.UTC(2025, 9, 10, 10),
    });
    expect(feed.episodes[0]!.showNotesHtml).toBe("<p>Second <b>content</b></p>");
    expect(feed.episodes[1]).toMatchObject({ title: "First entry", pubDate: Date.UTC(2025, 9, 1, 10) });
  });
});

describe("helpers", () => {
  test("rejects non-feeds", () => {
    expect(() => parseFeed("<html><body>hi</body></html>")).toThrow();
  });

  test("discovers a feed link in a web page", () => {
    const html = `<html><head><link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml"></head></html>`;
    expect(discoverFeedLink(html, "https://show.example.com/about")).toBe("https://show.example.com/feed.xml");
  });

  test("enclosure keys strip the query and scheme", () => {
    expect(enclosureKey("https://cdn.example.com/a.mp3?x=1#t=3")).toBe("cdn.example.com/a.mp3");
    expect(enclosureKey("http://CDN.example.com/A.mp3")).toBe("cdn.example.com/A.mp3");
  });

  test("enclosure keys peel tracking redirects", () => {
    const real = "traffic.megaphone.fm/ABC123.mp3";
    for (const url of [
      "https://traffic.megaphone.fm/ABC123.mp3?updated=1",
      "http://dts.podtrac.com/redirect.mp3/traffic.megaphone.fm/ABC123.mp3",
      "https://www.podtrac.com/pts/redirect.mp3/pdst.fm/e/chtbl.com/track/42D/traffic.megaphone.fm/ABC123.mp3",
      "https://tracking.swap.fm/track/xYz123/traffic.megaphone.fm/ABC123.mp3",
      "https://chrt.fm/track/15E3G4/traffic.megaphone.fm/ABC123.mp3",
      "https://pdst.fm/e/https://traffic.megaphone.fm/ABC123.mp3",
      "https://op3.dev/e,pg=abc/traffic.megaphone.fm/ABC123.mp3",
      "https://mgln.ai/e/89/traffic.megaphone.fm/ABC123.mp3",
    ]) {
      expect(enclosureKey(url), url).toBe(real);
    }
    expect(enclosureKey("https://anchor.fm/s/abc/podcast/play/123/https%3A%2F%2Fcdn.example.com%2Fstaging%2Fx.m4a")).toBe(
      "cdn.example.com/staging/x.m4a",
    );
    // A host's own path isn't mistaken for a wrapped URL.
    expect(enclosureKey("https://media.blubrry.com/show/file.mp3")).toBe("media.blubrry.com/show/file.mp3");
    expect(enclosureKey("https://media.blubrry.com/show/content.blubrry.com/show/file.mp3")).toBe("content.blubrry.com/show/file.mp3");
  });

  test("snippets never split an emoji", () => {
    const text = "a".repeat(278) + "🎙️ and more";
    const s = snippet(`<p>${text}</p>`)!;
    expect(s).toBe("a".repeat(278) + "…");
    expect(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(s)).toBe(false);
    expect(truncate("ab🎙", 3)).toBe("ab");
    expect(truncate("ab🎙", 4)).toBe("ab🎙");
  });

  test("Overcast's date formats", () => {
    expect(parseDate("Tue, 04 Oct 2016 05:24:50 +0000")).toBe(Date.UTC(2016, 9, 4, 5, 24, 50));
    expect(parseDate("2026-10-19T03:40:06-04:00")).toBe(Date.UTC(2026, 9, 19, 7, 40, 6));
    expect(parseDate("2016-02-18T21:03:11+11:00")).toBe(Date.UTC(2016, 1, 18, 10, 3, 11));
  });

  test("feed URL normalisation", () => {
    expect(normalizeFeedUrl("feed://Example.com/rss")).toBe("https://example.com/rss");
    expect(normalizeFeedUrl("example.com/rss")).toBe("https://example.com/rss");
  });

  test("Apple IDs from links", () => {
    expect(parseAppleId("https://podcasts.apple.com/au/podcast/the-show/id1234567890?i=1000")).toBe(1234567890);
    expect(parseAppleId("https://overcast.fm/itunes617416468/accidental-tech-podcast")).toBe(617416468);
    expect(parseAppleId("617416468")).toBe(617416468);
    expect(parseAppleId("https://example.com")).toBeUndefined();
  });
});
