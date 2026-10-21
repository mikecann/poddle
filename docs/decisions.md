# Decisions

Mike's calls so far (21 Oct 2026). `product-spec.md` is the detailed behaviour spec. Where they disagree, this file wins.

## Product

- **Name:** Poddle. Bundle ID `com.mikecann.poddle`. Apple team `4DTAZSZL6B` (paid account).
- **Look:** direction C, "Earful", warm and tactile: `designs/c-earful-warm.html`. Swap the name Earful for Poddle everywhere. Directions A and B are only kept for reference.
- **Platforms:** native SwiftUI. iPhone first, iPad and Mac to follow from the same multiplatform target. Latest OS only (iOS 27, macOS 27). No Watch or CarPlay for now.
- **Import:** Overcast "All data" OPML, with history. Apple Podcasts only by searching the directory.

## Behaviour

- **Queue:** an Inbox plus a single ordered Up Next queue. There are no Overcast-style playlists in v1.
- **New episodes, per show:** `Inbox` (default), `Up Next top`, `Up Next bottom` or `Don't add`. Shows set to an Up Next option are the "priority" shows.
- **Tabs:** Up Next, Inbox, Library, Discover, Stats. Global settings and the Overcast import sit behind a gear on Library.
- **Speed edits:** the speed sheet's scope switch defaults to "Just this show" if the show already has its own speed, otherwise "All podcasts". A change applies to whichever scope is selected. There is no per-episode speed.
- **Per-show settings:** each one is either "Use default" (inherits the global value live) or an explicit value. The full list is in spec §2.5.
- **Defaults:** skip back 15 s and forward 30 s; Smart Speed and Voice Boost on; AirPods next/previous = skip forward/back; auto-rewind on resume.

## Tech

- **Backend: Convex,** on Mike's Personal team (`mikec`) in Sydney. It's the source of truth for the library, episodes, user state, queue, settings and listening sessions. It does all feed fetching and parsing, polling, the Overcast import, stats and year-in-review maths, and APNs push.
- **App:** a thin client over Convex (the `convex-swift` client), with a local cache and a mutation outbox so it works offline. It also handles playback, downloads and rendering.
- **Auth:** single user. A long random API token is set in the Convex env (`PODDLE_API_TOKEN`), stored in the app's Keychain, and checked by every public function.
- **Distribution:** Xcode installs to start with, then TestFlight.
