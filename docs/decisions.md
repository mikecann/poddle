# Decisions

Mike's calls so far (21 Oct 2026). `product-spec.md` is the detailed behaviour spec. Where they disagree, this file wins.

## Product

- **Name:** Poddle. Bundle ID `com.mikecann.poddle`. Apple team `4DTAZSZL6B` (paid account).
- **Look:** direction C, "Earful", warm and tactile: `designs/c-earful-warm.html`. Swap the name Earful for Poddle everywhere. Directions A and B are only kept for reference.
- **Platforms:** native SwiftUI. iPhone first, iPad and Mac to follow from the same multiplatform target. Minimum **iOS 18.0** (Mike's phone is an iPhone XS Max on iOS 18.7, which can't run iOS 26 or later) and **macOS 26.0**. Newer APIs go behind `if #available`. His iPad is on iPadOS 26.6. No Watch or CarPlay for now.
- **Import:** Overcast "All data" OPML, with history. Apple Podcasts only by searching the directory.
  - Assumed speed for imported history: **2.0×** (Mike's usual Overcast speed).
  - A show is subscribed only if it has `subscribed="1"`. A missing attribute means unsubscribed.
  - Overcast has no Inbox. Its main smart playlist ("All Episodes") is effectively the queue. So on import, unplayed episodes that aren't deleted go into **Up Next**, ordered the way that playlist sorts them: `priorityPodcastIds` shows first, then by its `sorting`, with `sortedEpisodeIds` and manual playlists' `includeEpisodeIds` placed first. Everything else is archived.
  - Shows in `priorityPodcastIds` get the new-episode rule `Up Next top`. Every other show gets `Inbox`.

## Behaviour

- **Queue:** an Inbox plus a single ordered Up Next queue. There are no Overcast-style playlists in v1.
- **New episodes, per show:** `Inbox` (default), `Up Next top`, `Up Next bottom` or `Don't add`. Shows set to an Up Next option are the "priority" shows.
- **Tabs:** Up Next, Inbox, Library, Discover, Stats. Global settings and the Overcast import sit behind a gear on Library.
- **Speed edits:** the speed sheet's scope switch defaults to "Just this show" if the show already has its own speed, otherwise "All podcasts". A change applies to whichever scope is selected. There is no per-episode speed.
- **Per-show settings:** each one is either "Use default" (inherits the global value live) or an explicit value. The full list is in spec §2.5.
- **Speed-up method:** the default is PoddlePlayback's `timeDomain` stretcher. Mike preferred files 3 and 5 in the 21 Oct listening test, though only slightly. Settings > Playback has a "Speed-up method" choice ("Speech-tuned" = timeDomain, "Apple spectral" = spectral) so he can A/B on the phone with headphones. It also appears as a per-show override.
- **Defaults:** skip back 15 s and forward 30 s; Smart Speed and Voice Boost on; AirPods next/previous = skip forward/back; auto-rewind on resume.
- **Downloads over mobile data** (Mike, 21 Oct):
  - The global setting is "Download on: Wi-Fi only" (default) or "Wi-Fi and mobile data".
  - In Wi-Fi-only mode you can temporarily allow mobile downloads: "Allow mobile downloads for 1 hour" (also 3 hours, or until tomorrow). It's one tap from the Downloads settings, from the download queue, and from the prompt below.
  - While it's active, a small banner or chip shows the time left and has a "Stop" button. When it expires, unfinished downloads pause until Wi-Fi.
  - Tapping download on a single episode over mobile data in Wi-Fi-only mode asks: "Download now on mobile", "Allow mobile for 1 hour", or "Wait for Wi-Fi".
  - Streaming playback over mobile data is always allowed. This setting only covers downloads.
  - It's a device-local setting, not synced, so the iPad and Mac don't care.

## Tech

- **Backend: Convex,** on Mike's Personal team (`mikec`) in Sydney. It's the source of truth for the library, episodes, user state, queue, settings and listening sessions. It does all feed fetching and parsing, polling, the Overcast import, stats and year-in-review maths, and APNs push.
- **App:** a thin client over Convex (the `convex-swift` client), with a local cache and a mutation outbox so it works offline. It also handles playback, downloads and rendering.
- **Auth:** single user. A long random API token is set in the Convex env (`PODDLE_API_TOKEN`), stored in the app's Keychain, and checked by every public function.
- **Distribution:** Xcode installs to start with, then TestFlight.
