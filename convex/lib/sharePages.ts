import { v, type Infer } from "convex/values";
import type { Doc } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";
import { htmlToText, looksPrivate, snippet } from "./parse";

// The website's public pages (/e/<id> and /s/<id>) and their link previews.
// Shows and episodes are shared catalogue data, so they can be public, with
// two rules:
// - A private feed never gets a page: one flagged private, one whose feed URL
//   carries credentials or a token, or one anyone has switched to private in
//   their library. Its episodes don't either, and an episode whose enclosure URL
//   carries a token is treated the same way. All of these read as "not found".
// - Only the fields the pages show go out. Nothing personal is ever read here.

const RECENT_EPISODES = 20;
const SUMMARY_CHARS = 280;

export const vShareShow = v.object({
  _id: v.id("podcasts"),
  title: v.string(),
  author: v.optional(v.string()),
  description: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
  link: v.optional(v.string()),
  feedUrl: v.string(),
  episodeCount: v.number(),
  latestEpisodeAt: v.optional(v.number()),
});

export const vShareEpisodeSummary = v.object({
  _id: v.id("episodes"),
  title: v.string(),
  pubDate: v.optional(v.number()),
  duration: v.optional(v.number()),
  summary: v.optional(v.string()),
});

export const vSharePodcast = v.object({
  _id: v.id("podcasts"),
  title: v.string(),
  author: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
});

export const vShareEpisode = v.object({
  _id: v.id("episodes"),
  title: v.string(),
  pubDate: v.optional(v.number()),
  duration: v.optional(v.number()),
  summary: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
  /** Absent for episodes no longer in the feed (ghosts from the Overcast import). */
  audioUrl: v.optional(v.string()),
  audioType: v.optional(v.string()),
  season: v.optional(v.number()),
  episodeNumber: v.optional(v.number()),
  /** Unsanitised feed HTML: the page sanitises it before showing it. */
  showNotesHtml: v.optional(v.string()),
  podcast: vSharePodcast,
});

export const vShareShowPage = v.object({ show: vShareShow, episodes: v.array(vShareEpisodeSummary) });

export type ShareEpisode = Infer<typeof vShareEpisode>;
export type ShareShowPage = Infer<typeof vShareShowPage>;

/** A URL that's safe to show anyone: http(s), with no credentials or token-ish parts. */
export function isPublicUrl(url: string | undefined): url is string {
  if (!url) return false;
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" && u.protocol !== "http:") return false;
  } catch {
    return false;
  }
  return !looksPrivate(url);
}

/** Whether a show may have a public page. */
export async function isPublicShow(ctx: QueryCtx, show: Doc<"podcasts">): Promise<boolean> {
  if (show.isPrivate || !isPublicUrl(show.feedUrl)) return false;
  // Every library row for the show, subscribed or not: one person's "private"
  // switch keeps it off the web for everyone.
  const rows = await ctx.db
    .query("subscriptions")
    .withIndex("by_podcast_subscribed", (q) => q.eq("podcastId", show._id))
    .collect();
  return !rows.some((r) => r.isPrivate === true);
}

/** Feed HTML as plain text. Inline tags go without a trace so "<b>things</b>." doesn't read "things .". */
function plainText(html: string | undefined): string | undefined {
  if (!html) return undefined;
  const text = htmlToText(html.replace(/<\/?(a|b|i|em|strong|span|u|small|code)\b[^>]*>/gi, ""));
  return text || undefined;
}

function oneLine(html: string | undefined): string | undefined {
  return snippet(plainText(html), SUMMARY_CHARS);
}

export async function shareEpisode(ctx: QueryCtx, rawId: string): Promise<ShareEpisode | null> {
  const id = ctx.db.normalizeId("episodes", rawId);
  if (!id) return null;
  const episode = await ctx.db.get(id);
  if (!episode) return null;
  const show = await ctx.db.get(episode.podcastId);
  if (!show || !(await isPublicShow(ctx, show))) return null;
  // An enclosure with a token in it means a private feed, whatever the show says.
  if (episode.enclosureUrl && !isPublicUrl(episode.enclosureUrl)) return null;
  const notes = await ctx.db
    .query("episodeNotes")
    .withIndex("by_episode", (q) => q.eq("episodeId", id))
    .unique();
  return {
    _id: episode._id,
    title: episode.title,
    pubDate: episode.pubDate,
    duration: episode.duration,
    summary: oneLine(episode.summary ?? notes?.html),
    artworkUrl: isPublicUrl(episode.artworkUrl) ? episode.artworkUrl : isPublicUrl(show.artworkUrl) ? show.artworkUrl : undefined,
    audioUrl: episode.isGhost ? undefined : episode.enclosureUrl,
    audioType: episode.isGhost ? undefined : episode.enclosureType,
    season: episode.season,
    episodeNumber: episode.episodeNumber,
    showNotesHtml: notes?.html,
    podcast: {
      _id: show._id,
      title: show.title,
      author: show.author,
      artworkUrl: isPublicUrl(show.artworkUrl) ? show.artworkUrl : undefined,
    },
  };
}

export async function shareShow(ctx: QueryCtx, rawId: string): Promise<ShareShowPage | null> {
  const id = ctx.db.normalizeId("podcasts", rawId);
  if (!id) return null;
  const show = await ctx.db.get(id);
  if (!show || !(await isPublicShow(ctx, show))) return null;
  const recent = await ctx.db
    .query("episodes")
    .withIndex("by_podcast_pubDate", (q) => q.eq("podcastId", id))
    .order("desc")
    .take(RECENT_EPISODES * 2);
  const episodes = recent
    .filter((e) => !e.isGhost && (!e.enclosureUrl || isPublicUrl(e.enclosureUrl)))
    .slice(0, RECENT_EPISODES)
    .map((e) => ({ _id: e._id, title: e.title, pubDate: e.pubDate, duration: e.duration, summary: oneLine(e.summary) }));
  return {
    show: {
      _id: show._id,
      title: show.title,
      author: show.author,
      description: plainText(show.description),
      artworkUrl: isPublicUrl(show.artworkUrl) ? show.artworkUrl : undefined,
      link: isPublicUrl(show.link) ? show.link : undefined,
      feedUrl: show.feedUrl,
      episodeCount: show.episodeCount,
      latestEpisodeAt: show.latestEpisodeAt,
    },
    episodes,
  };
}
