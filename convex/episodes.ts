import { v } from "convex/values";
import { userMutation, userQuery } from "./lib/auth";
import { addToQueue } from "./lib/queue";
import { episodeRows } from "./lib/rows";
import { requireEpisode, setArchived, setInbox, setPlayed, setPosition, setStarred } from "./lib/state";
import { vEpisodeRow } from "./lib/validators";

// Episodes and per-episode user state. All writes are last-writer-wins on the
// client timestamp `at`, so they're safe to replay from the offline outbox.

const INBOX_LIMIT = 500;

/** The Inbox, newest first. */
export const inbox = userQuery({
  args: {},
  returns: v.array(vEpisodeRow),
  handler: async (ctx) => {
    const states = await ctx.db
      .query("episodeStates")
      .withIndex("by_user_inbox", (q) => q.eq("userId", ctx.userId).eq("inInbox", true))
      .order("desc")
      .take(INBOX_LIMIT);
    const episodes = [];
    for (const s of states) {
      const e = await ctx.db.get(s.episodeId);
      if (e) episodes.push(e);
    }
    return await episodeRows(ctx, episodes);
  },
});

/** Starred episodes, most recently starred first. */
export const starred = userQuery({
  args: {},
  returns: v.array(vEpisodeRow),
  handler: async (ctx) => {
    const states = await ctx.db
      .query("episodeStates")
      .withIndex("by_user_starred", (q) => q.eq("userId", ctx.userId).eq("starred", true))
      .order("desc")
      .take(500);
    const episodes = [];
    for (const s of states) {
      const e = await ctx.db.get(s.episodeId);
      if (e) episodes.push(e);
    }
    return await episodeRows(ctx, episodes);
  },
});

/** One episode with its state, show and show notes HTML. */
export const get = userQuery({
  args: { episodeId: v.id("episodes") },
  returns: v.union(v.null(), v.object({ row: vEpisodeRow, showNotesHtml: v.optional(v.string()), inQueue: v.boolean() })),
  handler: async (ctx, { episodeId }) => {
    const episode = await ctx.db.get(episodeId);
    if (!episode) return null;
    const [row] = await episodeRows(ctx, [episode]);
    if (!row) return null;
    const notes = await ctx.db
      .query("episodeNotes")
      .withIndex("by_episode", (q) => q.eq("episodeId", episodeId))
      .unique();
    const queued = await ctx.db
      .query("queueItems")
      .withIndex("by_user_episode", (q) => q.eq("userId", ctx.userId).eq("episodeId", episodeId))
      .unique();
    return { row, showNotesHtml: notes?.html, inQueue: queued !== null };
  },
});

/**
 * Save the playback position. Last-writer-wins on `positionUpdatedAt` (client
 * clock); returns false if a newer position was already stored.
 */
export const updatePosition = userMutation({
  args: {
    episodeId: v.id("episodes"),
    position: v.number(),
    positionUpdatedAt: v.number(),
    deviceId: v.string(),
  },
  returns: v.boolean(),
  handler: async (ctx, a) => {
    const episode = await requireEpisode(ctx, a.episodeId);
    return await setPosition(ctx, episode, a.position, a.positionUpdatedAt, a.deviceId);
  },
});

/** Mark played or unplayed. Marking played also removes it from the Inbox and Up Next. */
export const setPlayedState = userMutation({
  args: { episodeId: v.id("episodes"), played: v.boolean(), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, played, at }) => {
    return await setPlayed(ctx, await requireEpisode(ctx, episodeId), played, at);
  },
});

export const setStarredState = userMutation({
  args: { episodeId: v.id("episodes"), starred: v.boolean(), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, starred, at }) => {
    return await setStarred(ctx, await requireEpisode(ctx, episodeId), starred, at);
  },
});

/** Archive (or unarchive). Archiving removes it from the Inbox. */
export const setArchivedState = userMutation({
  args: { episodeId: v.id("episodes"), archived: v.boolean(), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, archived, at }) => {
    return await setArchived(ctx, await requireEpisode(ctx, episodeId), archived, at);
  },
});

/** Put an episode (back) into the Inbox, e.g. from a show page. */
export const addToInbox = userMutation({
  args: { episodeId: v.id("episodes"), at: v.number() },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, at }) => {
    const episode = await requireEpisode(ctx, episodeId);
    return await setInbox(ctx, episode, true, at, episode.pubDate ?? at);
  },
});

/**
 * Inbox swipe actions in one call: queue last / queue next move it to Up Next
 * (and out of the Inbox); archive and markPlayed do what they say.
 */
export const inboxAction = userMutation({
  args: {
    episodeId: v.id("episodes"),
    action: v.union(v.literal("queueLast"), v.literal("queueNext"), v.literal("archive"), v.literal("markPlayed")),
    at: v.number(),
  },
  returns: v.boolean(),
  handler: async (ctx, { episodeId, action, at }) => {
    const episode = await requireEpisode(ctx, episodeId);
    switch (action) {
      case "queueLast":
      case "queueNext": {
        const added = await addToQueue(ctx, episode, action === "queueLast" ? "bottom" : "next", at, "manual");
        await setInbox(ctx, episode, false, at);
        return added;
      }
      case "archive":
        return await setArchived(ctx, episode, true, at);
      case "markPlayed":
        return await setPlayed(ctx, episode, true, at);
    }
  },
});

/** "Archive all older from this show": archives the show's Inbox episodes published before this one. */
export const archiveAllOlder = userMutation({
  args: { episodeId: v.id("episodes"), at: v.number(), includeThis: v.optional(v.boolean()) },
  returns: v.number(),
  handler: async (ctx, { episodeId, at, includeThis }) => {
    const pivot = await requireEpisode(ctx, episodeId);
    const inInbox = await ctx.db
      .query("episodeStates")
      .withIndex("by_user_podcast_inbox", (q) => q.eq("userId", ctx.userId).eq("podcastId", pivot.podcastId).eq("inInbox", true))
      .collect();
    let n = 0;
    for (const s of inInbox) {
      const e = await ctx.db.get(s.episodeId);
      if (!e) continue;
      const older = e._id === pivot._id ? !!includeThis : (e.pubDate ?? 0) < (pivot.pubDate ?? 0);
      if (older && (await setArchived(ctx, e, true, at))) n++;
    }
    return n;
  },
});
