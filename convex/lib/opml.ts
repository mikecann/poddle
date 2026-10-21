import { XMLParser } from "fast-xml-parser";
import { enclosureKey, normalizeFeedUrl, parseDate, parseIntOrUndefined } from "./parse";

// Overcast "All data" export (https://overcast.fm/account/export_opml/extended).
// Format per hbmartin/overcast-to-sqlite: <body><outline text="playlists">…</outline>
// <outline text="feeds"><outline type="rss" …><outline type="podcast-episode" …/></outline></outline></body>.
// Plain subscription OPML (type="rss" outlines, maybe nested in folders) parses too,
// with no episodes.

export type OvercastEpisode = {
  overcastId: number;
  title: string;
  url?: string;
  overcastUrl?: string;
  /** Query string stripped, as overcast-to-sqlite does. */
  enclosureUrl?: string;
  pubDate?: number;
  played: boolean;
  progress?: number;
  userDeleted: boolean;
  userUpdatedAt?: number;
  userRecommendedAt?: number;
};

export type OvercastFeed = {
  overcastId?: number;
  title: string;
  feedUrl: string;
  htmlUrl?: string;
  subscribed: boolean;
  notifications: boolean;
  addedAt?: number;
  episodes: OvercastEpisode[];
};

export type OvercastPlaylist = {
  title: string;
  smart: boolean;
  sorting?: string;
  includePodcastIds: number[];
};

export type OvercastExport = {
  feeds: OvercastFeed[];
  playlists: OvercastPlaylist[];
  /** False for a plain subscriptions export: no episode state to import. */
  hasEpisodeData: boolean;
};

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  parseAttributeValue: false,
  parseTagValue: false,
  processEntities: true,
  htmlEntities: true,
  isArray: (name) => name === "outline",
});

type Outline = Record<string, unknown> & { outline?: Outline[] };

export function parseOvercastOpml(xml: string): OvercastExport {
  const doc = parser.parse(xml) as { opml?: { body?: Outline } };
  const body = doc.opml?.body;
  if (!body) throw new Error("Not an OPML file");

  const feeds: OvercastFeed[] = [];
  const playlists: OvercastPlaylist[] = [];
  let hasEpisodeData = false;

  const walk = (outlines: Outline[] | undefined) => {
    for (const o of outlines ?? []) {
      const type = str(o.type);
      if (type === "rss") {
        const feed = parseFeedOutline(o);
        if (feed) {
          if (feed.episodes.length) hasEpisodeData = true;
          feeds.push(feed);
        }
      } else if (type === "podcast-playlist") {
        const ids = str(o.includePodcastIds);
        if (ids) {
          playlists.push({
            title: str(o.title) ?? str(o.text) ?? "Playlist",
            smart: str(o.smart) === "1",
            sorting: str(o.sorting),
            includePodcastIds: ids
              .split(",")
              .map((x) => parseIntOrUndefined(x))
              .filter((x): x is number => x !== undefined),
          });
        }
      } else {
        walk(o.outline);
      }
    }
  };
  walk(body.outline);
  return { feeds, playlists, hasEpisodeData };
}

function parseFeedOutline(o: Outline): OvercastFeed | undefined {
  const xmlUrl = str(o.xmlUrl);
  if (!xmlUrl) return undefined;
  const episodes: OvercastEpisode[] = [];
  for (const e of o.outline ?? []) {
    if (str(e.type) !== "podcast-episode") continue;
    const overcastId = parseIntOrUndefined(e.overcastId);
    if (overcastId === undefined) continue;
    episodes.push({
      overcastId,
      title: str(e.title) ?? "",
      url: str(e.url),
      overcastUrl: str(e.overcastUrl),
      enclosureUrl: enclosureKey(str(e.enclosureUrl)),
      pubDate: parseDate(str(e.pubDate)),
      played: str(e.played) === "1",
      progress: parseIntOrUndefined(e.progress),
      userDeleted: str(e.userDeleted) === "1",
      userUpdatedAt: parseDate(str(e.userUpdatedDate)),
      userRecommendedAt: parseDate(str(e.userRecommendedDate)),
    });
  }
  return {
    overcastId: parseIntOrUndefined(o.overcastId),
    title: str(o.title) ?? str(o.text) ?? xmlUrl,
    feedUrl: normalizeFeedUrl(xmlUrl),
    htmlUrl: str(o.htmlUrl),
    // A plain OPML has no `subscribed` attribute: everything in it is a subscription.
    subscribed: o.subscribed === undefined ? true : str(o.subscribed) === "1",
    notifications: str(o.notifications) === "1",
    addedAt: parseDate(str(o.overcastAddedDate)),
    episodes,
  };
}

function str(x: unknown): string | undefined {
  if (x === undefined || x === null) return undefined;
  const s = String(x).trim();
  return s ? s : undefined;
}

/** overcast-to-sqlite's rule: an episode counts as listened if played or progress > 300 s. */
export function countsAsListened(e: Pick<OvercastEpisode, "played" | "progress">): boolean {
  return e.played || (e.progress ?? 0) > 300;
}
