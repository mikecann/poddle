import { XMLParser } from "fast-xml-parser";
import { parseDate, parseDuration, parseIntOrUndefined, snippet } from "./parse";

// RSS 2.0 (+ iTunes and Podcasting 2.0 namespaces) and Atom. Pure: no Convex imports.

export type ParsedTranscript = { url: string; type: string; language?: string; rel?: string };

export type ParsedEpisode = {
  guid?: string;
  enclosureUrl: string;
  enclosureType?: string;
  enclosureLength?: number;
  title: string;
  showNotesHtml?: string;
  summary?: string;
  link?: string;
  pubDate?: number;
  duration?: number;
  chaptersUrl?: string;
  chaptersType?: string;
  transcripts: ParsedTranscript[];
  artworkUrl?: string;
  season?: number;
  episodeNumber?: number;
  episodeType?: string;
  explicit?: boolean;
};

export type ParsedFeed = {
  format: "rss" | "atom";
  title: string;
  author?: string;
  description?: string;
  artworkUrl?: string;
  link?: string;
  language?: string;
  /** `itunes:new-feed-url`: the publisher moved the feed. */
  newFeedUrl?: string;
  /** Newest first. Items without an audio enclosure are dropped. */
  episodes: ParsedEpisode[];
};

export class FeedParseError extends Error {}

const ARRAY_TAGS = new Set([
  "item",
  "entry",
  "link",
  "podcast:transcript",
  "enclosure",
  "media:content",
  "itunes:category",
  "category",
  "atom:link",
]);

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true,
  processEntities: true,
  htmlEntities: true,
  isArray: (name) => ARRAY_TAGS.has(name),
});

type Node = Record<string, unknown>;

function asNode(x: unknown): Node | undefined {
  if (Array.isArray(x)) return asNode(x[0]);
  return x && typeof x === "object" ? (x as Node) : undefined;
}

function asArray(x: unknown): unknown[] {
  if (x === undefined || x === null) return [];
  return Array.isArray(x) ? x : [x];
}

/** Text content of an element whether it parsed as a string or as {#text, @_attrs}. */
function text(x: unknown): string | undefined {
  if (Array.isArray(x)) {
    for (const item of x) {
      const t = text(item);
      if (t) return t;
    }
    return undefined;
  }
  if (typeof x === "string") return x.trim() || undefined;
  if (typeof x === "number" || typeof x === "boolean") return String(x);
  const n = asNode(x);
  if (n && "#text" in n) return text(n["#text"]);
  return undefined;
}

function attr(x: unknown, name: string): string | undefined {
  const n = asNode(x);
  const val = n?.[`@_${name}`];
  return typeof val === "string" && val.trim() ? val.trim() : undefined;
}

function isAudioOrVideo(type: string | undefined, url: string): boolean {
  if (type) return /^(audio|video)\//i.test(type) || /octet-stream|x-m4a|mpeg/i.test(type);
  return /\.(mp3|m4a|aac|ogg|opus|wav|flac|mp4|m4v|mov)(\?|$)/i.test(url);
}

function parseExplicit(raw: string | undefined): boolean | undefined {
  if (!raw) return undefined;
  const s = raw.toLowerCase();
  if (["yes", "true", "explicit"].includes(s)) return true;
  if (["no", "false", "clean"].includes(s)) return false;
  return undefined;
}

function resolveUrl(url: string | undefined, base: string | undefined): string | undefined {
  if (!url) return undefined;
  try {
    return new URL(url, base).toString();
  } catch {
    return url;
  }
}

export function parseFeed(xml: string, feedUrl?: string): ParsedFeed {
  let doc: Node;
  try {
    doc = parser.parse(xml) as Node;
  } catch (e) {
    throw new FeedParseError(`Not valid XML: ${(e as Error).message}`);
  }
  const rss = asNode(doc.rss) ?? asNode(doc["rdf:RDF"]);
  if (rss) return parseRss(rss, feedUrl);
  const atom = asNode(doc.feed);
  if (atom) return parseAtom(atom, feedUrl);
  throw new FeedParseError("Not an RSS or Atom feed");
}

