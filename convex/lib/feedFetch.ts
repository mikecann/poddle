import type { FunctionReturnType } from "convex/server";
import { ConvexError } from "convex/values";
import { internal } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import type { ActionCtx } from "../_generated/server";
import { discoverFeedLink, FeedParseError, parseFeed, type ParsedFeed } from "./feedParser";
import type { IncomingEpisode, IngestMode } from "./ingest";
import { truncate } from "./parse";

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
      // Neither step may throw: falling through would hand fetch the URL with its credentials,
      // and fetch's error message quotes that URL into the logs.
      headers.Authorization = `Basic ${base64Utf8(`${decodeLoosely(u.username)}:${decodeLoosely(u.password)}`)}`;
      u.username = "";
      u.password = "";
      return { url: u.toString(), headers };
    }
  } catch {
    // Not a URL at all. Leave it to fetch to complain.
  }
  return { url, headers };
}

function decodeLoosely(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s; // A stray % that isn't an escape.
  }
}

/** btoa only takes Latin-1, so a password like "漢" threw. Encode the UTF-8 bytes instead. */
function base64Utf8(s: string): string {
  return btoa(Array.from(new TextEncoder().encode(s), (b) => String.fromCharCode(b)).join(""));
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

/**
 * Like `fetchWithTimeout`, but the deadline also covers reading the body, so a host that
 * sends its headers and then stalls can't hold a person's request open.
 */
export async function fetchText(
  url: string,
  init: RequestInit = {},
  timeoutMs = TIMEOUT_MS,
): Promise<{ res: Response; body: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...init, signal: controller.signal, redirect: "follow" });
    return { res, body: await res.text() };
  } finally {
    clearTimeout(timer);
  }
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Why a fetch got no response at all. Node's fetch throws a bare `TypeError: fetch failed`
 * and keeps the reason in `cause`: ENOTFOUND, ECONNREFUSED, UND_ERR_CONNECT_TIMEOUT, a
 * certificate error. That message alone told us nothing about PODDLE-E.
 *
 * Only codes and error names come back, never messages: those can quote the URL, and a
 * private feed's URL carries its token or password.
 */
export function fetchFailureCause(e: unknown): string {
  if (e instanceof Error && e.name === "AbortError") return "timeout";
  const cause = (e as { cause?: { code?: unknown; name?: unknown; errors?: { code?: unknown }[] } } | null)?.cause;
  // A host with several addresses fails with an AggregateError, one error per address.
  const code = cause?.code ?? cause?.errors?.find((x) => x?.code)?.code ?? (e as { code?: unknown } | null)?.code;
  if (typeof code === "string") return code;
  if (typeof cause?.name === "string") return cause.name;
  return e instanceof Error ? e.name : "unknown";
}

/** Just the host: a private feed's token lives in the path or query, and mustn't reach the logs. */
export function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return "that address";
  }
}

type Refusal = ConvexError<{ code: string; message: string }>;

/** Logs which host failed and why, and makes the error the person sees. */
export function unreachable(url: string, e: unknown): Refusal {
  const host = hostOf(url);
  const cause = fetchFailureCause(e);
  console.warn(`Couldn't fetch from ${host}`, cause);
  const message =
    cause === "ENOTFOUND" ? `Couldn't find ${host}. Check the address and try again.` : `Couldn't reach ${host}. Try again later.`;
  return new ConvexError({ code: "feedUnreachable", message });
}

/** Apple's directory (search, and Apple links), from a network error or an HTTP status. */
function appleUnreachable(url: string, why: unknown): Refusal {
  console.warn(`Couldn't fetch from ${hostOf(url)}`, typeof why === "number" ? `HTTP ${why}` : fetchFailureCause(why));
  return new ConvexError({ code: "appleUnreachable", message: "Couldn't reach Apple Podcasts. Try again later." });
}

/**
 * GETs JSON from Apple's directory. Anything short of a 2xx JSON answer in time (no answer,
 * an error status, a stalled body, an HTML outage page) is the same plain message.
 */
export async function appleJson<T>(url: string): Promise<T> {
  let got: { res: Response; body: string };
  try {
    got = await fetchText(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } }, 10_000);
  } catch (e) {
    throw appleUnreachable(url, e);
  }
  if (!got.res.ok) throw appleUnreachable(url, got.res.status);
  try {
    return JSON.parse(got.body) as T;
  } catch (e) {
    throw appleUnreachable(url, e);
  }
}

/**
 * Fetch a URL that should be a feed. Follows one `<link rel="alternate">` hop for website URLs.
 * Failures are ConvexErrors with a message for people: this backs adding a show by its link,
 * and prod hides any other error's text behind "Server Error".
 */
export async function fetchFeedDocument(feedUrl: string): Promise<{ feed: ParsedFeed; finalUrl: string }> {
  let url = feedUrl;
  for (let hop = 0; hop < 2; hop++) {
    const req = requestFor(url);
    let got: { res: Response; body: string };
    try {
      got = await fetchText(req.url, { headers: req.headers });
    } catch (e) {
      throw unreachable(req.url, e);
    }
    const { res, body } = got;
    if (!res.ok) {
      throw new ConvexError({ code: "feedHttp", message: `${hostOf(req.url)} answered with an error (HTTP ${res.status}).` });
    }
    try {
      return { feed: parseFeed(body, url), finalUrl: url };
    } catch (e) {
      const link = /<html/i.test(body) ? discoverFeedLink(body, res.url || url) : undefined;
      if (!link || hop > 0) {
        // The parser's message can quote the body, which could echo a private feed's token.
        console.warn(`No feed at ${hostOf(url)}`, e instanceof FeedParseError ? "not a feed" : fetchFailureCause(e));
        throw new ConvexError({ code: "notAFeed", message: "There's no podcast feed at that address." });
      }
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
  /** HTTP status of a failed fetch (absent for network and parse errors before a response). */
  httpStatus?: number;
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
    return { status: "error", newEpisodes: 0, error, httpStatus: status || undefined };
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
    out.showNotesHtml = truncate(out.showNotesHtml as string, MAX_NOTES_CHARS);
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
