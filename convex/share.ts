import { v } from "convex/values";
import { query } from "./_generated/server";
import { shareEpisode, shareShow, vShareEpisode, vShareShowPage } from "./lib/sharePages";

// The only public functions that need no sign-in: the website's episode and show
// pages. They return shared catalogue data and nothing personal, and private
// feeds come back as null, the same as an id that doesn't exist (lib/sharePages.ts).

export const episode = query({
  args: { episodeId: v.string() },
  returns: v.union(vShareEpisode, v.null()),
  handler: async (ctx, { episodeId }) => await shareEpisode(ctx, episodeId),
});

export const show = query({
  args: { podcastId: v.string() },
  returns: v.union(vShareShowPage, v.null()),
  handler: async (ctx, { podcastId }) => await shareShow(ctx, podcastId),
});
