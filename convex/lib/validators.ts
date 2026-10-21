import { v, type Infer } from "convex/values";
import { doc } from "convex-helpers/validators";
import schema from "../schema";

export const vPodcastDoc = doc(schema, "podcasts");
export const vEpisodeDoc = doc(schema, "episodes");
export const vEpisodeStateDoc = doc(schema, "episodeStates");
export const vQueueItemDoc = doc(schema, "queueItems");
export const vPodcastSettingsDoc = doc(schema, "podcastSettings");
export const vGlobalSettingsDoc = doc(schema, "globalSettings");
export const vSessionDoc = doc(schema, "listeningSessions");
export const vLibraryEventDoc = doc(schema, "libraryEvents");
export const vDeviceDoc = doc(schema, "devices");
export const vImportBatchDoc = doc(schema, "importBatches");
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
  /** Set when this feed is already in the library. */
  podcastId: v.optional(v.id("podcasts")),
  subscribed: v.boolean(),
});
export type DirectoryResult = Infer<typeof vDirectoryResult>;
