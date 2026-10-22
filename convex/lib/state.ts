import type { Doc, Id } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";
import type { UserMutationCtx as MutationCtx, UserQueryCtx } from "./auth";
import { ensureLibraryRow } from "./library";
import { removeFromQueue } from "./queue";
import { applyCompletion } from "./rollups";
import { resolveGlobalSettings } from "./settings";
import { localDay, zoneOffsetMinutes } from "./statsMath";

// Per-episode state for the person in `ctx.userId`. Each field is last-writer-wins on a client timestamp;
// ties go to the write the server sees last.

/**
 * LWW time for changes the server makes on its own (auto-adding a new episode,
 * auto-archive). Backdated so a user action on a device whose clock runs a
 * little behind still beats it.
 */
export const SYSTEM_CLOCK_SLACK_MS = 10 * 60_000;
export const systemAt = (now = Date.now()) => now - SYSTEM_CLOCK_SLACK_MS;

export async function stateFor(ctx: UserQueryCtx, episodeId: Id<"episodes">) {
  return await ctx.db
    .query("episodeStates")
    .withIndex("by_user_episode", (q) => q.eq("userId", ctx.userId).eq("episodeId", episodeId))
    .unique();
}

export async function getOrCreateState(ctx: MutationCtx, episode: Doc<"episodes">): Promise<Doc<"episodeStates">> {
  const existing = await stateFor(ctx, episode._id);
  if (existing) return existing;
  await ensureLibraryRow(ctx, episode.podcastId);
  const id = await ctx.db.insert("episodeStates", {
    userId: ctx.userId,
    episodeId: episode._id,
    podcastId: episode.podcastId,
    position: 0,
    positionUpdatedAt: 0,
    played: false,
    playedUpdatedAt: 0,
    starred: false,
    starredUpdatedAt: 0,
    archived: false,
    archivedUpdatedAt: 0,
    inInbox: false,
    inboxUpdatedAt: 0,
    updatedAt: Date.now(),
  });
  return (await ctx.db.get(id))!;
}

export async function requireEpisode(ctx: QueryCtx, episodeId: Id<"episodes">) {
  const episode = await ctx.db.get(episodeId);
  if (!episode) throw new Error(`Episode ${episodeId} not found`);
  return episode;
}

export async function userUtcOffset(ctx: UserQueryCtx, at: number): Promise<number> {
  const g = await ctx.db
    .query("globalSettings")
    .withIndex("by_user_updatedAt", (q) => q.eq("userId", ctx.userId))
    .first();
  return zoneOffsetMinutes(resolveGlobalSettings(g).timeZone, at);
}

export async function logEvent(
  ctx: MutationCtx,
  eventId: string,
  type: Doc<"libraryEvents">["type"],
  at: number,
  refs: { podcastId?: Id<"podcasts">; episodeId?: Id<"episodes"> },
) {
  const existing = await ctx.db
    .query("libraryEvents")
    .withIndex("by_user_eventId", (q) => q.eq("userId", ctx.userId).eq("eventId", eventId))
    .unique();
  if (existing) return existing._id;
  return await ctx.db.insert("libraryEvents", { userId: ctx.userId, eventId, type, at, ...refs, updatedAt: Date.now() });
}

export async function setPosition(
  ctx: MutationCtx,
  episode: Doc<"episodes">,
  position: number,
  positionUpdatedAt: number,
  deviceId: string | undefined,
): Promise<boolean> {
  const state = await getOrCreateState(ctx, episode);
  if (positionUpdatedAt < state.positionUpdatedAt) return false;
  await ctx.db.patch(state._id, {
    position: Math.max(0, position),
    positionUpdatedAt,
    positionDeviceId: deviceId,
    updatedAt: Date.now(),
  });
  return true;
}

export async function setInbox(ctx: MutationCtx, episode: Doc<"episodes">, inInbox: boolean, at: number, inboxAt?: number) {
  const state = await getOrCreateState(ctx, episode);
  if (at < state.inboxUpdatedAt) return false;
  if (state.inInbox === inInbox) {
    await ctx.db.patch(state._id, { inboxUpdatedAt: at });
    return false;
  }
  await ctx.db.patch(state._id, {
    inInbox,
    inboxAt: inInbox ? (inboxAt ?? at) : state.inboxAt,
    inboxUpdatedAt: at,
    updatedAt: Date.now(),
  });
  return true;
}

/** Marking played also takes it out of the Inbox and Up Next. */
export async function setPlayed(
  ctx: MutationCtx,
  episode: Doc<"episodes">,
  played: boolean,
  at: number,
  opts: { countCompletion?: boolean } = {},
): Promise<boolean> {
  const countCompletion = opts.countCompletion ?? true;
  const state = await getOrCreateState(ctx, episode);
  if (at < state.playedUpdatedAt) return false;
  if (state.played === played) {
    await ctx.db.patch(state._id, { playedUpdatedAt: at });
    return false;
  }
  if (played) {
    await ctx.db.patch(state._id, {
      played,
      playedAt: at,
      playedUpdatedAt: at,
      countedCompletion: countCompletion,
      updatedAt: Date.now(),
    });
    if (countCompletion) {
      await applyCompletion(ctx, localDay(at, await userUtcOffset(ctx, at)), 1);
      await logEvent(ctx, `completed:${episode._id}:${at}`, "completed", at, {
        podcastId: episode.podcastId,
        episodeId: episode._id,
      });
    }
    await setInbox(ctx, episode, false, at);
    await removeFromQueue(ctx, episode._id, at);
  } else {
    if (state.playedAt !== undefined && state.countedCompletion !== false) {
      await applyCompletion(ctx, localDay(state.playedAt, await userUtcOffset(ctx, state.playedAt)), -1);
    }
    await ctx.db.patch(state._id, { played, playedAt: undefined, playedUpdatedAt: at, updatedAt: Date.now() });
  }
  return true;
}

export async function setStarred(ctx: MutationCtx, episode: Doc<"episodes">, starred: boolean, at: number): Promise<boolean> {
  const state = await getOrCreateState(ctx, episode);
  if (at < state.starredUpdatedAt) return false;
  await ctx.db.patch(state._id, {
    starred,
    starredAt: starred ? (state.starred ? state.starredAt : at) : undefined,
    starredUpdatedAt: at,
    updatedAt: Date.now(),
  });
  if (starred && !state.starred) {
    await logEvent(ctx, `starred:${episode._id}:${at}`, "starred", at, {
      podcastId: episode.podcastId,
      episodeId: episode._id,
    });
  }
  return state.starred !== starred;
}

/** Archiving takes it out of the Inbox. Archiving unplayed counts as "skipped". */
export async function setArchived(ctx: MutationCtx, episode: Doc<"episodes">, archived: boolean, at: number): Promise<boolean> {
  const state = await getOrCreateState(ctx, episode);
  if (at < state.archivedUpdatedAt) return false;
  await ctx.db.patch(state._id, {
    archived,
    archivedAt: archived ? (state.archived ? state.archivedAt : at) : undefined,
    archivedUpdatedAt: at,
    updatedAt: Date.now(),
  });
  if (archived) {
    await setInbox(ctx, episode, false, at);
    if (!state.archived && !state.played) {
      await logEvent(ctx, `skipped:${episode._id}:${at}`, "skipped", at, {
        podcastId: episode.podcastId,
        episodeId: episode._id,
      });
    }
  }
  return state.archived !== archived;
}
