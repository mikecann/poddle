# Personal podcast player: product spec (v1 draft)

Working name: **Pod** (it's Poddle now, `decisions.md`). SwiftUI multiplatform app (iPhone first, iPad and Mac later), made for one listener.

Claims marked **[verified]** were checked against a source listed at the end. Claims marked **[inferred]** are my own design reasoning or memory and haven't been checked.

---

## 1. Goals and non-goals

### Goals (v1)
- Mike's everyday podcast player on iPhone, with nothing important missing.
- Bring in all Overcast data (subscriptions, played state, progress, stars, history) so stats are real from day one.
- Playback with pitch-corrected speed, Smart Speed, Voice Boost, chapters, sleep timer, and proper lock screen, AirPods and AirPlay support.
- Per-podcast overrides that just work.
- Stats and a year in review he'd actually want to share.
- Gestures everywhere. Every list row can be swiped, long-pressed and dragged.
- A single SwiftUI codebase for iOS, iPadOS and macOS from the first commit, so iPad and Mac are a layout job later, not a port.
- New-episode notifications that actually arrive (so a server, see §2.11).

### Non-goals (v1)
- Apple Watch, CarPlay, widgets, Siri/App Intents (beyond what Now Playing gives for free), Live Activities.
- Social features, comments, recommendations, multiple users.
- Video podcasts (play the audio track only).
- App Store release, localisation, accessibility beyond SwiftUI defaults plus VoiceOver labels.
- Generating transcripts on device.
- Podcasting 2.0 value-for-value or boosts.

---

## 2. Features and behaviours

### 2.1 Library and discovery

**Apple Podcasts directory (v1)**
- Search: `https://itunes.apple.com/search?term=…&media=podcast&entity=podcast&country=AU&limit=50` **[verified: URL format, `media`, `entity`, `limit` 1–200]**.
- Each result's `feedUrl` gives the RSS feed. Subscribe by fetching that feed directly, and never use the API's episode lists, which top out at 200 **[verified via third-party benchmark, not Apple docs]**.
- Lookup by ID (`/lookup?id=…`) for pasted `podcasts.apple.com/…/id123456` links.
- The rate limit is about 20 calls a minute **[verified]**. Debounce search by 400 ms and cache results for 24 h.
- Search UI: results come as you type. Each row shows artwork, title, author and a subscribe (+) button. Tap opens a preview of the feed before you subscribe.

**Podcast Index (later)**
- It's free with an API key and adds Podcasting 2.0 metadata and shows that aren't on Apple **[inferred; their docs page wouldn't render for me]**.
- Not worth it for v1, because add-by-URL covers the gaps. Add it later as a second search source if Apple search misses things.

**Add by URL (v1)**
- Paste box on the Add screen. If the clipboard holds a URL, offer it automatically.
- Accepts: an RSS/Atom URL, a `podcasts.apple.com` link (resolved via Lookup), an `overcast.fm/itunes…` link (pull the Apple ID out), or a website (look for `<link rel="alternate" type="application/rss+xml">`).
- Also a share extension: share a link from Safari and it gets subscribed.

**Private and authenticated feeds (v1)**
- Token-in-URL feeds (the usual pattern, including Mike's AI feed): store the full URL in Keychain and show it masked in the UI.
- HTTP Basic auth: accept `https://user:pass@host/feed`, or a username/password form. Credentials go in Keychain, and the `Authorization` header is sent on feed and enclosure requests to the same host.
- Flag private feeds `isPrivate = true`: never sent to Apple or Podcast Index lookups, and never shown in the share image.
- If the server polls private feeds (§2.11), the credentials have to live on the server too (see Open question 2).

**Library screen**
- Grid or list toggle. Sort by: recently updated (default), title, most listened, or date added.
- Unsubscribed shows that still have history stay findable under a "Past shows" filter, so imported history isn't orphaned.

### 2.2 Import from Overcast

**Getting the file:** overcast.fm → Account → "All data" export. The extended export is served from `https://overcast.fm/account/export_opml/extended` **[verified via two third-party tools]**. The plain subscriptions export is OPML with just `type="rss"` outlines (`text`, `title`, `xmlUrl`, `htmlUrl`, `overcastId`) **[verified]**. Only the extended export carries episode state, so the importer should require it and warn if it gets the plain one (no `podcast-episode` outlines).

**Structure of the extended export.** I rebuilt this from parser code and test fixtures in `overcast-to-sqlite`. The attribute names and formats are verified; the overall document shape is close to, but may not exactly match, a real export:

```xml
<opml version="1.0">
  <body>
    <outline text="playlists">
      <outline type="podcast-playlist" title="Morning Queue"
               smart="1" sorting="manual" includePodcastIds="101,202"/>
    </outline>
    <outline text="feeds">
      <outline type="rss" overcastId="101" text="Example Show" title="Example Show"
               xmlUrl="https://example.com/feed.xml" htmlUrl="https://example.com"
               subscribed="1" notifications="0"
               overcastAddedDate="2025-01-01T00:00:00Z">
        <outline type="podcast-episode" overcastId="555" title="Ep 1"
                 pubDate="Thu, 02 Jan 2025 00:00:00 GMT"
                 url="https://example.com/ep1" overcastUrl="https://overcast.fm/+…"
                 enclosureUrl="https://cdn.example.com/ep1.mp3"
                 played="1" progress="3600" userDeleted="0"
                 userUpdatedDate="2025-01-03T08:12:00Z"
                 userRecommendedDate="2025-01-03T08:15:00Z"/>
      </outline>
    </outline>
  </body>
</opml>
```

**Mapping**

| Overcast attribute | App field | Notes |
|---|---|---|
| feed `xmlUrl` | `Podcast.feedURL` | Re-fetch every feed after import to get current metadata. |
| feed `overcastId` | `Podcast.importRefs.overcastId` | Used to resolve playlist `includePodcastIds`. |
| `subscribed` 1/0 | `Podcast.subscribed` | Import `0` shows as unsubscribed so their history is kept. |
| `notifications` | `PodcastSettings.notify` | |
| `overcastAddedDate` | `Podcast.subscribedAt` | Feeds the "shows added this year" stat. |
| episode `enclosureUrl` | match key | Strip the query string **[verified that the tool does this]**, then match against the feed's enclosures. Fall back to GUID, then title + pubDate. |
| `played` | `EpisodeState.played` | |
| `progress` (seconds) | `EpisodeState.position` | |
| `userUpdatedDate` | `EpisodeState.updatedAt` and the estimated listen date | This is the "last touched" date, not the listen date **[inferred]**. |
| `userRecommendedDate` | `EpisodeState.starredAt` | Overcast's star/recommend **[verified]**. |
| `userDeleted` | `EpisodeState.archived = true` | Played-and-deleted is normal. Deleted-but-unplayed means skipped, which feeds the "skipped" stat. |
| `podcast-playlist` (`smart`, `sorting`, `includePodcastIds`) | not imported as playlists | Offer "make these shows Priority?" for shows in his main playlist. |

Episodes in the export that are no longer in the feed get created as **archived ghost episodes**: title, pubDate and enclosure from the OPML, duration unknown. This keeps the history and counts complete.

**What can't be recovered**
- No listening sessions: no start or end times, no speed used, no Smart Speed savings, no device. The export has state, not a log **[verified: no such attributes in the parser]**.
- No episode durations in the export **[inferred from the attribute list]**. Get them from the RSS `itunes:duration`. If that's missing, read the duration from the file's header with a ranged request on demand.
- `userUpdatedDate` can move if he later deleted or starred an episode.
- Old Overcast speed settings and per-show settings aren't in the export.

**Estimating imported listening time**
- Create one `ListeningSession` per played (or part-played) episode, with `source = .overcastImport` and `isEstimated = true`.
- Content time: `duration` if played, otherwise `progress`. `overcast-to-sqlite` counts an episode as listened when `played=1 OR progress>300` **[verified]**. Use the same rule.
- Wall-clock time: content time ÷ the speed he says he usually used (one question at import, default 1.0×). Smart Speed savings are recorded as 0.
- Timestamp: `endedAt = userUpdatedDate`, `startedAt = endedAt − wallTime`.
- Stats that need real times leave estimated sessions out: the time-of-day heatmap, session-length charts and the "by device" breakdown. Totals, top shows, completion and day-level streaks include them. The UI shows "includes estimated history before {import date}".
- Import is idempotent: re-running it updates rows matched by enclosure or `overcastId` and never duplicates sessions.

**Apple Podcasts (brief)**
- There's no official OPML export on iOS or macOS since Catalina **[verified, community sources]**.
- On the Mac, subscriptions have been reported in `~/Library/Containers/com.apple.podcasts/Data/Documents/PodcastsDB.plist`, and the `kasparsd/podcasts-tools` script converts it to OPML **[verified as reported, not tested]**.
- Fallback: a "paste a list of show names" importer that runs each name through iTunes Search and asks him to confirm the matches.
- Generic OPML import (subscriptions only) comes free with the Overcast importer.

### 2.3 Queue model

**Recommendation for v1: Inbox plus a single Up Next queue, plus Priority podcasts.**
- **Inbox:** new episodes from subscribed shows land here, newest first. Swipe to queue or archive.
- **Up Next:** one ordered queue that you drag to reorder. Playback advances through it.
- **Priority podcasts:** a per-show setting. New episodes skip the Inbox and go straight into Up Next, either at the top ("Play next") or the bottom.
- **Auto-add:** a per-show setting with three options: Inbox (default), Up Next bottom, or Up Next top.

Why not Overcast-style playlists in v1:
- One listener, one context. Here smart playlists would mostly stand in for a queue, and an explicit queue plus Priority covers that.
- One ordered list is much easier to sync without conflicts (fractional order keys, §2.12) than several smart and manual lists.
- Gestures stay simple: "queue next" and "queue last" mean exactly one thing.
- **Later:** saved filters ("Unplayed under 20 min", "Starred", "Show X backlog") as read-only views you can play from, not as competing queues.

### 2.4 Playback

**Engine [design, inferred]**
- Smart Speed and Voice Boost need direct access to the audio samples, so the main path is **AVAudioEngine**: `AVAudioPlayerNode` → `AVAudioUnitTimePitch` → EQ and dynamics → output, playing from a **local file**.
- If the file isn't downloaded yet: play with `AVPlayer` (speed only) while it downloads, then switch to the engine at the same position once the file is complete (see Open question 5).
- The audio session uses category `.playback`, mode `.spokenAudio`, and route-sharing policy `.longFormAudio` so it routes properly to AirPlay 2 and AirPods **[inferred]**.

**Pitch-corrected speed**
- `AVAudioUnitTimePitch.rate` changes rate and pitch independently **[verified]**. Algorithm options **[verified, Apple docs]**:
  - `timeDomain`: "modest quality … suitable for voice", and cheap.
  - `spectral`: "highest quality … suitable for music".
  - `varispeed`: no pitch correction (chipmunk effect).
  - `lowQualityZeroLatency`: the lowest quality and cheapest.
- On the `AVPlayer` fallback, set `AVPlayerItem.audioTimePitchAlgorithm` the same way.
- Default: **spectral** for content with music, **timeDomain** if he prefers the sound or for battery. Add a hidden setting to A/B the two, because at 1.5× and above timeDomain can warble on music beds **[inferred]**.
- Speed range 0.5–3.0× in 0.05 steps. Presets 1.0, 1.25, 1.5, 1.75, 2.0. Default 1.0× until he sets one.

**Smart Speed (silence shortening) [design, inferred: Overcast hasn't published its algorithm]**
- A decode thread reads PCM in chunks ahead of the playhead (about 2 s lookahead).
- Compute RMS in 10 ms windows. Track the speech level (a rolling 90th-percentile RMS) and the noise floor.
- A window counts as silent when it's below `max(−45 dBFS, speechLevel − 25 dB)`.
- A silent run longer than **250 ms** is cut to **120 ms**: keep 60 ms at each edge and crossfade over 8 ms to avoid clicks. Never shorten a single gap by more than 2 s, so a deliberate pause doesn't vanish.
- Schedule the edited buffers on the player node. Keep a map from content time to output time so the scrubber, chapters and saved position stay in content time.
- Time saved, recorded per session: `smartRemovedContent` in seconds of content. Wall-clock saving from Smart Speed = `smartRemovedContent / rate`. Speed saving = `contentTime × (1 − 1/rate)`. These two add up to `contentTime − wallTime`. Show both, the way Overcast shows Smart Speed savings "beyond speed adjustments" **[verified that Overcast reports it that way]**.
- Default **on** globally. Turn it off per show for music-heavy shows.

**Voice Boost [design, inferred]**
- Chain: high-pass at about 80 Hz, a gentle presence lift (+3 dB around 3 kHz) via `AVAudioUnitEQ`, then Apple's dynamics processor (an `AVAudioUnitEffect` with `kAudioUnitSubType_DynamicsProcessor`) for compression with makeup gain and a limiter at −1 dBFS.
- Loudness normalisation: measure integrated loudness (ITU-R BS.1770) once at download time, store it, and apply a static gain towards **−16 LUFS** before the compressor. This evens out loud and quiet shows.
- Default **on**.

**Skip intervals**
- Defaults: back **15 s**, forward **30 s**, configurable from 5 to 60 s. The same values go to the lock screen and AirPods.
- Optional "skip intro" per show: start playback at N seconds.

**Chapters**
- Podcasting 2.0: `<podcast:chapters url type="application/json+chapters">` on `<item>` **[verified]**. JSON has `version` and `chapters[]`. Each chapter needs `startTime` (seconds) and can have `title`, `img`, `url`, `endTime`, and `toc:false` to hide it **[verified]**.
- ID3v2 `CHAP`/`CTOC` frames in MP3 files: read them with `AVAsset` metadata (`AVAsset.chapterMetadataGroups`) or parse the ID3 directly **[inferred]**. Same for MP4/M4A chapter tracks.
- Order of preference: the JSON, then embedded chapters.
- Chapter artwork replaces the episode art on Now Playing and the lock screen while that chapter plays.
- Chapter list: a sheet on Now Playing. Tap to jump. Swipe a chapter to "skip this chapter whenever it comes up" (an ad-skip habit).

**Transcripts**
- `<podcast:transcript url type language rel>`, which can appear several times. Types include VTT, SRT, JSON, HTML and plain text **[verified]**.
- Prefer JSON, then VTT, then SRT (they have timings), then HTML or text.
- v1: a scrolling transcript sheet that highlights the current line and seeks when you tap a line. Search within the transcript. Untimed formats show as static text.

**Sleep timer**
- Options: 5, 10, 15, 30, 45 and 60 min, end of episode, end of chapter, or custom.
- Fades out over the last 10 s (default on). Shake the phone within 30 s of it stopping to restart the same timer (default on).
- Shown as a countdown on Now Playing. "End of episode" doesn't advance the queue.

**Lock screen, Control Centre, AirPods**
- `MPNowPlayingInfoCenter` holds title, show, artwork (chapter art if there is any), elapsed time, duration, rate and chapter.
- `MPRemoteCommandCenter`: play, pause, toggle, `skipBackward` and `skipForward` (with `preferredIntervals` from settings), `changePlaybackPosition` (scrubbing), `changePlaybackRate`, and `nextTrack`/`previousTrack`.
- AirPods double-tap and triple-tap, and headphone buttons, send next/previous track. Default mapping is **skip forward / skip back**, with a setting to make them **next chapter / previous chapter** instead (configurable).
- Interruptions (calls, Siri): pause, then resume if `shouldResume`. When headphones are unplugged or the route changes to the speaker, pause.
- Auto-rewind on resume: 3 s after a pause over 5 min, 10 s after over 1 h (default on).
- AirPlay: an `AVRoutePickerView` button on Now Playing.

**Advancing**
- At the end of an episode: mark it played, archive it, and play the next item in Up Next (default on).
- "Played" threshold: within 30 s of the end, or 98%.

### 2.5 Per-podcast overrides

Every setting is **Use default** (inherits the global value) or an explicit value. The effective value is `podcast.override ?? global`, resolved at play time, so changing a global default updates every show still set to inherit. The settings screen shows inherited values in grey with "(default)".

| Setting | Global default |
|---|---|
| Playback speed | 1.0× |
| Smart Speed | On |
| Voice Boost | On |
| Time-pitch algorithm | Spectral |
| Skip intro (start at) | 0 s |
| Skip outro (stop N s early) | 0 s |
| Auto-add new episodes | Inbox |
| Priority | Off |
| Auto-download | On for Up Next items only |
| Keep latest N (Up Next and downloads) | All (decisions.md, 25 Oct 2026) |
| Notifications | Off (on for shows imported with `notifications="1"`) |
| Episode order on podcast page | Newest first |
| Auto-archive unplayed after | Never |
| Skip-chapter rules | None |

Speed changed on Now Playing applies to **this episode only** by default. A "Save for this show" button promotes it to the show's override, and long-pressing the speed control offers "Set as default for all".

### 2.6 Gestures

The ★ items are configurable. Leading swipe means left to right.

**Inbox**
- Tap row: open episode detail. Tap artwork: play now.
- Leading short swipe: **Queue last** ★. Leading long swipe: **Queue next** ★.
- Trailing short swipe: **Archive** ★. Trailing long swipe: **Mark played** ★.
- Long press: a menu with Play now, Queue next, Queue last, Download, Star, Mark played, Archive, Share, Go to show, Archive all older from this show. Includes a context preview showing the show notes.
- Pull to refresh. Multi-select through Edit for bulk queue or archive.

**Up Next**
- Drag the handle to reorder. On iPhone, long-press then drag anywhere on the row.
- Tap: play now (the current item moves down to position 2).
- Leading swipe: **Move to top**. Trailing short swipe: **Remove from queue**. Trailing long swipe: **Mark played** ★.
- Long press: Play now, Move to top, Move to bottom, Download or remove download, Star, Mark played, Share, Go to show.
- Top bar: sort once and Clear queue (with confirmation). No big title and no filter chips.
- Rows show each episode's real length ("1h 8m left", "1h 14m"), not sped up and with no speed or own-speed badge on them. The mini player and the queue sheet do the same. The end of the list says how long the whole queue takes at your speeds (decisions.md, 27 Oct 2026).

**Podcast page**
- Episode rows behave like the Inbox, minus Archive, plus "Mark all older as played" in the long-press menu.
- Header long press: Settings, Share feed, Copy feed URL, Mark all played, Unsubscribe.

**Library**
- Tap: podcast page. Long press: Settings, Play latest, Queue latest, Mark all played, Unsubscribe. Trailing swipe in list mode: Unsubscribe (with confirmation).

**Now Playing**
- Tap artwork: play or pause. Double-tap the left or right half of the artwork: skip back or forward ★.
- Swipe artwork left or right: next or previous chapter, or next queue item if there are no chapters ★.
- Swipe down: dismiss to the mini player.
- Scrubber: drag to seek. Dragging your finger further down while holding slows the scrub (finer control).
- Tap speed: cycle through presets. Long-press speed: slider sheet with per-show and default options.
- Long-press the skip buttons: choose the interval for this session.
- Long-press the sleep button: quick "end of episode".

**Mini player** (on every tab)
- Tap: expand. Swipe up: expand. Swipe left or right: skip forward or back ★. Long press: queue sheet.

**Mac and iPad:** the same actions as context menus and keyboard shortcuts: space to play or pause, ←/→ to skip, ⌘↑ to queue next, ⌫ to archive.

### 2.7 Downloads and storage

- Background `URLSession` downloads, Wi-Fi only by default (setting: allow cellular, or ask).
- Default rules:
  - Download the first **10** Up Next items automatically.
  - Priority shows: download new episodes as they arrive.
  - Other shows: no download until queued.
  - Per show: "Keep latest N" (All, or 1 to 50; default All). Like Overcast's episode limit, it covers Up Next as well as downloads (decisions.md, 25 Oct 2026):
    - **Up Next:** when a new episode of the show lands in Up Next, or the setting changes, the show's older unplayed episodes beyond its newest N come out of Up Next (the normal remove: not played, not archived). One that's been started or starred, and the first item (what's playing), always stay. Adding one by hand doesn't trim.
    - **Downloads:** files beyond the newest N that aren't in Up Next are deleted. All deletes nothing by this rule. A priority show downloads its newest N new episodes, or 3 when it's set to All.
- Streaming: allowed. Pressing play on a non-downloaded episode streams it and downloads at the same time (§2.4).
- Cleanup:
  - Delete the file **24 h after it's marked played** (setting: immediately, 24 h, 1 week, never).
  - Delete files for episodes removed from Up Next and not starred after 7 days.
  - Storage cap of **5 GB**. When over it, delete the oldest played files first, then the oldest unqueued unplayed ones. Never delete the top 3 in Up Next.
- Cache 600 px artwork separately, with an LRU limit of 200 MB.
- Downloads are local to each device and never synced.

### 2.8 New-episode detection and notifications

**The honest picture on iOS background refresh**
- `BGAppRefreshTask` runs when the system decides it should, and Apple calls the scheduling discretionary **[verified, Apple DTS on forums]**.
- Developers report about one run a day on a real device in some cases **[verified, forum report]**. Downcast says "several times an hour… Apple does not publish the heuristics" **[verified]**.
- Apple DTS recommends server-sent push for timely notifications **[verified]**.

**Recommendation: a server poller with push, plus on-device refresh as a backup.**
- The server (Convex, §2.12) polls each feed every **15 min**, using conditional GET (`ETag`/`If-Modified-Since`) and backing off for feeds that rarely update **[design]**.
- When a new item appears, it writes the episode to the database and sends an APNs alert ("Show: Episode title") if notifications are on for that show. It can also send a background push (`content-available`) to trigger the download, though iOS throttles these as well **[inferred]**.
- Sending APNs from Convex needs HTTP/2 and a JWT signed with a `.p8` key. I haven't checked that Convex's runtime does HTTP/2 to APNs. If it doesn't, use a small relay (a Cloudflare Worker) **[unverified risk]**.
- On device: refresh all feeds when the app comes to the foreground and on pull to refresh, and keep a `BGAppRefreshTask` as best effort.
- Parsing everywhere: RSS 2.0 with the iTunes and Podcasting 2.0 namespaces, plus Atom. Episode identity: GUID, then enclosure URL, then title + date.

### 2.9 Stats

**Raw data**: an append-only `ListeningSession` log.
- A session opens on play and closes on pause, stop, episode end, a rate change, a route change, or a jump over 30 s. It's also saved every 30 s so a crash loses very little.
- Fields: content start and end, wall-clock start and end, rate, Smart Speed on or off, `smartRemovedContent`, Voice Boost, output route (AirPods, speaker, car Bluetooth, AirPlay), device, and source (live or import) with an `isEstimated` flag.
- Also record lifecycle events: subscribed, unsubscribed, starred, completed, skipped (archived unplayed).

**Derived**
- Listening hours (wall clock) and content hours.
- Time saved, split into speed and Smart Speed (formulas in §2.4).
- Top shows (by wall time) and top episodes (by repeat listens and stars).
- Completion rate: completed ÷ started, with started meaning at least 5 min played.
- Streaks: consecutive local days with at least 10 min of listening.
- Time-of-day × weekday heatmap (live sessions only).
- Average speed, weighted by content time.
- Listening by route (AirPods vs car vs speaker).
- New shows added; longest single day; median and longest session; backlog size and age.
- Screens: This week, Month, Year, All time. Tap any show for its own stats.

**Year in review**
- Contents: total hours, time saved, episodes completed, top 5 shows with art, top episode, longest streak, biggest day, busiest month, a listening-personality line ("Night owl: 41% after 9 pm"), average speed, first and last episode of the year, and new shows discovered.
- It's a series of cards, swiped through like a story, plus one summary card.
- Rendering: lay out each card as a SwiftUI view at a fixed size and render it with `ImageRenderer` (scale 1, explicit frame): **1080×1920 (9:16)** and **1080×1080 (1:1)**. Pre-load artwork as images first, because `AsyncImage` won't load while rendering **[inferred]**.
- Sharing:
  - `ShareLink` with a `Transferable` PNG.
  - "Copy image", which puts the PNG on `UIPasteboard.general.image` (iOS) or `NSPasteboard` (macOS).
  - "Copy as text" for a plain summary.
- Private feeds are left out of share cards by default. If estimated data is included, a small footnote says so.
- Available from 1 December for the calendar year, then kept in a "Past years" archive.

### 2.10 Sync across iPhone, iPad and Mac

| | SwiftData + CloudKit | Plain CloudKit | Convex backend |
|---|---|---|---|
| Effort | Lowest, mostly automatic | High (hand-written record sync) | Medium-high (local store, outbox, subscriptions) |
| Conflicts | No control in practice; record-level last-writer-wins is my reading of how `NSPersistentCloudKitContainer` behaves **[inferred]** | Full control, via server change tags | Full control, written as TypeScript mutations |
| Schema limits | No `.unique`, every relationship optional, no `.deny` delete rule, schema additive only once it's in production **[verified]** | Additive schema | None to speak of |
| Offline | Built in | You build it | You build it (a local store plus an outbox). The Swift client docs don't mention offline support **[verified]** |
| Server feed polling and push | No | No (CloudKit can't poll RSS) | Yes: crons, actions, APNs |
| Cost | Free, needs the paid dev account | Free | Free/Starter tier, 1M function calls a month, crons included **[verified]** |
| Debugging | Opaque | OK | Excellent (dashboard, logs), and Mike already knows it |

**Recommendation: Convex, behind a local-first store.**
- Each device keeps a local SwiftData store (CloudKit off: `cloudKitDatabase: .none`) as the UI's source of truth. Writes go into an outbox and are pushed to Convex mutations. A Convex subscription per table brings remote changes back into the local store.
- One backend handles sync, feed polling and push. Notifications need a server anyway (§2.8), so CloudKit would mean running two systems.
- Conflict rules **[design]**:
  - **Playback position:** last-writer-wins on `positionUpdatedAt` (device clock, with server receive time as the tie-break). A device that's **currently playing** owns the position, and remote updates to that episode are ignored until it pauses. When another device opens the episode and the synced position is over 30 s from its local one, show "Resume from 34:12 (on iPhone)?".
  - **Played/starred/archived:** last-writer-wins per field, with timestamps.
  - **Up Next order:** fractional order keys (strings) per item, so a reorder on one device and an add on another both survive.
  - **Sessions and events:** append-only with client-generated UUIDs. Inserts are idempotent, so there are never conflicts.
  - **Settings:** last-writer-wins per field.
- Load: polling about 100 feeds every 15 min is roughly 290k action runs a month before backoff. That fits the 1M free calls, but it's worth watching **[inferred arithmetic]**.
- Auth: Convex Auth or Clerk, single user. Or, simplest of all, a long random device token checked in every function.

### 2.11 Distribution

- A free Apple account (Personal Team): installs from Xcode only, profiles **expire after 7 days**, up to **3 apps per device** **[verified]**. It also can't use the iCloud capability **[verified for iCloud; push assumed to be the same]**.
- **Paid Apple Developer Program needed** for TestFlight, a 1-year provisioning profile, push (APNs) and iCloud. It's US$99/yr from memory; one forum user reports paying A$149 **[unverified]**.
- Recommended: the paid account plus **TestFlight internal testing** for iPhone and iPad (installs over the air, builds last 90 days, which is reported but unverified). The Mac runs from Xcode with a Developer ID or development signing.
- Xcode Cloud or a `fastlane` lane to push a TestFlight build on every merge to `main` (later).

---

## 3. Data model sketch

Synced (Convex tables, mirrored in local SwiftData):

- **Podcast**: `id`, `feedURL`, `isPrivate`, `credentialRef` (Keychain key, never synced in plain text), `title`, `author`, `artworkURL`, `description`, `appleId?`, `importRefs {overcastId?}`, `subscribed`, `subscribedAt`, `lastFetchedAt`, `etag`, `lastModified`.
- **Episode**: `id`, `podcastId`, `guid`, `enclosureURL`, `enclosureType`, `enclosureLength`, `title`, `pubDate`, `duration?`, `showNotesHTML`, `chaptersURL?`, `transcripts[] {url,type,lang,rel}`, `artworkURL?`, `isGhost`.
- **EpisodeState** (user state, separate from feed data so feed refreshes never clobber it): `episodeId`, `position`, `positionUpdatedAt`, `positionDevice`, `played`, `playedAt`, `starredAt?`, `archived`, `inboxAt?`, `updatedAt`.
- **QueueItem**: `id`, `episodeId`, `orderKey` (fractional string), `addedAt`, `addedBy` (manual / priority / auto).
- **PodcastSettings**: `podcastId` plus nullable override fields (§2.5). `null` means inherit.
- **GlobalSettings**: one row with all the defaults.
- **ListeningSession**: `id` (UUID), `episodeId`, `podcastId`, `deviceId`, `startedAt`, `endedAt`, `contentStart`, `contentEnd`, `rate`, `smartSpeed`, `smartRemovedContent`, `voiceBoost`, `route`, `source` (live / overcastImport), `isEstimated`.
- **LibraryEvent**: `id`, `type` (subscribed / unsubscribed / starred / completed / skipped), `podcastId?`, `episodeId?`, `at`.
- **Device**: `id`, `name`, `platform`, `apnsToken`, `lastSeenAt`.
- **ImportBatch**: `id`, `source`, `importedAt`, `assumedSpeed`, `counts`.

Local only:
- **Download**: `episodeId`, `localPath`, `bytes`, `state`, `completedAt`, `loudnessLUFS`.
- **ChapterCache**: `episodeId`, `source` (json / id3 / mp4), `chapters[] {start,end?,title,img?,url?,toc}`.
- **TranscriptCache**, **ArtworkCache**, **Outbox** (pending mutations).

---

## 4. Open questions for Mike

1. **Convex as the backend from v1** (sync, feed polling, push), with a local store on each device? *Recommended: yes.*
2. **Can private feed URLs and credentials live on the Convex server** so it can poll them and notify? *Recommended: yes for token URLs (including your AI feed), stored as Convex env/secret rows; Basic-auth feeds stay device-only.*
3. **What speed did you usually listen at in Overcast?** It turns imported history into estimated listening hours. *Recommended: ask once at import; prefill 1.0×.*
4. **Inbox plus Up Next, or should new episodes go straight into Up Next** the way Overcast's "All episodes" playlist works? *Recommended: Inbox plus Up Next, with Priority shows going straight into the queue.*
5. **Is it OK if Smart Speed and Voice Boost only kick in once the file has downloaded?** Streaming before then gets speed only. *Recommended: yes, and Up Next auto-downloads so it rarely comes up.*
6. **What should AirPods double-tap and triple-tap do: skip ±30/15 s, or next/previous chapter?** *Recommended: skip, with chapters as a setting.*
7. **Default skip intervals: back 15 s, forward 30 s?** *Recommended: yes.*
8. **Latest OS only** (newest iOS/macOS SwiftData, no back-compat)? *Recommended: yes, it's a personal app.*
9. **Mac: a native SwiftUI macOS target** rather than Catalyst? *Recommended: native multiplatform target.*
10. **Should year-in-review totals include estimated imported history?** *Recommended: yes, with a footnote; the time-of-day heatmap uses only real sessions.*

---

## 5. Sources

**Overcast export**
- overcast-to-sqlite (schema, played rule, retention): https://github.com/hbmartin/overcast-to-sqlite
- Parser, URLs and selectors: https://raw.githubusercontent.com/hbmartin/overcast-to-sqlite/main/overcast_to_sqlite/overcast.py
- Fixture with attribute names and formats: https://raw.githubusercontent.com/hbmartin/overcast-to-sqlite/main/tests/test_opml.py
- Datastore queries: https://raw.githubusercontent.com/hbmartin/overcast-to-sqlite/main/overcast_to_sqlite/datastore.py
- Extended export URL and episode attributes: https://gist.github.com/cleverdevil/a8215850420493c1ee06364161e281c0
- Plain OPML sample: https://metacast.app/blog/podcasting/opml-import-export

**Apple Podcasts export**
- https://kaspars.net/blog/apple-podcasts-subscriptions/md
- https://talk.macpowerusers.com/t/export-iphone-podcast-subscription-list/22795
- https://leancrew.com/all-this/2025/11/casting-about-again/

**Directory**
- iTunes Search API: https://performance-partners.apple.com/search-api
- Lookup 200-episode cap and `feedUrl` (third party): https://apify.com/darknezz/apple-podcasts-scraper.md

**Playback**
- `AVAudioTimePitchAlgorithm`: https://developer.apple.com/documentation/avfoundation/avaudiotimepitchalgorithm
- `AVAudioUnitTimePitch`: https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch
- Smart Speed behaviour and "time saved": https://tidbits.com/2014/07/16/overcast-refines-the-iphone-podcast-experience/
- How Smart Speed differs from silence skipping: https://james.cridland.net/blog/2024/why-overcast-is-more-than-a-podcast-player/
- `podcast:chapters`: https://podcasting2.org/docs/podcast-namespace/tags/chapters
- JSON chapters format: https://podcasting2.org/docs/podcast-namespace/examples/chapters/jsonChapters
- `podcast:transcript`: https://podcasting2.org/docs/podcast-namespace/tags/transcript

**Background refresh**
- https://developer.apple.com/forums/thread/729824
- https://developer.apple.com/forums/thread/772426
- https://developer.apple.com/forums/thread/125912
- https://support.downcast.fm/article/Wg9EDqYz3M-background-refresh

**Sync**
- SwiftData + CloudKit: https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
- Convex Swift client: https://github.com/get-convex/convex-swift
- Convex limits: https://docs.convex.dev/production/state/limits

**Distribution**
- Memberships: https://developer.apple.com/support/compare-memberships/
- Free profile expiry: https://developer.apple.com/forums/thread/92538
- A$149 price (forum user): https://developer.apple.com/forums/thread/711146

**What's verified and what isn't**
- **Verified against a source:** the Overcast attribute names, element types, date formats and export URL (from third-party code, not Overcast docs); iTunes API parameters and rate limit; time-pitch algorithm descriptions; Podcasting 2.0 chapter and transcript syntax; SwiftData CloudKit limits; free-account limits; Convex free-tier calls and crons; how unreliable background refresh is.
- **Inferred, not verified:** the exact OPML document shape (`<head>`, nesting under `text="feeds"` is from parser selectors); that the export has no duration; the meaning of `userUpdatedDate`; all of the Smart Speed and Voice Boost algorithm design; whether `ImageRenderer` loads `AsyncImage`; whether Convex can do HTTP/2 to APNs; CloudKit's last-writer-wins conflict behaviour; the Developer Program price and the TestFlight 90-day expiry; the Podcast Index details (its docs page wouldn't render).