function parseRss(rss: Node, feedUrl?: string): ParsedFeed {
  const channel = asNode(rss.channel);
  if (!channel) throw new FeedParseError("RSS feed has no <channel>");
  const items = asArray(channel.item ?? rss.item);
  const feedArtwork =
    attr(channel["itunes:image"], "href") ?? text(asNode(channel.image)?.url) ?? attr(channel["media:thumbnail"], "url");
  const channelLink = asArray(channel.link)
    .map((l) => text(l) ?? attr(l, "href"))
    .find((l) => l && /^https?:/i.test(l));

  const episodes: ParsedEpisode[] = [];
  for (const raw of items) {
    const item = asNode(raw);
    if (!item) continue;
    const ep = parseRssItem(item, feedUrl);
    if (ep) episodes.push(ep);
  }
  return {
    format: "rss",
    title: text(channel.title) ?? text(channel["itunes:title"]) ?? "Untitled podcast",
    author: text(channel["itunes:author"]) ?? text(channel["managingEditor"]) ?? text(asNode(channel["itunes:owner"])?.["itunes:name"]),
    description: text(channel.description) ?? text(channel["itunes:summary"]),
    artworkUrl: resolveUrl(feedArtwork, feedUrl),
    link: channelLink,
    language: text(channel.language),
    newFeedUrl: text(channel["itunes:new-feed-url"]),
    episodes: sortAndDedupe(episodes),
  };
}

function parseRssItem(item: Node, feedUrl?: string): ParsedEpisode | undefined {
  const enclosures = [...asArray(item.enclosure), ...asArray(item["media:content"])];
  let enclosureUrl: string | undefined;
  let enclosureType: string | undefined;
  let enclosureLength: number | undefined;
  for (const e of enclosures) {
    const url = attr(e, "url");
    if (!url) continue;
    const type = attr(e, "type");
    if (!isAudioOrVideo(type, url)) continue;
    enclosureUrl = resolveUrl(url, feedUrl);
    enclosureType = type;
    enclosureLength = parseIntOrUndefined(attr(e, "length") ?? attr(e, "fileSize"));
    if (enclosureLength === 0) enclosureLength = undefined;
    break;
  }
  if (!enclosureUrl) return undefined;

  const showNotesHtml = text(item["content:encoded"]) ?? text(item.description) ?? text(item["itunes:summary"]);
  const chapters = asNode(item["podcast:chapters"]);
  const title = text(item.title) ?? text(item["itunes:title"]) ?? snippet(showNotesHtml, 80) ?? "Untitled episode";
  return {
    guid: text(item.guid),
    enclosureUrl,
    enclosureType,
    enclosureLength,
    title,
    showNotesHtml,
    summary: snippet(text(item["itunes:subtitle"]) ?? showNotesHtml),
    link: text(item.link),
    pubDate: parseDate(text(item.pubDate) ?? text(item["dc:date"]) ?? text(item.published)),
    duration: parseDuration(text(item["itunes:duration"])),
    chaptersUrl: attr(chapters, "url"),
    chaptersType: attr(chapters, "type"),
    transcripts: asArray(item["podcast:transcript"]).flatMap((t) => {
      const url = attr(t, "url");
      if (!url) return [];
      return [{ url, type: attr(t, "type") ?? "text/plain", language: attr(t, "language"), rel: attr(t, "rel") }];
    }),
    artworkUrl: resolveUrl(attr(item["itunes:image"], "href") ?? attr(item["media:thumbnail"], "url"), feedUrl),
    season: parseIntOrUndefined(text(item["itunes:season"])),
    episodeNumber: parseIntOrUndefined(text(item["itunes:episode"])),
    episodeType: text(item["itunes:episodeType"])?.toLowerCase(),
    explicit: parseExplicit(text(item["itunes:explicit"])),
  };
}

