import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { globalSettingFields, podcastOverrideFields } from "./lib/settings";

// Conventions:
// - Shared tables (podcasts, feedStates, episodes, episodeNotes, directoryCache) hold
//   feed and catalog data that's the same for everyone. Every other table is
//   personal: it has a `userId` and every index on it starts with `userId`. The
//   exceptions are documented on the index (lookups that must see every person,
//   like fanning a new episode out to its subscribers).
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

/**
 * Owner of a personal row. Optional only until the accounts migration
 * (`migrations:run`) has given every existing row an owner on prod; then make
 * it `v.id("users")` (docs/runbooks/accounts-prod.md, last step). New rows always
 * get one.
 */
export const vOwner = v.optional(v.id("users"));

/** Shared show fields. Who's subscribed lives in `subscriptions`. */
export const podcastFields = {
  feedUrl: v.string(),
  title: v.string(),
  author: v.optional(v.string()),
  description: v.optional(v.string()),
  artworkUrl: v.optional(v.string()),
  link: v.optional(v.string()),
  language: v.optional(v.string()),
  appleId: v.optional(v.number()),
  overcastId: v.optional(v.number()),
  /** Default for new subscribers: feeds with credentials or token-ish query params. Each person can override it. */
  isPrivate: v.boolean(),
  latestEpisodeAt: v.optional(v.number()),
  episodeCount: v.number(),
  lastFetchedAt: v.optional(v.number()),
  createdAt: v.number(),
  updatedAt: v.number(),
};

/**
 * Subscription fields from the single-user days. The accounts migration moves
 * them into `subscriptions` and clears them; delete them once it has run on prod.
 */
const legacyPodcastFields = {
  subscribed: v.optional(v.boolean()),
  subscribedAt: v.optional(v.number()),
  unsubscribedAt: v.optional(v.number()),
  subscriptionUpdatedAt: v.optional(v.number()),
};

