# Poddle backend API

The contract between the Convex backend (`convex/`) and the Swift app (`Packages/PoddleKit`). If the code and this file disagree, the code is wrong or this file is stale: fix one of them in the same change.

## Calling convention

- Functions are addressed as `"module:function"`, e.g. `"queue:add"`.
- **Every public function acts for the signed-in caller** (Convex Auth, see [Accounts and sign-in](#accounts-and-sign-in)). Send the access token as the client's auth token; there's no token arg. Not signed in (or a session for a user that no longer exists) throws a `ConvexError` `{ code: "unauthenticated", message }`.
- **Admin path for scripts:** any public function also takes an optional `admin: { token, email }`. The token is compared in constant time with `PODDLE_API_TOKEN` and the call acts as the user with that email. Wrong token: `{ code: "unauthorized" }`; none set on the server: `{ code: "unconfigured" }`; no such user: `{ code: "unknownUser" }`. The app never sends it.
- Everything a function reads or writes is the caller's: their subscriptions, episode state, queue, settings, sessions, stats, imports and devices. Shows and episodes are shared catalog data, the same for everyone.
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
| `AUTH_PRIVATE_KEY`, `AUTH_JWKS` | yes | Convex Auth's signing keys. `node scripts/set-auth-keys.mjs <dev\|prod>` |
| `AUTH_APPLE_CLIENT_ID`, `AUTH_APPLE_TEAM_ID`, `AUTH_APPLE_KEY_ID`, `AUTH_APPLE_PRIVATE_KEY` | yes (placeholder ok) | Sign in with Apple: Services ID, team, key ID, `.p8` contents. `node scripts/set-oauth-keys.mjs` |
| `AUTH_GOOGLE_CLIENT_ID`, `AUTH_GOOGLE_CLIENT_SECRET` | yes (placeholder ok) | Google OAuth "Web application" client |
| `PODDLE_ALLOWED_EMAILS` | for sign-up | Comma-separated emails that may make an account. Unset: nobody new. Existing accounts always sign in. |
| `PODDLE_TEST_SIGNIN` | dev only | Exactly `1` enables test sign-in. Never set it on prod (it's refused on prod's addresses anyway). |
| `PODDLE_API_TOKEN` | for scripts | Long random string for the admin path. |
| `APNS_KEY_P8` | for push | Contents of the `.p8` auth key. PEM (newlines or literal `\n`) or the bare base64 body. |
| `APNS_KEY_ID` | for push | The key's 10-character ID. |
| `APNS_TEAM_ID` | for push | `4DTAZSZL6B` |
| `APNS_TOPIC` | for push | `com.mikecann.poddle` |
| `APNS_ENV` | for push | `sandbox` (default) or `production`. A device's own `apnsEnvironment` overrides it. |

Without the four required APNs vars, every push is a logged no-op.

Convex Auth's components refuse to deploy unless every provider variable has a value, so before Apple and Google are set up run `node scripts/set-oauth-keys.mjs <dev|prod> --placeholders`: it sets the missing ones to `not-configured`, and only signing in with that provider fails.

## Accounts and sign-in

Convex Auth v2 (`@convex-dev/auth` 2.0.0-beta.0), set up like Walkies: `convex/convex.config.ts`, `convex/auth.ts`, `convex/users.ts`, `convex/http.ts`.

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `auth:startSignInWithApple`, `auth:startSignInWithGoogle` | mutation | `redirectTo` (`<site>/app/signed-in`) | `{ redirect, state }`. Open `redirect` in `ASWebAuthenticationSession`. The provider sends people to `<site>/oauth/<provider>/callback`, which ends on `<site>/app/signed-in?convexAuthCode=…`, which 302s to `poddle://signed-in?…` for the sheet to catch. `convexAuthError=access_denied` means they cancelled. |
| `auth:completeSignInWithApple`, `auth:completeSignInWithGoogle` | mutation | `code`, `state` | `{ status: "complete", tokens: { accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt, userId } }` (times in ms). Someone not on the allowlist gets `ConvexError { code: "inviteOnly", message: "Poddle is invite-only for now." }`. |
| `auth:refreshSession` | mutation | `refreshToken` | `{ kind: "rotated", tokens }` or `{ kind: "noSession" }` (signed out). Access tokens last a minute; refresh tokens rotate, so refresh one at a time. |
| `auth:signOut` | mutation | `refreshToken` | `null` |
| `auth:signInForTesting` | mutation | `email?` | Dev only (`PODDLE_TEST_SIGNIN=1`). Signs in as the user with that email, making a test user if there isn't one; without an email, a fresh test user. Same result shape as `complete…`. Refused with `{ code: "testSignInDisabled" }` everywhere else, including direct `auth:signInAnonymously` calls. |
| `users:me` | query | – | `{ userId, name, email, picture } \| null` |

- **One person, two providers:** Apple and Google with the same verified email land in the same user (`existingUser` in `users.ts`). Apple's "Hide my email" relay addresses are different emails, so they don't match (and aren't on the allowlist).
- **Allowlist:** `PODDLE_ALLOWED_EMAILS`, enforced in one place (`convex/lib/allowlist.ts`, called only when a new user would be made). To open sign-up, make `maySignUp` return true.
- **Return URLs to register** with Apple and Google: `https://striped-turtle-260.ap-southeast-2.convex.site/oauth/{apple,google}/callback` (dev) and `https://coordinated-dodo-120.ap-southeast-2.convex.site/oauth/{apple,google}/callback` (prod). Convex Auth builds them from `CONVEX_SITE_URL`.
- **Custom domain:** if prod's `CONVEX_SITE_URL` is overridden to `https://poddle.mikecann.app`, the callbacks become `https://poddle.mikecann.app/oauth/{apple,google}/callback` (register those too, and add the domain to the Apple Services ID), JWTs are issued by and verified against that URL (`convex/auth.config.ts`), so existing sessions stop working and everyone signs in once more, and the app's `returnURL` must follow (it's derived from the `.convex.cloud` URL today, `LiveConfig.siteURL`). The website, which will sign in with the same Convex Auth, adds its own origin to `allowedRedirectOrigins` in `convex/auth.ts`.

## Documents

These are the shapes returned by queries and by `sync:changes`. Every synced table has `updatedAt` (server ms).

Every personal document below (episode state, queue item, settings, session, event, device, import batch, deletion) also has `userId`, always the caller's.

### Podcast (`podcasts`)
The shared show with the caller's subscription merged in. `_id`, `feedUrl`, `title`, `author?`, `description?`, `artworkUrl?`, `link?`, `language?`, `appleId?: Int`, `overcastId?: Int`, `isPrivate: Bool` (the caller's own switch, else the show's default), `subscribed: Bool`, `subscribedAt?` (first subscribe; Overcast's added date on import), `unsubscribedAt?`, `subscriptionUpdatedAt` (LWW clock, 0 if never), `latestEpisodeAt?`, `episodeCount: Int`, `lastFetchedAt?`, `createdAt`, `updatedAt` (the later of the show's and the subscription's). Stored as a shared `podcasts` row plus a personal `subscriptions` row per person who has the show in their library (subscribed or not).

### Episode (`episodes`)
Feed data only, never user state. `_id`, `podcastId`, `guid?`, `enclosureUrl?`, `enclosureKey?` (for matching: no query, scheme or tracking-redirect prefixes), `enclosureType?`, `enclosureLength?: Int`, `title`, `summary?` (plain text, ≤280 chars), `link?`, `pubDate?`, `duration?` (seconds; absent if the feed doesn't say), `chaptersUrl?`, `chaptersType?`, `transcripts: [{ url, type, language?, rel? }]`, `artworkUrl?` (episode art; fall back to the show's), `season?`, `episodeNumber?`, `episodeType?` (`full`/`trailer`/`bonus`), `explicit?: Bool`, `isGhost: Bool` (only known from the Overcast import; no longer in the feed, may have no enclosure), `firstSeenAt`, `updatedAt`.

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
`_id`, `source: "overcast"`, `status` (`parsing` → `fetching` → `done`, or `failed`), `assumedSpeed`, `startedAt`, `finishedAt?`, `error?`, `warning?`, `playlists: [{ title, smart: Bool, sorting?, podcastIds: [Id], priorityPodcastIds?: [Id], episodeCount? }]` (every Overcast playlist; `podcastIds` is what a smart playlist is limited to, `episodeCount` how many episodes it lists by hand), `failedFeeds?: [{ podcastId, title, feedUrl, status?: Int, error }]` (feeds that couldn't be fetched; `status` is the HTTP status when there was one), `medianDuration?` (seconds, used for unknown durations), `upNextPlan?` (internal: how Up Next gets seeded), `updatedAt`, and `counts`:

| Count | Meaning |
|---|---|
| `podcasts`, `subscribedPodcasts` | Shows in the file / still subscribed in Overcast |
| `podcastsProcessed`, `feedsFailed` | Progress through the feed fetches. Done when `podcastsProcessed == podcasts`. |
| `episodes` | Episode rows in the file |
| `episodesMatched`, `ghostEpisodes` | Matched to a feed episode / created as ghosts |
| `ghostsOlderThanFeed?`, `ghostsMissingFromFeed?`, `ghostsFeedFailed?` | Why: older than anything the feed still lists / removed from inside the feed's range / feed failed |
| `playedEpisodes`, `inProgressEpisodes`, `starredEpisodes` | For the receipt |
| `sessions`, `estimatedListenSeconds` | Estimated sessions created and their wall time (hours = /3600) |
| `estimatedDurationSessions?` | Sessions whose episode length was unknown and used the show's (or overall) median |
| `upNextEpisodes?` | In Up Next when the import finished |
| `earliestListenAt?` | Earliest estimated listen, for "since {date}" |

### Deletion (`deletions`)
Tombstones for `sync:changes`. `_id`, `table` (currently `queueItems`), `docId` (the deleted row's `_id`, may be `""` if the row never existed), `episodeId?`, `deletedAt` (client `at`), `updatedAt`. Kept 90 days.

### Shared return shapes

- **EpisodeRow** = `{ episode: Episode, state: EpisodeState | null, podcast: PodcastSummary }`
- **PodcastSummary** = `{ _id, title, author?, artworkUrl?, isPrivate }`
- **DirectoryResult** = `{ appleId?: Int, title, author?, artworkUrl?, feedUrl?, genre?, episodeCount?: Int, podcastId?: Id, subscribed: Bool }`. `podcastId` is set when the feed is already in the library.
- **Paginated<T>** = `{ page: [T], isDone: Bool, continueCursor: String }` (plus Convex's optional `splitCursor`, `pageStatus`). Pass `paginationOpts: { numItems: Int, cursor: String | null }`.

## Functions

Every function below acts for the signed-in caller (and also takes the optional `admin`). "→" is the return type.

### Library (`podcasts:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `podcasts:list` | query | – | `[Podcast]` subscribed shows, by title. |
| `podcasts:pastShows` | query | – | `[Podcast]` unsubscribed shows that have history (a session, or a played/started/starred episode). |
| `podcasts:get` | query | `podcastId` | `{ podcast, overrides, resolved, feed: { lastCheckedAt?, lastSuccessAt?, nextCheckAt?, lastError? } } \| null`. `overrides`/`resolved` as in `settings:forPodcast`. |
| `podcasts:episodes` | query | `podcastId`, `order?: "newestFirst" \| "oldestFirst"`, `paginationOpts` | `Paginated<EpisodeRow>` by `pubDate`. |
| `podcasts:subscribe` | mutation | `feedUrl`, `at`, `title?`, `author?`, `artworkUrl?`, `appleId?: Int` | `Id<"podcasts">`. Creates the show if needed (URL normalised: `feed://` → `https://`, host lower-cased), subscribes, and fetches it straight away. On a show's **first** fetch only the newest episode gets the new-episode rule, so Up Next isn't flooded. Pass title/artwork from search so the row looks right before the fetch lands. |
| `podcasts:unsubscribe` | mutation | `podcastId`, `at` | `Bool` changed. Keeps history, stats and queue entries; clears its Inbox entries; stops polling. |
| `podcasts:setPrivate` | mutation | `podcastId`, `isPrivate` | `null`. Your own switch. Feeds with credentials or token-ish query params start private. Private shows are left out of your year-in-review lists. |
| `podcasts:markAllPlayed` | mutation | `podcastId`, `at`, `beforePubDate?` | `null`. Runs in background batches. Bulk marks don't count as completions in stats. |

### Discovery (`directory:*`, `feedActions:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `directory:search` | action | `term`, `limit?` (1–200, default 50) | `[DirectoryResult]` from the iTunes Search API (`media=podcast&entity=podcast&country=AU`). Cached 24 h server-side. Debounce 400 ms on the client; Apple allows ~20 calls a minute. |
| `directory:lookup` | action | `appleIdOrUrl` | `DirectoryResult \| null`. Accepts `617416468`, `https://podcasts.apple.com/au/podcast/…/id617416468`, `https://overcast.fm/itunes617416468/…`. |
| `feedActions:previewFeed` | action | `url` | `{ feedUrl, podcastId?, subscribed, title, author?, description?, artworkUrl?, link?, episodeCount: Int, episodes: [{ title, pubDate?, duration?, summary?, enclosureUrl, artworkUrl? }] }` (newest 20). Accepts a feed URL, a website (finds `<link rel="alternate">`), or an Apple / Overcast link. Writes nothing. Subscribe with the returned `feedUrl`. |
| `feedActions:refreshNow` | action | `podcastId?` | `{ scheduled: Int, result?: { status, newEpisodes: Int, error? } }`. With `podcastId`: fetches that show and waits (pull-to-refresh on a show page). Without: schedules every subscribed feed not checked in the last 2 min and returns at once (app foreground, Up Next pull-to-refresh); results arrive through your live queries. `status` is `updated`, `notModified` (304), `unchanged` (same body), `busy` (a fetch is already running) or `error`. |

### Episodes (`episodes:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `episodes:inbox` | query | – | **Deprecated.** `[EpisodeRow]` newest first (max 500). There's no Inbox any more, nothing new goes into it, and `migrations:retireInbox` empties it, so this returns `[]`. Kept while the app still subscribes to it. |
| `episodes:starred` | query | – | `[EpisodeRow]` most recently starred first. |
| `episodes:get` | query | `episodeId` | `{ row: EpisodeRow, showNotesHtml?, inQueue: Bool } \| null` |
| `episodes:updatePosition` | mutation | `episodeId`, `position`, `positionUpdatedAt`, `deviceId` | `Bool` applied. LWW on `positionUpdatedAt`; equal times: later arrival wins. Send on pause, every ~30 s while playing, and on episode change. |
| `episodes:setPlayedState` | mutation | `episodeId`, `played`, `at` | `Bool` changed. Played also removes it from the Inbox **and Up Next** (so "episode finished" = one call, and the next queue item becomes first). It counts as a completion in stats. |
| `episodes:setStarredState` | mutation | `episodeId`, `starred`, `at` | `Bool` changed |
| `episodes:setArchivedState` | mutation | `episodeId`, `archived`, `at` | `Bool` changed. Archiving removes it from the Inbox (not from Up Next). Archiving an unplayed episode logs a `skipped` event. |
| `episodes:archiveAllOlder` | mutation | `episodeId`, `at`, `includeThis?` | `Int` archived. Archives that show's Inbox episodes published before this one. With the Inbox gone it finds nothing; kept while the app still calls it. |

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
| `timePitch` | `"spectral" \| "timeDomain"` | `timeDomain` (the speed-up method: "Speech-tuned"; `spectral` is "Apple spectral") |
| `skipIntroSeconds` | Double | 0 |
| `skipOutroSeconds` | Double | 0 |
| `newEpisodes` | `"upNextBottom" \| "upNextTop" \| "none"` (`"inbox"` is deprecated: still accepted, stored as `upNextBottom` on write, and a stored one resolves to and behaves as `upNextBottom`) | `upNextBottom` |
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

What it does: parses the extended export; creates every show (only `subscribed="1"` shows are subscribed; the rest become past shows); fetches every feed (6 at a time), then matches each show's episodes by enclosure (query, http/https and tracking redirects like `dts.podtrac.com/redirect.mp3/` ignored), then GUID, then link (Overcast's `url`, if only one feed item has it), then title + pubDate (within a day), then a title only one feed item has; creates ghost episodes for ones no longer in the feed; sets played / position / starred with Overcast's `userUpdatedDate` as the LWW time; creates one estimated session per listened episode (played, or progress > 300 s) ending at `userUpdatedDate`, lasting content ÷ `assumedSpeed`, where content is the episode's duration if played (the show's median duration if unknown, else the overall median) or the progress if not. `notifications="1"` turns on the show's notification override.

Up Next (decisions.md): Overcast has no Inbox, so unplayed, undeleted episodes of subscribed shows go to Up Next, plus episodes a subscribed show has published since the newest one in the export (the export only lists episodes he's touched). Order follows Overcast's main playlist ("All Episodes"): manual playlists' `includeEpisodeIds` and its `sortedEpisodeIds` first, then its `priorityPodcastIds` shows, then the rest, by its `sorting` (newest first unless `chronological`). Everything else in the export is archived, so the Inbox is empty afterwards. `priorityPodcastIds` shows get the `newEpisodes = upNextTop` override.

Re-running is safe: shows match by Overcast ID or feed URL, sessions and events have deterministic IDs, and state only changes where Overcast's date is newer than what Poddle has. A show an earlier import wrongly subscribed is unsubscribed again unless it's been changed in Poddle since. Up Next never gets duplicates, and episodes removed from Up Next, played or archived in Poddle since aren't re-added. If the file is the plain subscriptions export, the batch finishes with `warning` set and only subscriptions imported.

### Devices and push (`devices:*`, `apns:*`)

| Function | Kind | Args | Returns / behaviour |
|---|---|---|---|
| `devices:register` | mutation | `deviceId` (stable UUID in the Keychain), `name`, `platform` (`"iOS"`, `"macOS"`…), `apnsToken?` (hex), `apnsEnvironment?` | `Id<"devices">`. Upsert for the caller; call on launch, after signing in and whenever the APNs token changes. A device (and its token) belongs to whoever registered it last: rows other people had for it stop getting pushes. Debug builds should send `sandbox`. |
| `devices:list` | query | – | `[Device]` |
| `apns:sendTestPush` | action | `message?` | `{ sent: Int, failed: Int, skipped? }` (`skipped`: `unconfigured`, `noDevices`) |

New-episode alerts: `{ aps: { alert: { title: <show>, body: <episode> }, sound: "default", "thread-id": <podcastId> }, episodeId, podcastId }`. Sent for genuinely new episodes (not a show's first fetch, not imports) to each subscriber whose resolved `notifications` is on for that show, on that person's devices only. Dead tokens (410 / `BadDeviceToken`) are dropped.

### Sync (`sync:*`)

| Function | Kind | Args | Returns |
|---|---|---|---|
| `sync:changes` | query | `table`, `since: ms`, `paginationOpts` | `{ page: [Document], isDone, continueCursor, maxUpdatedAt: ms \| null }` |

`table` is one of `podcasts`, `episodes`, `episodeStates`, `queueItems`, `podcastSettings`, `globalSettings`, `listeningSessions`, `libraryEvents`, `devices`, `importBatches`, `deletions`. Only the caller's data comes back.

- Personal tables are read off their `by_user_updatedAt` index.
- Shared shows and episodes come through the caller's library: one `subscriptions` row per show they've subscribed to or have any state for (an episode state, queue item, setting or session makes one, unsubscribed). `podcasts` walks those rows and sends each show whose own or subscription `updatedAt` is in range. `episodes` walks them and, per show, reads `by_podcast_updatedAt` from `since`; a show that joined the library after `since` sends its whole back catalogue, so a new subscription to an old show still fills in. A show nobody in your library points at never reaches you. (Pages may come back short after filtering; keep paging until `isDone`.)
- `episodeNotes` isn't synced (it never was used offline): `episodes:get` returns show notes.

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
- Server-side changes (auto-adding a new episode to Up Next, auto-archive) are stamped 10 minutes in the past, so a user action from a device whose clock runs a little slow still wins.

## Behaviour notes for the app

- **New episodes:** a feed is polled once for everyone. Each new episode is then applied to each subscriber with their own resolved `newEpisodes` for the show. Subscribing to a show someone else already has puts its newest episode in your Up Next (per your rule) straight away, like a first fetch.
- **Per show:** your resolved `newEpisodes` decides where new episodes go. `upNextTop` inserts **after** the first (playing) item rather than replacing it. There's no Inbox: nothing is ever put in one, and a stored `inbox` rule (global or per show) goes to the bottom of Up Next. New-episode push notifications follow the show's `notifications` setting. Items older than the show's previous newest episode by more than 2 days (back-catalogue dumps) aren't auto-added, and at most 10 per fetch are.
- **Polling:** a cron runs every 15 min. Each feed has its own `nextCheckAt`: 15 min if it published in the last week, 1 h within a month, 4 h within six months, else 12 h. Errors back off exponentially up to 24 h. Conditional GET is used, and an unchanged body is skipped.
- **Feed identity:** GUID, then enclosure URL (query stripped), then title + pubDate. Feed refreshes only touch feed fields, never `episodeStates`.
- **Duration** may be absent (`itunes:duration` missing, or a ghost). Read it from the file and display it locally.
- **Daily housekeeping** (16:00 UTC): for each person, applies their `autoArchiveUnplayedAfterDays` to their Inbox and drops their tombstones older than 90 days; then clears the directory cache.
- **Polling** stays on while anyone subscribes to a feed (`feedStates.active`).

## Accounts migration

`convex/migrations.ts` turned the single-user data into Mike's account (docs/runbooks/accounts-prod.md): `migrations:run` makes his user (`mike.cann@gmail.com`, verified) if needed, gives every personal row without an owner to him, and moves the old `subscribed`/`subscribedAt`/`unsubscribedAt`/`subscriptionUpdatedAt` fields off each shared show into a `subscriptions` row of his. Idempotent. `migrations:report` counts `total`, `unowned` and `legacy` rows per table; done means zeros in the last two. Until it has run on prod, `userId` is optional in the schema (`vOwner`).

## Retiring the Inbox

`migrations:retireInbox` (docs/runbooks/accounts-prod.md, step 3b) runs per person (`migrations:retireInboxFor`, in batches of 200). Every episode in their Inbox that isn't archived, played or already queued goes to the bottom of their Up Next, oldest `pubDate` first, through the same queue helper as `queue:add` (server-computed fractional keys, LWW at server time minus 10 minutes, `addedBy: "auto"`); then every Inbox entry is cleared (`inInbox: false`, no `inboxAt`). Stored `inbox` rules become `upNextBottom`, and a per-show `inbox` override that then matches the global rule is cleared to "use default". Every touched row gets a new `updatedAt`, so `sync:changes` delivers them. Idempotent. `migrations:inboxReport` lists, per person, `inbox`, `toMove`, `upNext`, `globalInboxRule` and `showInboxRules`; done means zeros in all but `upNext`.
