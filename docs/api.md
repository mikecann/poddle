# Poddle backend API

The contract between the Convex backend (`convex/`) and the Swift app (`Packages/PoddleKit`). If the code and this file disagree, the code is wrong or this file is stale: fix one of them in the same change.

## Calling convention

- Functions are addressed as `"module:function"`, e.g. `"queue:add"`.
- **Every public function takes a `token: String` arg**: the `PODDLE_API_TOKEN` from the Keychain. It's compared in constant time. A wrong token throws a `ConvexError` with data `{ code: "unauthorized", message }`. If the server has no token set: `{ code: "unconfigured", message }`.
- Other failures throw a plain `Error` (e.g. `"Episode … not found"`), which the client sees as a server error.
- Every arg and return value is validated. Optional fields are **absent** from returned documents (not `null`) unless this doc says `| null`. Decode them as Swift optionals.

## Conventions

| Thing | Type | Notes |
|---|---|---|
| IDs | `String` | Convex document IDs (`Id<"episodes">` etc.). Opaque. |
| Wall-clock times | `Double`, ms since epoch | `startedAt`, `pubDate`, `at`, `updatedAt` … |
| Content times | `Double`, seconds | `position`, `duration`, `contentStart` … |
| Speeds | `Double` | 0.5–3.0 |
| Local days | `String` | `"YYYY-MM-DD"` in the user's time zone; months are `"YYYY-MM"` |
| `at` | `Double`, ms | **Client** time the user did the thing. Drives last-writer-wins. See the offline contract. |
| `_creationTime` | `Double` | Present on every document. Ignore it. |

## Environment variables

Set with `npx convex env set NAME value` on the deployment.

| Name | Required | Meaning |
|---|---|---|
| `PODDLE_API_TOKEN` | yes | Long random string. Every public function checks it. |
| `APNS_KEY_P8` | for push | Contents of the `.p8` auth key. PEM (newlines or literal `\n`) or the bare base64 body. |
| `APNS_KEY_ID` | for push | The key's 10-character ID. |
| `APNS_TEAM_ID` | for push | `4DTAZSZL6B` |
| `APNS_TOPIC` | for push | `com.mikecann.poddle` |
| `APNS_ENV` | for push | `sandbox` (default) or `production`. A device's own `apnsEnvironment` overrides it. |

Without the four required APNs vars, every push is a logged no-op.

## Documents

These are the shapes returned by queries and by `sync:changes`. Every synced table has `updatedAt` (server ms).

