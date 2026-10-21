import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { globalSettingFields, podcastOverrideFields } from "./lib/settings";

// Conventions:
// - Wall-clock times are ms since the epoch. Content times are seconds.
// - Every synced table has `updatedAt` (server ms) and a `by_updatedAt` index so
//   the app can catch up with `sync:changes` after being offline.
// - Fields ending `At` that come from the client (e.g. `positionUpdatedAt`)
//   are client clocks used for last-writer-wins.

export const vTranscript = v.object({
  url: v.string(),
  type: v.string(),
  language: v.optional(v.string()),
  rel: v.optional(v.string()),
});

export const vSessionSource = v.union(v.literal("live"), v.literal("overcastImport"));
export const vLibraryEventType = v.union(
  v.literal("subscribed"),
  v.literal("unsubscribed"),
  v.literal("starred"),
  v.literal("completed"),
  v.literal("skipped"),
);
export const vQueueAddedBy = v.union(
  v.literal("manual"),
  v.literal("priority"),
  v.literal("auto"),
);
export const vImportStatus = v.union(
  v.literal("parsing"),
  v.literal("fetching"),
  v.literal("done"),
  v.literal("failed"),
);

export default defineSchema({
  podcasts: defineTable({
    feedUrl: v.string(),
    title: v.string(),
    author: v.optional(v.string()),
    description: v.optional(v.string()),
    artworkUrl: v.optional(v.string()),
    link: v.optional(v.string()),
    language: v.optional(v.string()),
    appleId: v.optional(v.number()),
    overcastId: v.optional(v.number()),
    isPrivate: v.boolean(),
    subscribed: v.boolean(),
    /** When first subscribed (Overcast's `overcastAddedDate` on import). */
    subscribedAt: v.optional(v.number()),
    unsubscribedAt: v.optional(v.number()),
    /** Client time of the last subscribe/unsubscribe, for LWW. */
    subscriptionUpdatedAt: v.number(),
    latestEpisodeAt: v.optional(v.number()),
    episodeCount: v.number(),
    lastFetchedAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_feedUrl", ["feedUrl"])
    .index("by_overcastId", ["overcastId"])
    .index("by_appleId", ["appleId"])
    .index("by_subscribed_title", ["subscribed", "title"])
    .index("by_subscribedAt", ["subscribedAt"])
    .index("by_updatedAt", ["updatedAt"]),

  /** Fetch bookkeeping, kept off `podcasts` so polling doesn't churn the app's subscriptions. */
  feedStates: defineTable({
    podcastId: v.id("podcasts"),
    /** Polled by the cron only while subscribed. */
    active: v.boolean(),
    nextCheckAt: v.number(),
    etag: v.optional(v.string()),
    lastModified: v.optional(v.string()),
    bodyHash: v.optional(v.string()),
    lastCheckedAt: v.optional(v.number()),
    lastSuccessAt: v.optional(v.number()),
    lastChangedAt: v.optional(v.number()),
    lastStatus: v.optional(v.number()),
    lastError: v.optional(v.string()),
    consecutiveErrors: v.number(),
    /** Lease held while a fetch is in flight. */
    fetchingUntil: v.optional(v.number()),
  })
    .index("by_podcast", ["podcastId"])
    .index("by_active_nextCheckAt", ["active", "nextCheckAt"]),

  episodes: defineTable({
    podcastId: v.id("podcasts"),
    guid: v.optional(v.string()),
    enclosureUrl: v.optional(v.string()),
    /** Enclosure URL normalised for matching: no query, scheme or tracking redirect prefixes (`parse.enclosureKey`). */
    enclosureKey: v.optional(v.string()),
    enclosureType: v.optional(v.string()),
    enclosureLength: v.optional(v.number()),
    title: v.string(),
    /** Plain-text snippet of the show notes for list rows. */
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
    /** Known only from an import, no longer in the feed. */
    isGhost: v.boolean(),
    firstSeenAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_podcast_pubDate", ["podcastId", "pubDate"])
    .index("by_podcast_guid", ["podcastId", "guid"])
    .index("by_podcast_enclosureKey", ["podcastId", "enclosureKey"])
    .index("by_podcast_title", ["podcastId", "title"])
    .index("by_podcast_link", ["podcastId", "link"])
    .index("by_updatedAt", ["updatedAt"]),

  /** Show notes HTML, split out so episode lists stay light. */
  episodeNotes: defineTable({
    episodeId: v.id("episodes"),
    html: v.string(),
    updatedAt: v.number(),
  })
    .index("by_episode", ["episodeId"])
    .index("by_updatedAt", ["updatedAt"]),

  /** User state per episode, never touched by feed refreshes. */
  episodeStates: defineTable({
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    position: v.number(),
    positionUpdatedAt: v.number(),
    positionDeviceId: v.optional(v.string()),
    played: v.boolean(),
    playedAt: v.optional(v.number()),
    playedUpdatedAt: v.number(),
    /** False when marked played in bulk, so it isn't in completion stats. */
    countedCompletion: v.optional(v.boolean()),
    starred: v.boolean(),
    starredAt: v.optional(v.number()),
    starredUpdatedAt: v.number(),
    archived: v.boolean(),
    archivedAt: v.optional(v.number()),
    archivedUpdatedAt: v.number(),
    inInbox: v.boolean(),
    inboxAt: v.optional(v.number()),
    inboxUpdatedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_episode", ["episodeId"])
    .index("by_podcast", ["podcastId"])
    .index("by_inbox", ["inInbox", "inboxAt"])
    .index("by_podcast_inbox", ["podcastId", "inInbox"])
    .index("by_starred", ["starred", "starredAt"])
    .index("by_updatedAt", ["updatedAt"]),

  /** Up Next. One row per queued episode. The lowest orderKey is what's playing. */
  queueItems: defineTable({
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    orderKey: v.string(),
    addedAt: v.number(),
    addedBy: vQueueAddedBy,
    /** Client time of the last add or move, for LWW against stale replays. */
    orderUpdatedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_orderKey", ["orderKey"])
    .index("by_episode", ["episodeId"])
    .index("by_updatedAt", ["updatedAt"]),

  /** Tombstones so `sync:changes` can report deletions. */
  deletions: defineTable({
    table: v.string(),
    docId: v.string(),
    /** For queue items: the episode, so a stale replayed add can be ignored. */
    episodeId: v.optional(v.id("episodes")),
    /** Client time of the delete. */
    deletedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_updatedAt", ["updatedAt"])
    .index("by_table_episode", ["table", "episodeId"]),

  podcastSettings: defineTable({
    podcastId: v.id("podcasts"),
    ...podcastOverrideFields,
    /** Per-field client timestamps for LWW. */
    fieldTimes: v.record(v.string(), v.number()),
    updatedAt: v.number(),
  })
    .index("by_podcast", ["podcastId"])
    .index("by_updatedAt", ["updatedAt"]),

  globalSettings: defineTable({
    ...Object.fromEntries(
      Object.entries(globalSettingFields).map(([k, val]) => [k, v.optional(val)]),
    ) as { [K in keyof typeof globalSettingFields]: ReturnType<typeof v.optional<(typeof globalSettingFields)[K]>> },
    fieldTimes: v.record(v.string(), v.number()),
    updatedAt: v.number(),
  }).index("by_updatedAt", ["updatedAt"]),

  listeningSessions: defineTable({
    /** Client-generated UUID. Re-sending the same id updates the session. */
    sessionId: v.string(),
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    deviceId: v.optional(v.string()),
    startedAt: v.number(),
    endedAt: v.number(),
    contentStart: v.number(),
    contentEnd: v.number(),
    rate: v.number(),
    smartSpeed: v.boolean(),
    smartRemovedContent: v.number(),
    voiceBoost: v.boolean(),
    route: v.optional(v.string()),
    source: vSessionSource,
    isEstimated: v.boolean(),
    /** Local UTC offset when the session started, for day and hour bucketing. */
    utcOffsetMinutes: v.number(),
    importBatchId: v.optional(v.id("importBatches")),
    updatedAt: v.number(),
  })
    .index("by_sessionId", ["sessionId"])
    .index("by_startedAt", ["startedAt"])
    .index("by_episode", ["episodeId"])
    .index("by_podcast_startedAt", ["podcastId", "startedAt"])
    .index("by_updatedAt", ["updatedAt"]),

  libraryEvents: defineTable({
    /** Client UUID or a deterministic id; makes inserts idempotent. */
    eventId: v.string(),
    type: vLibraryEventType,
    podcastId: v.optional(v.id("podcasts")),
    episodeId: v.optional(v.id("episodes")),
    at: v.number(),
    updatedAt: v.number(),
  })
    .index("by_eventId", ["eventId"])
    .index("by_type_at", ["type", "at"])
    .index("by_updatedAt", ["updatedAt"]),

  devices: defineTable({
    deviceId: v.string(),
    name: v.string(),
    platform: v.string(),
    apnsToken: v.optional(v.string()),
    apnsEnvironment: v.optional(v.union(v.literal("sandbox"), v.literal("production"))),
    lastSeenAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_deviceId", ["deviceId"])
    .index("by_apnsToken", ["apnsToken"])
    .index("by_updatedAt", ["updatedAt"]),

  importBatches: defineTable({
    source: v.literal("overcast"),
    status: vImportStatus,
    assumedSpeed: v.number(),
    startedAt: v.number(),
    finishedAt: v.optional(v.number()),
    error: v.optional(v.string()),
    warning: v.optional(v.string()),
    counts: v.object({
      podcasts: v.number(),
      subscribedPodcasts: v.number(),
      podcastsProcessed: v.number(),
      feedsFailed: v.number(),
      episodes: v.number(),
      episodesMatched: v.number(),
      ghostEpisodes: v.number(),
      /** Why the ghosts are ghosts: older than anything the feed still lists, */
      ghostsOlderThanFeed: v.optional(v.number()),
      /** inside the feed's date range but removed from it, */
      ghostsMissingFromFeed: v.optional(v.number()),
      /** or the feed couldn't be fetched. */
      ghostsFeedFailed: v.optional(v.number()),
      playedEpisodes: v.number(),
      inProgressEpisodes: v.number(),
      starredEpisodes: v.number(),
      sessions: v.number(),
      /** Sessions whose length used a show (or overall) median duration. */
      estimatedDurationSessions: v.optional(v.number()),
      estimatedListenSeconds: v.number(),
      earliestListenAt: v.optional(v.number()),
      /** Episodes put in Up Next at the end of the import. */
      upNextEpisodes: v.optional(v.number()),
    }),
    playlists: v.array(
      v.object({
        title: v.string(),
        smart: v.boolean(),
        sorting: v.optional(v.string()),
        /** Shows the playlist is limited to (empty: every show). */
        podcastIds: v.array(v.id("podcasts")),
        /** Shows it puts first. */
        priorityPodcastIds: v.optional(v.array(v.id("podcasts"))),
        /** How many episodes it lists by hand (manual episodes or a smart playlist's pinned order). */
        episodeCount: v.optional(v.number()),
      }),
    ),
    /** Feeds that couldn't be fetched, so the app can list them. */
    failedFeeds: v.optional(
      v.array(
        v.object({
          podcastId: v.id("podcasts"),
          title: v.string(),
          feedUrl: v.string(),
          /** HTTP status, absent for network and parse errors. */
          status: v.optional(v.number()),
          error: v.string(),
        }),
      ),
    ),
    /** Median episode length across the imported feeds, for estimating unknown durations. */
    medianDuration: v.optional(v.number()),
    /** Overcast's main playlist, resolved, for seeding Up Next once matching is done. */
    upNextPlan: v.optional(
      v.object({
        leadingEpisodeIds: v.array(v.number()),
        priorityPodcastIds: v.array(v.id("podcasts")),
        newestFirst: v.boolean(),
      }),
    ),
    updatedAt: v.number(),
  })
    .index("by_startedAt", ["startedAt"])
    .index("by_updatedAt", ["updatedAt"]),

  /** Staged Overcast episodes waiting for their feed to be fetched and matched. */
  importItems: defineTable({
    batchId: v.id("importBatches"),
    podcastId: v.id("podcasts"),
    overcastId: v.number(),
    title: v.string(),
    url: v.optional(v.string()),
    enclosureUrl: v.optional(v.string()),
    pubDate: v.optional(v.number()),
    played: v.boolean(),
    progress: v.optional(v.number()),
    userDeleted: v.boolean(),
    userUpdatedAt: v.optional(v.number()),
    userRecommendedAt: v.optional(v.number()),
  }).index("by_batch_podcast", ["batchId", "podcastId"]),

  /** Podcasts still to fetch ("fetch"), then to match ("match"), for an import batch. */
  importQueue: defineTable({
    batchId: v.id("importBatches"),
    podcastId: v.id("podcasts"),
    phase: v.union(v.literal("fetch"), v.literal("match")),
    /** Newest pubDate among the show's exported episodes, and Overcast's added date. */
    newestExportedAt: v.optional(v.number()),
    addedAt: v.optional(v.number()),
    /** Set once fetched. */
    feedOk: v.optional(v.boolean()),
    oldestFeedPubDate: v.optional(v.number()),
    medianDuration: v.optional(v.number()),
    /** Known durations, for the batch-wide median. */
    durations: v.optional(v.array(v.number())),
  }).index("by_batch_phase", ["batchId", "phase"]),

  /** Episodes to put in Up Next when an import finishes. */
  importUpNext: defineTable({
    batchId: v.id("importBatches"),
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    /** Overcast's episode ID, when it came from the export. */
    overcastId: v.optional(v.number()),
    pubDate: v.optional(v.number()),
    /** LWW time for the queue add: Overcast's `userUpdatedDate`, or the pubDate for untouched episodes. */
    at: v.number(),
  }).index("by_batch", ["batchId"]),

  // ---- Stats rollups (maintained on every session write) ----

  statsDays: defineTable({
    day: v.string(), // local YYYY-MM-DD
    wall: v.number(),
    content: v.number(),
    speedSaved: v.number(),
    smartSaved: v.number(),
    rateContent: v.number(), // Σ content × rate, for content-weighted average speed
    estimatedWall: v.number(),
    sessions: v.number(),
    episodesStarted: v.number(),
    episodesCompleted: v.number(),
    liveHours: v.array(v.number()), // 24 buckets of live wall seconds
  }).index("by_day", ["day"]),

  statsMonths: defineTable({
    month: v.string(), // local YYYY-MM
    wall: v.number(),
    content: v.number(),
    speedSaved: v.number(),
    smartSaved: v.number(),
    rateContent: v.number(),
    estimatedWall: v.number(),
    sessions: v.number(),
    episodesStarted: v.number(),
    episodesCompleted: v.number(),
    heatmap: v.array(v.number()), // 7 × 24, Monday first, live wall seconds
  }).index("by_month", ["month"]),

  statsShowDays: defineTable({
    day: v.string(),
    podcastId: v.id("podcasts"),
    wall: v.number(),
    content: v.number(),
    speedSaved: v.number(),
    smartSaved: v.number(),
    sessions: v.number(),
  }).index("by_day_podcast", ["day", "podcastId"]),

  statsShowMonths: defineTable({
    month: v.string(),
    podcastId: v.id("podcasts"),
    wall: v.number(),
    content: v.number(),
    speedSaved: v.number(),
    smartSaved: v.number(),
    sessions: v.number(),
  })
    .index("by_month_podcast", ["month", "podcastId"])
    .index("by_podcast_month", ["podcastId", "month"]),

  episodeTotals: defineTable({
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    wall: v.number(),
    content: v.number(),
    sessions: v.number(),
  })
    .index("by_episode", ["episodeId"])
    .index("by_wall", ["wall"]),

  /** iTunes Search API responses, cached for 24 h (Apple allows ~20 calls a minute). */
  directoryCache: defineTable({
    key: v.string(),
    json: v.string(),
    fetchedAt: v.number(),
  }).index("by_key", ["key"]),
});