function parseAtom(feed: Node, feedUrl?: string): ParsedFeed {
  const links = asArray(feed.link);
  const alternate = links.find((l) => (attr(l, "rel") ?? "alternate") === "alternate");
  const episodes: ParsedEpisode[] = [];
  for (const raw of asArray(feed.entry)) {
    const entry = asNode(raw);
    if (!entry) continue;
    const entryLinks = asArray(entry.link);
    const enc = entryLinks.find((l) => attr(l, "rel") === "enclosure" && attr(l, "href"));
    const href = attr(enc, "href");
    if (!href) continue;
    const showNotesHtml = text(entry.content) ?? text(entry.summary);
    const page = entryLinks.find((l) => (attr(l, "rel") ?? "alternate") === "alternate");
    const title = text(entry.title) ?? snippet(showNotesHtml, 80) ?? "Untitled episode";
    episodes.push({
      guid: text(entry.id),
      enclosureUrl: resolveUrl(href, feedUrl)!,
      enclosureType: attr(enc, "type"),
      enclosureLength: parseIntOrUndefined(attr(enc, "length")) || undefined,
      title,
      showNotesHtml,
      summary: snippet(text(entry.summary) ?? showNotesHtml),
      link: attr(page, "href"),
      pubDate: parseDate(text(entry.published) ?? text(entry.updated)),
      duration: parseDuration(text(entry["itunes:duration"])),
      chaptersUrl: attr(entry["podcast:chapters"], "url"),
      chaptersType: attr(entry["podcast:chapters"], "type"),
      transcripts: asArray(entry["podcast:transcript"]).flatMap((t) => {
        const url = attr(t, "url");
        return url ? [{ url, type: attr(t, "type") ?? "text/plain", language: attr(t, "language"), rel: attr(t, "rel") }] : [];
      }),
      artworkUrl: attr(entry["itunes:image"], "href"),
    });
  }
  const author = asNode(feed.author);
  return {
    format: "atom",
    title: text(feed.title) ?? "Untitled podcast",
    author: text(author?.name) ?? text(feed["itunes:author"]),
    description: text(feed.subtitle) ?? text(feed["itunes:summary"]),
    artworkUrl: resolveUrl(attr(feed["itunes:image"], "href") ?? text(feed.logo) ?? text(feed.icon), feedUrl),
    link: attr(alternate, "href"),
    language: attr(feed, "xml:lang"),
    newFeedUrl: text(feed["itunes:new-feed-url"]),
    episodes: sortAndDedupe(episodes),
  };
}

/** Newest first; drop repeats of the same GUID (or enclosure when there's no GUID). */
function sortAndDedupe(episodes: ParsedEpisode[]): ParsedEpisode[] {
  const seen = new Set<string>();
  const out: ParsedEpisode[] = [];
  for (const ep of episodes) {
    const key = ep.guid ? `g:${ep.guid}` : `u:${ep.enclosureUrl}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(ep);
  }
  return out
    .map((ep, i) => ({ ep, i }))
    .sort((a, b) => (b.ep.pubDate ?? -Infinity) - (a.ep.pubDate ?? -Infinity) || a.i - b.i)
    .map(({ ep }) => ep);
}

/** Find `<link rel="alternate" type="application/rss+xml" href="…">` in an HTML page. */
export function discoverFeedLink(html: string, pageUrl: string): string | undefined {
  const re = /<link\b[^>]*>/gi;
  for (const tag of html.match(re) ?? []) {
    if (!/rel=["']?alternate/i.test(tag)) continue;
    if (!/type=["']?application\/(rss|atom)\+xml/i.test(tag)) continue;
    const href = /href=["']([^"']+)["']/i.exec(tag)?.[1];
    if (href) return resolveUrl(href, pageUrl);
  }
  return undefined;
}