### Podcast (`podcasts`)
`_id`, `feedUrl`, `title`, `author?`, `description?`, `artworkUrl?`, `link?`, `language?`, `appleId?: Int`, `overcastId?: Int`, `isPrivate: Bool`, `subscribed: Bool`, `subscribedAt?` (first subscribe; Overcast's added date on import), `unsubscribedAt?`, `subscriptionUpdatedAt` (LWW clock), `latestEpisodeAt?`, `episodeCount: Int`, `lastFetchedAt?`, `createdAt`, `updatedAt`.

### Episode (`episodes`)
Feed data only, never user state. `_id`, `podcastId`, `guid?`, `enclosureUrl?`, `enclosureKey?` (URL without query), `enclosureType?`, `enclosureLength?: Int`, `title`, `summary?` (plain text, ≤280 chars), `link?`, `pubDate?`, `duration?` (seconds; absent if the feed doesn't say), `chaptersUrl?`, `chaptersType?`, `transcripts: [{ url, type, language?, rel? }]`, `artworkUrl?` (episode art; fall back to the show's), `season?`, `episodeNumber?`, `episodeType?` (`full`/`trailer`/`bonus`), `explicit?: Bool`, `isGhost: Bool` (only known from the Overcast import; no longer in the feed, may have no enclosure), `firstSeenAt`, `updatedAt`.

### Episode notes (`episodeNotes`)
`_id`, `episodeId`, `html` (show notes HTML, capped at 50k chars), `updatedAt`. Split out so episode lists stay light. Returned by `episodes:get`.

### Episode state (`episodeStates`)
One per episode the user has touched, or that was auto-added. Absent means all defaults (position 0, unplayed, not starred, not archived, not in the Inbox).
`_id`, `episodeId`, `podcastId`, `position`, `positionUpdatedAt`, `positionDeviceId?`, `played`, `playedAt?`, `playedUpdatedAt`, `countedCompletion?: Bool` (false when bulk-marked), `starred`, `starredAt?`, `starredUpdatedAt`, `archived`, `archivedAt?`, `archivedUpdatedAt`, `inInbox`, `inboxAt?` (sort key, newest first), `inboxUpdatedAt`, `updatedAt`.

### Queue item (`queueItems`)
`_id`, `episodeId` (unique), `podcastId`, `orderKey` (sort ascending as plain byte strings; never generate these on the client), `addedAt`, `addedBy` (`manual` / `priority` / `auto`), `orderUpdatedAt` (LWW clock), `updatedAt`. **The first item is what's playing.**

### Podcast settings (`podcastSettings`) and global settings (`globalSettings`)
See [Settings](#settings). Both also carry `fieldTimes: { [field]: ms }` (per-field LWW clocks) and `updatedAt`. Global settings is a single row that may not exist yet; `settings:getGlobal` always returns it with defaults filled in.

### Listening session (`listeningSessions`)
`_id`, `sessionId` (client UUID), `episodeId`, `podcastId`, `deviceId?`, `startedAt`, `endedAt`, `contentStart`, `contentEnd`, `rate`, `smartSpeed`, `smartRemovedContent` (content seconds Smart Speed cut), `voiceBoost`, `route?`, `source` (`live` / `overcastImport`), `isEstimated`, `utcOffsetMinutes`, `importBatchId?`, `updatedAt`.

### Library event (`libraryEvents`)
`_id`, `eventId`, `type` (`subscribed` / `unsubscribed` / `starred` / `completed` / `skipped`), `podcastId?`, `episodeId?`, `at`, `updatedAt`. Written by the server as a side effect of the mutations below.

### Device (`devices`)
`_id`, `deviceId`, `name`, `platform`, `apnsToken?`, `apnsEnvironment?` (`sandbox`/`production`), `lastSeenAt`, `updatedAt`.

### Import batch (`importBatches`)
`_id`, `source: "overcast"`, `status` (`parsing` → `fetching` → `done`, or `failed`), `assumedSpeed`, `startedAt`, `finishedAt?`, `error?`, `warning?`, `playlists: [{ title, smart: Bool, podcastIds: [Id] }]`, `updatedAt`, and `counts`:

| Count | Meaning |
|---|---|
| `podcasts`, `subscribedPodcasts` | Shows in the file / still subscribed in Overcast |
| `podcastsProcessed`, `feedsFailed` | Progress through the feed fetches. Done when `podcastsProcessed == podcasts`. |
| `episodes` | Episode rows in the file |
| `episodesMatched`, `ghostEpisodes` | Matched to a feed episode / created as ghosts |
| `playedEpisodes`, `inProgressEpisodes`, `starredEpisodes` | For the receipt |
| `sessions`, `estimatedListenSeconds` | Estimated sessions created and their wall time (hours = /3600) |
| `earliestListenAt?` | Earliest estimated listen, for "since {date}" |

### Deletion (`deletions`)
Tombstones for `sync:changes`. `_id`, `table` (currently `queueItems`), `docId` (the deleted row's `_id`, may be `""` if the row never existed), `episodeId?`, `deletedAt` (client `at`), `updatedAt`. Kept 90 days.

### Shared return shapes

- **EpisodeRow** = `{ episode: Episode, state: EpisodeState | null, podcast: PodcastSummary }`
- **PodcastSummary** = `{ _id, title, author?, artworkUrl?, isPrivate }`
- **DirectoryResult** = `{ appleId?: Int, title, author?, artworkUrl?, feedUrl?, genre?, episodeCount?: Int, podcastId?: Id, subscribed: Bool }`. `podcastId` is set when the feed is already in the library.
- **Paginated<T>** = `{ page: [T], isDone: Bool, continueCursor: String }` (plus Convex's optional `splitCursor`, `pageStatus`). Pass `paginationOpts: { numItems: Int, cursor: String | null }`.

## Functions

Every function below also takes `token`. "→" is the return type.

### Library (`podcasts:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `podcasts:list` | query | – | `[Podcast]` subscribed shows, by title. |
| `podcasts:pastShows` | query | – | `[Podcast]` unsubscribed shows that have history (a session, or a played/started/starred episode). |
| `podcasts:get` | query | `podcastId` | `{ podcast, overrides, resolved, feed: { lastCheckedAt?, lastSuccessAt?, nextCheckAt?, lastError? } } \| null`. `overrides`/`resolved` as in `settings:forPodcast`. |
| `podcasts:episodes` | query | `podcastId`, `order?: "newestFirst" \| "oldestFirst"`, `paginationOpts` | `Paginated<EpisodeRow>` by `pubDate`. |
| `podcasts:subscribe` | mutation | `feedUrl`, `at`, `title?`, `author?`, `artworkUrl?`, `appleId?: Int` | `Id<"podcasts">`. Creates the show if needed (URL normalised: `feed://` → `https://`, host lower-cased), subscribes, and fetches it straight away. On a show's **first** fetch only the newest episode gets the new-episode rule, so the Inbox isn't flooded. Pass title/artwork from search so the row looks right before the fetch lands. |
| `podcasts:unsubscribe` | mutation | `podcastId`, `at` | `Bool` changed. Keeps history, stats and queue entries; clears its Inbox entries; stops polling. |
| `podcasts:setPrivate` | mutation | `podcastId`, `isPrivate` | `null`. Feeds with credentials or token-ish query params start private. Private shows are left out of year-in-review lists. |
| `podcasts:markAllPlayed` | mutation | `podcastId`, `at`, `beforePubDate?` | `null`. Runs in background batches. Bulk marks don't count as completions in stats. |

### Discovery (`directory:*`, `feedActions:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `directory:search` | action | `term`, `limit?` (1–200, default 50) | `[DirectoryResult]` from the iTunes Search API (`media=podcast&entity=podcast&country=AU`). Cached 24 h server-side. Debounce 400 ms on the client; Apple allows ~20 calls a minute. |
| `directory:lookup` | action | `appleIdOrUrl` | `DirectoryResult \| null`. Accepts `617416468`, `https://podcasts.apple.com/au/podcast/…/id617416468`, `https://overcast.fm/itunes617416468/…`. |
| `feedActions:previewFeed` | action | `url` | `{ feedUrl, podcastId?, subscribed, title, author?, description?, artworkUrl?, link?, episodeCount: Int, episodes: [{ title, pubDate?, duration?, summary?, enclosureUrl, artworkUrl? }] }` (newest 20). Accepts a feed URL, a website (finds `<link rel="alternate">`), or an Apple / Overcast link. Writes nothing. Subscribe with the returned `feedUrl`. |
| `feedActions:refreshNow` | action | `podcastId?` | `{ scheduled: Int, result?: { status, newEpisodes: Int, error? } }`. With `podcastId`: fetches that show and waits (pull-to-refresh on a show page). Without: schedules every subscribed feed not checked in the last 2 min and returns at once (app foreground, Inbox pull-to-refresh); results arrive through your live queries. `status` is `updated`, `notModified` (304), `unchanged` (same body), `busy` (a fetch is already running) or `error`. |

### Episodes and Inbox (`episodes:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `episodes:inbox` | query | – | `[EpisodeRow]` newest first (max 500). |
| `episodes:starred` | query | – | `[EpisodeRow]` most recently starred first. |
| `episodes:get` | query | `episodeId` | `{ row: EpisodeRow, showNotesHtml?, inQueue: Bool } \| null` |
| `episodes:updatePosition` | mutation | `episodeId`, `position`, `positionUpdatedAt`, `deviceId` | `Bool` applied. LWW on `positionUpdatedAt`; equal times: later arrival wins. Send on pause, every ~30 s while playing, and on episode change. |
| `episodes:setPlayedState` | mutation | `episodeId`, `played`, `at` | `Bool` changed. Played also removes it from the Inbox **and Up Next** (so "episode finished" = one call, and the next queue item becomes first). It counts as a completion in stats. |
| `episodes:setStarredState` | mutation | `episodeId`, `starred`, `at` | `Bool` changed |
| `episodes:setArchivedState` | mutation | `episodeId`, `archived`, `at` | `Bool` changed. Archiving removes it from the Inbox (not from Up Next). Archiving an unplayed episode logs a `skipped` event. |
| `episodes:addToInbox` | mutation | `episodeId`, `at` | `Bool` |
| `episodes:inboxAction` | mutation | `episodeId`, `action: "queueLast" \| "queueNext" \| "archive" \| "markPlayed"`, `at` | `Bool`. The Inbox swipes. Queue actions also take it out of the Inbox. |
| `episodes:archiveAllOlder` | mutation | `episodeId`, `at`, `includeThis?` | `Int` archived. Archives that show's Inbox episodes published before this one. |

### Up Next (`queue:*`)

The first item is what's playing. Order keys are computed on the server.

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `queue:upNext` | query | – | `[{ item: QueueItem, row: EpisodeRow }]` in play order. |
| `queue:add` | mutation | `episodeId`, `position: "top" \| "next" \| "bottom"`, `at` | `Bool` applied. `next` = straight after the first (playing) item. Moves the item if it's already queued. Removes it from the Inbox. |
| `queue:playNow` | mutation | `episodeId`, `at` | `Bool`. Moves it to the top; the old first item becomes second. |
| `queue:move` | mutation | `episodeId`, `afterEpisodeId: Id \| null`, `beforeEpisodeId?: Id \| null`, `at` | `Bool`. Places it directly after `afterEpisodeId` (null = top). If that neighbour has left the queue, directly before `beforeEpisodeId`. For a drag, send both neighbours from what the user saw. |
| `queue:remove` | mutation | `episodeId`, `at` | `Bool` removed |
| `queue:clear` | mutation | `at` | `Int` removed. Only removes items added or moved at or before `at`. |

### Settings (`settings:*`)

Per-show fields (each one "use default" or an explicit value):

| Field | Type | Global default |
|---|---|---|
| `playbackSpeed` | Double | 1.0 |
| `smartSpeed` | Bool | true |
| `voiceBoost` | Bool | true |
| `timePitch` | `"spectral" \| "timeDomain"` | `spectral` |
| `skipIntroSeconds` | Double | 0 |
| `skipOutroSeconds` | Double | 0 |
| `newEpisodes` | `"inbox" \| "upNextTop" \| "upNextBottom" \| "none"` | `inbox` |
| `autoDownload` | `"never" \| "upNext" \| "allNew"` | `upNext` |
| `keepLatestDownloaded` | Int | 3 |
| `notifications` | Bool | false |
| `episodeOrder` | `"newestFirst" \| "oldestFirst"` | `newestFirst` |
| `autoArchiveUnplayedAfterDays` | Int, 0 = never | 0 |
| `skipChapterTitles` | [String] (case-insensitive substrings) | [] |

Global-only fields: `skipBackSeconds` (15), `skipForwardSeconds` (30), `remoteNextPrevious` (`"skip" \| "chapter"`, `skip`), `autoRewind` (true), `advanceToNext` (true), `upNextAutoDownloadCount` (10), `cellularDownloads` (`"never" \| "ask" \| "always"`, `never`), `deletePlayedAfterHours` (24), `storageCapBytes` (5 GiB), `sleepFadeOut` (true), `shakeToRestartSleep` (true), `timeZone` (IANA, `"Australia/Sydney"`; stats bucket days in this zone when a session has no offset).

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `settings:getGlobal` | query | – | Every global field, defaults filled in. |
| `settings:forPodcast` | query | `podcastId` | `{ overrides: { [field]?: value }, resolved: { …every per-show field, inherited: [String] } }`. `inherited` lists fields showing the default (grey "(default)" in the UI). |
| `settings:resolved` | query | `podcastId` | The `resolved` object alone (`override ?? global`). |
| `settings:updateGlobal` | mutation | `patch: { [field]?: value }`, `at` | `[String]` fields applied. |
| `settings:updatePodcast` | mutation | `podcastId`, `patch: { [field]?: value \| null }`, `at` | `[String]` fields applied. A value sets the override; `null` resets to "use default". |

Both updates are LWW **per field**. The speed sheet's scope switch is client logic: write to `updatePodcast` or `updateGlobal` depending on scope.

### Listening sessions (`sessions:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `sessions:record` | mutation | `sessions: [SessionInput]` | `{ inserted, updated, unchanged }` |

`SessionInput` = `{ sessionId (UUID), episodeId, deviceId?, startedAt, endedAt, contentStart, contentEnd, rate, smartSpeed, smartRemovedContent, voiceBoost, route?, utcOffsetMinutes? }`.

- Open a session on play; close it on pause, stop, episode end, rate change, route change, or a seek over 30 s.
- While playing, re-send the **same `sessionId`** every 30 s with the later `endedAt`/`contentEnd`. The server replaces its copy and adjusts the rollups. An identical or older copy is ignored.
- Wall time is `endedAt − startedAt`. Content time is `contentEnd − contentStart` (including any silence Smart Speed cut). So the engine should report `contentEnd` in content time.
- Send `utcOffsetMinutes` (`TimeZone.current.secondsFromGMT(for: start) / 60`) so days and hours bucket correctly while travelling.

### Stats (`stats:*`)

All seconds are wall-clock unless named `content`.

| Function | Kind | Args | Returns |
|---|---|---|---|
| `stats:summary` | query | `period: "week" \| "month" \| "year" \| "all"`, `anchorDay?: "YYYY-MM-DD"` | `Summary` for the calendar period containing `anchorDay` (default today). Weeks start Monday. |
| `stats:forPodcast` | query | `podcastId` | `{ wall, content, timeSaved, sessions: Int, months: [{ month, wall }] }` |
| `stats:yearInReview` | query | `year: Int`, `includePrivate?: Bool` | `YearInReview` |

`Summary`:
```
{ period, startDay, endDay,
  totals: { wall, content, speedSaved, smartSaved, timeSaved, estimatedWall, sessions: Int, averageSpeed: Double | null },
  completion: { started: Int, completed: Int, rate: Double | null },     // started = ≥5 min of content heard
  topShows: [{ podcast: PodcastSummary, wall, content, sessions: Int }], // top 10 by wall time
  topEpisodes: [{ episodeId, title, artworkUrl?, podcast, wall, sessions: Int, starred: Bool }],
  longestStreak: { length: Int, startDay?, endDay? },                   // days with ≥10 min
  currentStreak: { length: Int, startDay?, endDay? },                   // ending today or yesterday
  heatmap: [Double] (168),                                              // live sessions only; index = weekday*24 + hour, Monday = 0
  busiestDay: { day, wall } | null,
  busiestMonth: { month, wall } | null,                                 // year and all only
  days: [{ day, wall }],                                                // week, month, year
  months: [{ month, wall }],                                            // year, all
  includesEstimated: Bool }
```

Maths: speed saving = content × (1 − 1/rate); Smart Speed saving = smartRemovedContent / rate; `timeSaved` is the sum; average speed is weighted by content time. Estimated (imported) sessions count in totals, top shows, completion and streaks, but not the heatmap.

`YearInReview`:
```
{ year, availableFrom: "YYYY-12-01", totals, episodesCompleted: Int,
  topShows (top 5), topEpisode | null, longestStreak, biggestDay | null, busiestMonth | null,
  personality: { key, label, percent: Int } | null,      // e.g. "Night owl: 41% after 9 pm"; keys nightOwl, earlyBird, commuter, weekender, allDay
  firstEpisode: { episodeId, title, podcast, at } | null, lastEpisode: same | null,
  newShows: [PodcastSummary],                             // subscribedAt in that year
  heatmap, months, includesEstimated: Bool, estimatedBefore: ms | null }
```
Private shows are left out of `topShows`, `topEpisode`, `first/lastEpisode` and `newShows` unless `includePrivate` is true. Totals still include them.

### Overcast import (`overcastImport:*`)

1. `overcastImport:generateUploadUrl` (mutation, no args) → upload URL. POST the OPML file to it with `Content-Type: text/xml`; the response JSON has `storageId`.
2. `overcastImport:startOvercastImport` (mutation) `{ storageId?, opml?, assumedSpeed }` → `Id<"importBatches">`. Pass either the uploaded `storageId` (preferred) or the file text as `opml` (fine up to a few MB). `assumedSpeed` is 0.5–3.0, default 1.0 in the UI.
3. Subscribe to `overcastImport:getImport { batchId }` → `ImportBatch | null` and fill in the receipt as the counts grow. `overcastImport:latestImport` → the newest batch or null.

What it does: parses the extended export; creates every show (Overcast's `subscribed=0` shows become past shows); fetches each feed (6 at a time); matches episodes by enclosure URL (query stripped), then GUID, then title + pubDate (within a day); creates archived ghost episodes for ones no longer in the feed; sets played / position / starred / archived with Overcast's `userUpdatedDate` as the LWW time; creates one estimated session per listened episode (played, or progress > 300 s) ending at `userUpdatedDate`, lasting content ÷ `assumedSpeed`. Imported shows' new episodes don't go to the Inbox. `notifications="1"` turns on the show's notification override. Playlists come back in `playlists` so the app can offer "make these shows Priority?".

Re-running is safe: shows match by Overcast ID or feed URL, sessions and events have deterministic IDs, and state only changes where Overcast's date is newer than what Poddle has. If the file is the plain subscriptions export, the batch finishes with `warning` set and only subscriptions imported.

### Devices and push (`devices:*`, `apns:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `devices:register` | mutation | `deviceId` (stable UUID in the Keychain), `name`, `platform` (`"iOS"`, `"macOS"`…), `apnsToken?` (hex), `apnsEnvironment?` | `Id<"devices">`. Upsert; call on launch and whenever the APNs token changes. Debug builds should send `sandbox`. |
| `devices:list` | query | – | `[Device]` |
| `apns:sendTestPush` | action | `message?` | `{ sent: Int, failed: Int, skipped? }` (`skipped`: `unconfigured`, `noDevices`) |

New-episode alerts: `{ aps: { alert: { title: <show>, body: <episode> }, sound: "default", "thread-id": <podcastId> }, episodeId, podcastId }`. Sent for genuinely new episodes (not a show's first fetch, not imports) on shows whose resolved `notifications` is on, to every device with a token. Dead tokens (410 / `BadDeviceToken`) are dropped.

### Sync (`sync:*`)

| Function | Kind | Args | Returns |
|---|---|---|---|
| `sync:changes` | query | `table`, `since: ms`, `paginationOpts` | `{ page: [Document], isDone, continueCursor, maxUpdatedAt: ms \| null }` |

`table` is one of `podcasts`, `episodes`, `episodeNotes`, `episodeStates`, `queueItems`, `podcastSettings`, `globalSettings`, `listeningSessions`, `libraryEvents`, `devices`, `importBatches`, `deletions`.

## Offline and outbox contract

**Reads.** The app keeps a local cache of the tables above.
- While online, use live subscriptions for what's on screen (`queue:upNext`, `episodes:inbox`, `podcasts:list`, …) and write what they return into the cache.
- To catch up after being offline (or on first launch), call `sync:changes` per table:
  1. Keep a `since` per table (start at 0, which is a full snapshot).
  2. Page with `cursor: null` and then `continueCursor` until `isDone`. Upsert every document by `_id`.
  3. Afterwards, set `since = max(since, maxUpdatedAt of every page)`.
  4. Apply `deletions` by deleting `docId` from the cache table named in `table`.
- The server re-sends a 30 s overlap before `since`, because a mutation stamps `updatedAt` slightly before it commits. Duplicates are expected; upserts make them harmless.
- Tombstones are kept for 90 days. If the app has been offline longer, resync that table from `since = 0`.
- Stats aren't synced: they're live queries over server-side rollups. Cache the last result for offline display.

**Writes.** Every mutation is safe to replay from an outbox:
- Put each user action in the outbox with `at` = the device time when the user did it, and replay in order, unchanged, until the server accepts it. Don't re-stamp `at` on retry.
- Episode state, settings, subscriptions and queue changes are **last-writer-wins on `at`**, per field. A replayed change older than what the server has is ignored. The mutation returns `false`, and the app should drop the op and take the server's value from its subscription or the next `sync:changes`. Equal times: the later arrival wins.
- Position uses `positionUpdatedAt` the same way. While a device is playing an episode it owns the position: ignore incoming position updates for that episode until it pauses (client logic).
- Queue items remember their last add/move time, and removals leave a tombstone. So a stale "add" or "move" can't resurrect or reorder an item that another device has since removed or moved. `queue:clear` only removes items added before it.
- Sessions are keyed by the client `sessionId`, so re-sending is idempotent.
- `podcasts:subscribe` is keyed by feed URL, and `devices:register` by `deviceId`.
- Actions (`refreshNow`, `search`, `previewFeed`) are online-only. Don't queue them.
- Server-side changes (auto-adding a new episode to the Inbox or Up Next, auto-archive) are stamped 10 minutes in the past, so a user action from a device whose clock runs a little slow still wins.

## Behaviour notes for the app

- **New episodes:** a show's resolved `newEpisodes` decides where new episodes go. `upNextTop` inserts **after** the first (playing) item rather than replacing it. Items older than the show's previous newest episode by more than 2 days (back-catalogue dumps) aren't auto-added, and at most 10 per fetch are.
- **Polling:** a cron runs every 15 min. Each feed has its own `nextCheckAt`: 15 min if it published in the last week, 1 h within a month, 4 h within six months, else 12 h. Errors back off exponentially up to 24 h. Conditional GET is used, and an unchanged body is skipped.
- **Feed identity:** GUID, then enclosure URL (query stripped), then title + pubDate. Feed refreshes only touch feed fields, never `episodeStates`.
- **Duration** may be absent (`itunes:duration` missing, or a ghost). Read it from the file and display it locally.
- **Daily housekeeping** (16:00 UTC): applies `autoArchiveUnplayedAfterDays` to Inbox items, drops tombstones older than 90 days and clears the directory cache.