export default defineSchema({
  /** People. Rows are made by Convex Auth's createUser callbacks (users.ts) and the accounts migration. */
  users: defineTable({
    name: v.optional(v.string()),
    email: v.optional(v.string()),
    emailVerified: v.optional(v.boolean()),
    /** Google photo. */
    picture: v.optional(v.string()),
    /** Set when this user was folded into another one with the same verified email. */
    mergedInto: v.optional(v.id("users")),
    /** Made by the dev-only test sign-in. */
    isTest: v.optional(v.boolean()),
    /**
     * Set when the person deleted their account (`users:deleteAccount`). The row
     * stays as a tombstone with no name, email or photo, because Convex Auth keeps
     * its provider account pointing at this id: signing in again with the same
     * Apple or Google account brings it back, empty (users.ts).
     */
    deletedAt: v.optional(v.number()),
  })
    .index("by_email", ["email"])
    .index("by_mergedInto", ["mergedInto"]),

  /**
   * One per account deletion. The work is batched through the scheduler; this
   * records how far it got, so it picks up where it left off (accountDeletion.ts).
   */
  accountDeletions: defineTable({
    userId: v.id("users"),
    requestedAt: v.number(),
    /** The table being emptied now (`accountDeletion.STAGES`). */
    stage: v.string(),
    /** Full passes over every stage; another pass runs if rows turned up behind it. */
    passes: v.number(),
    deletedRows: v.number(),
    lastStepAt: v.number(),
    finishedAt: v.optional(v.number()),
  })
    .index("by_user", ["userId"])
    .index("by_finishedAt_lastStepAt", ["finishedAt", "lastStepAt"]),

  /** Test sign-in hands the email it wants to `users:createUserAnonymous` through here (dev only). */
  testSignIns: defineTable({ email: v.string() }),

  podcasts: defineTable({ ...podcastFields, ...legacyPodcastFields })
    .index("by_feedUrl", ["feedUrl"])
    .index("by_overcastId", ["overcastId"])
    .index("by_appleId", ["appleId"])
    .index("by_updatedAt", ["updatedAt"]),

  /**
   * A show in someone's library, subscribed or not. Every show a person has
   * any state for (an episode state, a queue item, a session) has one of these,
   * which is what `sync:changes` uses to decide which shared shows and episodes
   * to send them.
   */
  subscriptions: defineTable({
    userId: vOwner,
    podcastId: v.id("podcasts"),
    subscribed: v.boolean(),
    /** When first subscribed (Overcast's `overcastAddedDate` on import). */
    subscribedAt: v.optional(v.number()),
    unsubscribedAt: v.optional(v.number()),
    /** Client time of the last subscribe/unsubscribe, for LWW. */
    subscriptionUpdatedAt: v.number(),
    /** This person's "private" switch; absent means the show's default. */
    isPrivate: v.optional(v.boolean()),
    /** Server time the show joined the library, so sync sends its whole back catalogue once. */
    addedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_podcast", ["userId", "podcastId"])
    .index("by_user_subscribed", ["userId", "subscribed"])
    .index("by_user_subscribedAt", ["userId", "subscribedAt"])
    .index("by_user_updatedAt", ["userId", "updatedAt"])
    // Not user-first: a new episode has to reach every subscriber, and polling
    // needs to know whether anyone still subscribes.
    .index("by_podcast_subscribed", ["podcastId", "subscribed"]),

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
    .index("by_podcast_updatedAt", ["podcastId", "updatedAt"])
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
    userId: vOwner,
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
    .index("by_user_episode", ["userId", "episodeId"])
    .index("by_user_podcast", ["userId", "podcastId"])
    .index("by_user_inbox", ["userId", "inInbox", "inboxAt"])
    .index("by_user_podcast_inbox", ["userId", "podcastId", "inInbox"])
    .index("by_user_starred", ["userId", "starred", "starredAt"])
    .index("by_user_updatedAt", ["userId", "updatedAt"]),

  /** Up Next. One row per queued episode. The lowest orderKey is what's playing. */
  queueItems: defineTable({
    userId: vOwner,
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    orderKey: v.string(),
    addedAt: v.number(),
    addedBy: vQueueAddedBy,
    /** Client time of the last add or move, for LWW against stale replays. */
    orderUpdatedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_orderKey", ["userId", "orderKey"])
    .index("by_user_episode", ["userId", "episodeId"])
    /** A show's episodes in Up Next, for its "Keep latest" limit (lib/keepLatest.ts). */
    .index("by_user_podcast", ["userId", "podcastId"])
    .index("by_user_updatedAt", ["userId", "updatedAt"]),

  /** Tombstones so `sync:changes` can report deletions. */
  deletions: defineTable({
    userId: vOwner,
    table: v.string(),
    docId: v.string(),
    /** For queue items: the episode, so a stale replayed add can be ignored. */
    episodeId: v.optional(v.id("episodes")),
    /** Client time of the delete. */
    deletedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_updatedAt", ["userId", "updatedAt"])
    .index("by_user_table_episode", ["userId", "table", "episodeId"]),

  podcastSettings: defineTable({
    userId: vOwner,
    podcastId: v.id("podcasts"),
    ...podcastOverrideFields,
    /** Per-field client timestamps for LWW. */
    fieldTimes: v.record(v.string(), v.number()),
    updatedAt: v.number(),
  })
    .index("by_user_podcast", ["userId", "podcastId"])
    .index("by_user_updatedAt", ["userId", "updatedAt"]),

  /** One row per person (absent until they change something). */
  globalSettings: defineTable({
    userId: vOwner,
    ...Object.fromEntries(
      Object.entries(globalSettingFields).map(([k, val]) => [k, v.optional(val)]),
    ) as { [K in keyof typeof globalSettingFields]: ReturnType<typeof v.optional<(typeof globalSettingFields)[K]>> },
    fieldTimes: v.record(v.string(), v.number()),
    updatedAt: v.number(),
  }).index("by_user_updatedAt", ["userId", "updatedAt"]),

  listeningSessions: defineTable({
    userId: vOwner,
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
    .index("by_user_sessionId", ["userId", "sessionId"])
    .index("by_user_startedAt", ["userId", "startedAt"])
    .index("by_user_podcast_startedAt", ["userId", "podcastId", "startedAt"])
    .index("by_user_updatedAt", ["userId", "updatedAt"]),

  libraryEvents: defineTable({
    userId: vOwner,
    /** Client UUID or a deterministic id; makes inserts idempotent. */
    eventId: v.string(),
    type: vLibraryEventType,
    podcastId: v.optional(v.id("podcasts")),
    episodeId: v.optional(v.id("episodes")),
    at: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_eventId", ["userId", "eventId"])
    .index("by_user_type_at", ["userId", "type", "at"])
    .index("by_user_updatedAt", ["userId", "updatedAt"]),

  devices: defineTable({
    userId: vOwner,
    deviceId: v.string(),
    name: v.string(),
    platform: v.string(),
    apnsToken: v.optional(v.string()),
    apnsEnvironment: v.optional(v.union(v.literal("sandbox"), v.literal("production"))),
    lastSeenAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_updatedAt", ["userId", "updatedAt"])
    // Not user-first: a phone (and its push token) belongs to whoever signed in
    // on it last, so registering has to find it whoever had it before.
    .index("by_deviceId", ["deviceId"])
    .index("by_apnsToken", ["apnsToken"]),

  // One row per person: when their next background sync push is due. New
  // episodes from a whole poll land within a minute or two of each other, and
  // iOS throttles apps that send lots of silent pushes, so they share one.
  syncWakes: defineTable({
    userId: v.id("users"),
    dueAt: v.number(),
  }).index("by_user", ["userId"]),

  importBatches: defineTable({
    userId: vOwner,
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
    .index("by_user_startedAt", ["userId", "startedAt"])
    .index("by_user_updatedAt", ["userId", "updatedAt"]),

  // importItems, importQueue and importUpNext are scratch space for one batch,
  // so they're keyed by the (personal) batch rather than the user.

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
    userId: vOwner,
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
  }).index("by_user_day", ["userId", "day"]),

  statsMonths: defineTable({
    userId: vOwner,
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
  }).index("by_user_month", ["userId", "month"]),

  statsShowDays: defineTable({
    userId: vOwner,
    day: v.string(),
    podcastId: v.id("podcasts"),
    wall: v.number(),
    content: v.number(),
    speedSaved: v.number(),
    smartSaved: v.number(),
    sessions: v.number(),
  }).index("by_user_day_podcast", ["userId", "day", "podcastId"]),

  statsShowMonths: defineTable({
    userId: vOwner,
    month: v.string(),
    podcastId: v.id("podcasts"),
    wall: v.number(),
    content: v.number(),
    speedSaved: v.number(),
    smartSaved: v.number(),
    sessions: v.number(),
  })
    .index("by_user_month_podcast", ["userId", "month", "podcastId"])
    .index("by_user_podcast_month", ["userId", "podcastId", "month"]),

  episodeTotals: defineTable({
    userId: vOwner,
    episodeId: v.id("episodes"),
    podcastId: v.id("podcasts"),
    wall: v.number(),
    content: v.number(),
    sessions: v.number(),
  })
    .index("by_user_episode", ["userId", "episodeId"])
    .index("by_user_wall", ["userId", "wall"]),

  /** iTunes Search API responses, cached for 24 h (Apple allows ~20 calls a minute). */
  directoryCache: defineTable({
    key: v.string(),
    json: v.string(),
    fetchedAt: v.number(),
  }).index("by_key", ["key"]),
});
