import type { FunctionReturnType } from "convex/server";
import { internal } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import type { ActionCtx } from "../_generated/server";
import { discoverFeedLink, FeedParseError, parseFeed, type ParsedFeed } from "./feedParser";
import type { IncomingEpisode, IngestMode } from "./ingest";

// Fetch + parse + ingest, shared by the polling, refresh and import actions.

export const USER_AGENT = "Poddle/1.0 (+https://github.com/mikecann/poddle; podcast player)";
const TIMEOUT_MS = 20_000;
const MAX_NOTES_CHARS = 50_000;
/** Keep each ingest mutation's args well under Convex's limits. */
const CHUNK_BYTES = 400_000;
/** Pause between chunks so a huge back catalogue stays under the deployment's write-rate limit. */
const CHUNK_PAUSE_MS = 250;

/** Pulls `user:pass@` out of the URL into an Authorization header (fetch rejects credentials in URLs). */
export function requestFor(url: string): { url: string; headers: Record<string, string> } {
  const headers: Record<string, string> = { "User-Agent": USER_AGENT, Accept: "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5" };
  try {
    const u = new URL(url);
    if (u.username || u.password) {
      const creds = `${decodeURIComponent(u.username)}:${decodeURIComponent(u.password)}`;
      headers.Authorization = `Basic ${btoa(creds)}`;
      u.username = "";
      u.password = "";
      return { url: u.toString(), headers };
    }
  } catch {
    // Leave it to fetch to complain.
  }
  return { url, headers };
}

export async function fetchWithTimeout(url: string, init: RequestInit = {}, timeoutMs = TIMEOUT_MS): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal, redirect: "follow" });
  } finally {
    clearTimeout(timer);
  }
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Fetch a URL that should be a feed. Follows one `<link rel="alternate">` hop for website URLs. */
export async function fetchFeedDocument(feedUrl: string): Promise<{ feed: ParsedFeed; finalUrl: string }> {
  let url = feedUrl;
  for (let hop = 0; hop < 2; hop++) {
    const req = requestFor(url);
    const res = await fetchWithTimeout(req.url, { headers: req.headers });
    if (!res.ok) throw new Error(`HTTP ${res.status} fetching ${req.url}`);
    const body = await res.text();
    try {
      return { feed: parseFeed(body, url), finalUrl: url };
    } catch (e) {
      const link = /<html/i.test(body) ? discoverFeedLink(body, res.url || url) : undefined;
      if (!link || hop > 0) throw e;
      url = link;
    }
  }
  throw new FeedParseError("No feed found");
}

export type RefreshResult = {
  /** "busy": another fetch of this feed is already running. */
  status: "updated" | "notModified" | "unchanged" | "busy" | "error";
  newEpisodes: number;
  error?: string;
};

export async function refreshPodcast(
  ctx: ActionCtx,
  podcastId: Id<"podcasts">,
  opts: { mode?: IngestMode; force?: boolean } = {},
): Promise<RefreshResult> {
  const info = await ctx.runMutation(internal.feeds.claimFetch, { podcastId });
  if (!info) return { status: "busy", newEpisodes: 0 };
  try {
    return await fetchAndIngest(ctx, podcastId, info, opts);
  } catch (e) {
    // Always release the lease and record the failure (and its backoff).
    const error = `Failed: ${(e as Error).message}`;
    await ctx.runMutation(internal.feeds.recordFetch, { podcastId, status: 0, error, changed: false });
    return { status: "error", newEpisodes: 0, error };
  }
}

type FetchInfo = NonNullable<FunctionReturnType<typeof internal.feeds.claimFetch>>;

