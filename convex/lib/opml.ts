import { XMLParser } from "fast-xml-parser";
import { normalizeFeedUrl, parseDate, parseIntOrUndefined, stripQuery } from "./parse";

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
  /** "chronological" or "reverse-chronological" (newest first). */
  sorting?: string;
  /** Shows a smart playlist is limited to. Empty means every show. */
  includePodcastIds: number[];
  /** Shows a smart playlist puts first. */
  priorityPodcastIds: number[];
  /** A manual playlist's episodes, in order. */
  includeEpisodeIds: number[];
  /** Episodes a smart playlist has been hand-sorted to put first, in order. */
  sortedEpisodeIds: number[];
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

  // The extended export marks every show subscribed="1" or leaves it off for
  // ones he's unsubscribed from. A plain subscriptions OPML never has it, and
  // everything in it is a subscription.
  const rss: Outline[] = [];
  const walk = (outlines: Outline[] | undefined) => {
    for (const o of outlines ?? []) {
      const type = str(o.type);
      if (type === "rss") rss.push(o);
      else if (type === "podcast-playlist") playlists.push(parsePlaylistOutline(o));
      else walk(o.outline);
    }
  };
  walk(body.outline);
  const hasSubscribedFlags = rss.some((o) => o.subscribed !== undefined);
  for (const o of rss) {
    const feed = parseFeedOutline(o, hasSubscribedFlags);
    if (!feed) continue;
    if (feed.episodes.length) hasEpisodeData = true;
    feeds.push(feed);
  }
  return { feeds, playlists, hasEpisodeData };
}

function parsePlaylistOutline(o: Outline): OvercastPlaylist {
  return {
    title: str(o.title) ?? str(o.text) ?? "Playlist",
    smart: str(o.smart) === "1",
    sorting: str(o.sorting),
    includePodcastIds: idList(o.includePodcastIds),
    priorityPodcastIds: idList(o.priorityPodcastIds),
    includeEpisodeIds: idList(o.includeEpisodeIds),
    sortedEpisodeIds: idList(o.sortedEpisodeIds),
  };
}

function idList(x: unknown): number[] {
  return (str(x) ?? "")
    .split(",")
    .map((id) => parseIntOrUndefined(id))
    .filter((id): id is number => id !== undefined);
}

function parseFeedOutline(o: Outline, hasSubscribedFlags: boolean): OvercastFeed | undefined {
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
      enclosureUrl: stripQuery(str(e.enclosureUrl)),
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
    subscribed: hasSubscribedFlags ? str(o.subscribed) === "1" : true,
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

/**
 * How to seed Up Next from Overcast's playlists (decisions.md). Overcast has no
 * Inbox: its main smart playlist ("All Episodes") is the queue. Its hand-sorted
 * episodes and every manual playlist's episodes go first, then its priority
 * shows, then everything else in its sort order.
 */
export type UpNextPlan = {
  /** Overcast episode IDs to put first, in order. */
  leadingEpisodeIds: number[];
  priorityPodcastIds: number[];
  newestFirst: boolean;
};

export function upNextPlan(playlists: OvercastPlaylist[]): UpNextPlan {
  const main =
    playlists.find((p) => p.smart && /^all episodes$/i.test(p.title)) ??
    playlists.find((p) => p.smart && (p.priorityPodcastIds.length > 0 || p.sortedEpisodeIds.length > 0)) ??
    playlists.find((p) => p.smart && p.includePodcastIds.length === 0);
  const leading = [...playlists.filter((p) => !p.smart).flatMap((p) => p.includeEpisodeIds), ...(main?.sortedEpisodeIds ?? [])];
  return {
    leadingEpisodeIds: [...new Set(leading)],
    priorityPodcastIds: main?.priorityPodcastIds ?? [],
    newestFirst: main?.sorting !== "chronological",
  };
}
