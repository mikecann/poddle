import { v, type Infer } from "convex/values";
import { doc } from "convex-helpers/validators";
import type { Doc } from "../_generated/dataModel";
import schema, { podcastFields, vImportStatus } from "../schema";

/** A show as the app sees it: the shared show plus the caller's subscription (lib/library.ts). */
export const vPodcastDoc = v.object({
  _id: v.id("podcasts"),
  _creationTime: v.number(),
  ...podcastFields,
  subscribed: v.boolean(),
  subscribedAt: v.optional(v.number()),
  unsubscribedAt: v.optional(v.number()),
  subscriptionUpdatedAt: v.number(),
});
export const vEpisodeDoc = doc(schema, "episodes");
export const vEpisodeStateDoc = doc(schema, "episodeStates");
export const vQueueItemDoc = doc(schema, "queueItems");
export const vPodcastSettingsDoc = doc(schema, "podcastSettings");
export const vGlobalSettingsDoc = doc(schema, "globalSettings");
export const vSessionDoc = doc(schema, "listeningSessions");
export const vLibraryEventDoc = doc(schema, "libraryEvents");
export const vDeviceDoc = doc(schema, "devices");
/** An import batch as stored, for internal code. */
export const vImportBatchRow = doc(schema, "importBatches");
const { state: _state, stateTimers: _timers, ...batchFields } = schema.tables.importBatches.validator.fields;
/**
 * An import batch as the app and website see it (docs/api.md): the importBatch
 * machine's state shown as the `status`, `finishedAt` and `error` they've always
 * read, so apps from before the machine keep working.
 */
export const vImportBatchDoc = v.object({
  _id: v.id("importBatches"),
  _creationTime: v.number(),
  ...batchFields,
  status: vImportStatus,
  finishedAt: v.optional(v.number()),
  error: v.optional(v.string()),
});
export type ImportBatchView = Infer<typeof vImportBatchDoc>;

export function importBatchView(row: Doc<"importBatches">): ImportBatchView {
  const { state, stateTimers: _t, ...rest } = row;
  return {
    ...rest,
    status: state.kind,
    ...(state.kind === "done" || state.kind === "failed" ? { finishedAt: state.finishedAt } : {}),
    ...(state.kind === "failed" ? { error: state.error } : {}),
  };
}
export const vDeletionDoc = doc(schema, "deletions");
export const vEpisodeNotesDoc = doc(schema, "episodeNotes");

export const vPodcastSummary = v.object({
  _id: v.id("podcasts"),
  title: v.string(),
  author: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
  isPrivate: v.boolean(),
});

/** An episode with its user state (null if never touched) and its show. */
export const vEpisodeRow = v.object({
  episode: vEpisodeDoc,
  state: v.union(vEpisodeStateDoc, v.null()),
  podcast: vPodcastSummary,
});
export type EpisodeRow = Infer<typeof vEpisodeRow>;

/** The shape returned by directory search, Apple lookup and feed preview. */
export const vDirectoryResult = v.object({
  appleId: v.optional(v.number()),
  title: v.string(),
  author: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
  feedUrl: v.optional(v.string()),
  genre: v.optional(v.string()),
  episodeCount: v.optional(v.number()),
  /** When the show's newest episode came out (ms), from Apple. */
  latestEpisodeAt: v.optional(v.number()),
  /** Set when this feed is already in the library. */
  podcastId: v.optional(v.id("podcasts")),
  subscribed: v.boolean(),
});
export type DirectoryResult = Infer<typeof vDirectoryResult>;

/** One episode from Apple's episode search (`directory:searchEpisodes`). Open it with `feedActions:openFeed`. */
export const vDirectoryEpisode = v.object({
  appleId: v.optional(v.number()),
  title: v.string(),
  showTitle: v.string(),
  author: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
  feedUrl: v.string(),
  /** The feed item's `<guid>`, as Apple saw it. */
  guid: v.optional(v.string()),
  audioUrl: v.optional(v.string()),
  pubDate: v.optional(v.number()),
  /** Seconds. */
  duration: v.optional(v.number()),
});
export type DirectoryEpisode = Infer<typeof vDirectoryEpisode>;
