import { v, type Infer } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { vTranscript } from "../schema";
import { enclosureKey } from "./parse";

// Episode upserts from a parsed feed. Only feed-owned fields are ever written;
// user state lives in episodeStates and is never touched here.

export const vIncomingEpisode = v.object({
  guid: v.optional(v.string()),
  enclosureUrl: v.string(),
  enclosureType: v.optional(v.string()),
  enclosureLength: v.optional(v.number()),
  title: v.string(),
  showNotesHtml: v.optional(v.string()),
  summary: v.optional(v.string()),
  link: v.optional(v.string()),
  pubDate: v.optional(v.number()),
  duration: v.optional(v.number()),
  chaptersUrl: v.optional(v.string()),
  chaptersType: v.optional(v.string()),
  transcripts: v.array(vTranscript),
  artworkUrl: v.optional(v.string()),
  season: v.optional(v.number()),
  episodeNumber: v.optional(v.number()),
  episodeType: v.optional(v.string()),
  explicit: v.optional(v.boolean()),
});
export type IncomingEpisode = Infer<typeof vIncomingEpisode>;

/** "initial": first fetch after subscribing; "import": Overcast import, no new-episode rules. */
export const vIngestMode = v.union(v.literal("initial"), v.literal("normal"), v.literal("import"));
export type IngestMode = Infer<typeof vIngestMode>;

const DAY = 86_400_000;

type Match = { guid?: string; enclosureUrl?: string; title?: string; pubDate?: number };

/** Fallback matches only hit episodes without a GUID of their own (or import ghosts). */
const compatibleWith = (match: Match) => (e: Doc<"episodes">) =>
  !e.guid || e.isGhost || !match.guid || e.guid === match.guid;

export async function findByGuid(ctx: QueryCtx, podcastId: Id<"podcasts">, guid: string | undefined) {
  if (!guid) return null;
  return await ctx.db
    .query("episodes")
    .withIndex("by_podcast_guid", (q) => q.eq("podcastId", podcastId).eq("guid", guid))
    .first();
}

export async function findByEnclosure(ctx: QueryCtx, podcastId: Id<"podcasts">, match: Match) {
  const key = enclosureKey(match.enclosureUrl);
  if (!key) return null;
  const hits = await ctx.db
    .query("episodes")
    .withIndex("by_podcast_enclosureKey", (q) => q.eq("podcastId", podcastId).eq("enclosureKey", key))
    .take(5);
  return hits.find(compatibleWith(match)) ?? null;
}

/** Same title, published within a day of each other. */
export async function findByTitleDate(ctx: QueryCtx, podcastId: Id<"podcasts">, match: Match) {
  if (!match.title || match.pubDate === undefined) return null;
  const hits = await ctx.db
    .query("episodes")
    .withIndex("by_podcast_title", (q) => q.eq("podcastId", podcastId).eq("title", match.title!))
    .take(10);
  return (
    hits.find((e) => compatibleWith(match)(e) && e.pubDate !== undefined && Math.abs(e.pubDate - match.pubDate!) < DAY) ??
    null
  );
}

/**
 * Episode identity: GUID, then enclosure URL (query stripped), then title + pubDate.
 * The fallbacks only match episodes that have no GUID of their own (or ghosts
 * from an import), so two distinct items that share an enclosure aren't merged.
 */
export async function findExistingEpisode(ctx: QueryCtx, podcastId: Id<"podcasts">, match: Match) {
  return (
    (await findByGuid(ctx, podcastId, match.guid)) ??
    (await findByEnclosure(ctx, podcastId, match)) ??
    (await findByTitleDate(ctx, podcastId, match))
  );
}

type FeedFields = Omit<IncomingEpisode, "showNotesHtml">;
const FEED_FIELDS: (keyof FeedFields)[] = [
  "guid",
  "enclosureUrl",
  "enclosureType",
  "enclosureLength",
  "title",
  "summary",
  "link",
  "pubDate",
  "duration",
  "chaptersUrl",
  "chaptersType",
  "transcripts",
  "artworkUrl",
  "season",
  "episodeNumber",
  "episodeType",
  "explicit",
];

function changedFields(existing: Doc<"episodes">, incoming: IncomingEpisode): Partial<Doc<"episodes">> {
  const patch: Record<string, unknown> = {};
  for (const f of FEED_FIELDS) {
    const next = incoming[f];
    // Keep what we know rather than blanking it (e.g. a feed dropping durations).
    if (next === undefined && f !== "chaptersUrl") continue;
    if (JSON.stringify(existing[f]) !== JSON.stringify(next)) patch[f] = next;
  }
  const key = enclosureKey(incoming.enclosureUrl);
  if (existing.enclosureKey !== key) patch.enclosureKey = key;
  if (existing.isGhost) patch.isGhost = false;
  return patch as Partial<Doc<"episodes">>;
}

export async function upsertEpisode(
  ctx: MutationCtx,
  podcastId: Id<"podcasts">,
  incoming: IncomingEpisode,
  now: number,
): Promise<{ episode: Doc<"episodes">; created: boolean }> {
  const existing = await findExistingEpisode(ctx, podcastId, incoming);
  const { showNotesHtml, ...fields } = incoming;
  let episodeId: Id<"episodes">;
  let created = false;
  if (existing) {
    episodeId = existing._id;
    const patch = changedFields(existing, incoming);
    if (Object.keys(patch).length) await ctx.db.patch(episodeId, { ...patch, updatedAt: now });
  } else {
    episodeId = await ctx.db.insert("episodes", {
      ...fields,
      podcastId,
      enclosureKey: enclosureKey(incoming.enclosureUrl),
      isGhost: false,
      firstSeenAt: now,
      updatedAt: now,
    });
    created = true;
  }
  if (showNotesHtml !== undefined) await upsertNotes(ctx, episodeId, showNotesHtml, now);
  return { episode: (await ctx.db.get(episodeId))!, created };
}

async function upsertNotes(ctx: MutationCtx, episodeId: Id<"episodes">, html: string, now: number) {
  const existing = await ctx.db
    .query("episodeNotes")
    .withIndex("by_episode", (q) => q.eq("episodeId", episodeId))
    .unique();
  if (!existing) await ctx.db.insert("episodeNotes", { episodeId, html, updatedAt: now });
  else if (existing.html !== html) await ctx.db.patch(existing._id, { html, updatedAt: now });
}
