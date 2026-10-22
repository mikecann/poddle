import type { Doc } from "../_generated/dataModel";
import type { UserQueryCtx } from "./auth";
import { showCache } from "./library";
import { stateFor } from "./state";
import type { EpisodeRow } from "./validators";

export function podcastSummary(p: { _id: Doc<"podcasts">["_id"]; title: string; author?: string; artworkUrl?: string; isPrivate: boolean }): EpisodeRow["podcast"] {
  return { _id: p._id, title: p.title, author: p.author, artworkUrl: p.artworkUrl, isPrivate: p.isPrivate };
}

/** Join episodes with this person's state and the show, caching shows across the batch. */
export async function episodeRows(ctx: UserQueryCtx, episodes: Doc<"episodes">[]): Promise<EpisodeRow[]> {
  const show = showCache(ctx);
  const rows: EpisodeRow[] = [];
  for (const episode of episodes) {
    const podcast = await show(episode.podcastId);
    if (!podcast) continue;
    rows.push({ episode, state: await stateFor(ctx, episode._id), podcast: podcastSummary(podcast) });
  }
  return rows;
}