async function fetchAndIngest(
  ctx: ActionCtx,
  podcastId: Id<"podcasts">,
  info: FetchInfo,
  opts: { mode?: IngestMode; force?: boolean },
): Promise<RefreshResult> {

  const conditional = !opts.force && !info.isFirstFetch;
  const req = requestFor(info.feedUrl);
  if (conditional && info.etag) req.headers["If-None-Match"] = info.etag;
  if (conditional && info.lastModified) req.headers["If-Modified-Since"] = info.lastModified;

  const fail = async (status: number, error: string): Promise<RefreshResult> => {
    await ctx.runMutation(internal.feeds.recordFetch, { podcastId, status, error, changed: false });
    return { status: "error", newEpisodes: 0, error };
  };

  let res: Response;
  try {
    res = await fetchWithTimeout(req.url, { headers: req.headers });
  } catch (e) {
    return await fail(0, `Network error: ${(e as Error).message}`);
  }
  if (res.status === 304) {
    await ctx.runMutation(internal.feeds.recordFetch, { podcastId, status: 304, changed: false });
    return { status: "notModified", newEpisodes: 0 };
  }
  if (!res.ok) return await fail(res.status, `HTTP ${res.status}`);

  const body = await res.text();
  const etag = res.headers.get("etag") ?? undefined;
  const lastModified = res.headers.get("last-modified") ?? undefined;
  const bodyHash = await sha256Hex(body);
  if (conditional && bodyHash === info.bodyHash) {
    await ctx.runMutation(internal.feeds.recordFetch, { podcastId, status: res.status, etag, lastModified, changed: false });
    return { status: "unchanged", newEpisodes: 0 };
  }

  let feed: ParsedFeed;
  try {
    feed = parseFeed(body, info.feedUrl);
  } catch (e) {
    return await fail(res.status, `Parse error: ${(e as Error).message}`);
  }

  await ctx.runMutation(internal.feeds.updatePodcastMeta, {
    podcastId,
    title: feed.title,
    author: feed.author,
    description: feed.description,
    artworkUrl: feed.artworkUrl,
    link: feed.link,
    language: feed.language,
    newFeedUrl: feed.newFeedUrl,
  });

  const mode: IngestMode = opts.mode ?? (info.isFirstFetch ? "initial" : "normal");
  let newEpisodes = 0;
  for (const [i, chunk] of chunkEpisodes(feed.episodes.map(toIncoming)).entries()) {
    if (i > 0) await new Promise((r) => setTimeout(r, CHUNK_PAUSE_MS));
    const result = await ctx.runMutation(internal.feeds.ingestEpisodes, {
      podcastId,
      mode,
      isFirstChunk: i === 0,
      previousLatestAt: info.latestEpisodeAt,
      episodes: chunk,
    });
    newEpisodes += result.created;
  }
  await ctx.runMutation(internal.feeds.recordFetch, {
    podcastId,
    status: res.status,
    etag,
    lastModified,
    bodyHash,
    changed: newEpisodes > 0,
  });
  return { status: "updated", newEpisodes };
}

export function toIncoming(ep: ParsedFeed["episodes"][number]): IncomingEpisode {
  const out: Record<string, unknown> = {};
  for (const [k, val] of Object.entries(ep)) if (val !== undefined) out[k] = val;
  if (typeof out.showNotesHtml === "string" && out.showNotesHtml.length > MAX_NOTES_CHARS) {
    out.showNotesHtml = (out.showNotesHtml as string).slice(0, MAX_NOTES_CHARS);
  }
  return out as IncomingEpisode;
}

function chunkEpisodes(episodes: IncomingEpisode[]): IncomingEpisode[][] {
  const chunks: IncomingEpisode[][] = [];
  let current: IncomingEpisode[] = [];
  let bytes = 0;
  for (const ep of episodes) {
    const size = JSON.stringify(ep).length;
    if (current.length && (bytes + size > CHUNK_BYTES || current.length >= 100)) {
      chunks.push(current);
      current = [];
      bytes = 0;
    }
    current.push(ep);
    bytes += size;
  }
  if (current.length) chunks.push(current);
  return chunks;
}
