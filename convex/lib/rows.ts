import type { Doc, Id } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";
import { stateFor } from "./state";
import type { EpisodeRow } from "./validators";

export function podcastSummary(p: Doc<"podcasts">): EpisodeRow["podcast"] {
  return { _id: p._id, title: p.title, author: p.author, artworkUrl: p.artworkUrl, isPrivate: p.isPrivate };
}

/** Join episodes with their state and show, caching shows across the batch. */
export async function episodeRows(ctx: QueryCtx, episodes: Doc<"episodes">[]): Promise<EpisodeRow[]> {
  const shows = new Map<Id<"podcasts">, Doc<"podcasts"> | null>();
  const rows: EpisodeRow[] = [];
  for (const episode of episodes) {
    if (!shows.has(episode.podcastId)) shows.set(episode.podcastId, await ctx.db.get(episode.podcastId));
    const podcast = shows.get(episode.podcastId);
    if (!podcast) continue;
    rows.push({ episode, state: await stateFor(ctx, episode._id), podcast: podcastSummary(podcast) });
  }
  return rows;
}
