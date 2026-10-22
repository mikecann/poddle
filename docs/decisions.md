# Decisions

Mike's calls so far (21 Oct 2026). `product-spec.md` is the detailed behaviour spec. Where they disagree, this file wins.

## Product

- **Name:** Poddle. Bundle ID `com.mikecann.poddle`. Apple team `4DTAZSZL6B` (paid account).
- **Brand (22 Oct):** Poddle sounds like "poodle", so the brand is a cute, fluffy cartoon poodle. Mike chose **A, "Headphones Poodle"** (`designs/branding/round1/concept-a.jpg`): a round cream poodle with cloud curls, a thick deep-ink outline, closed happy eyes, blush cheeks and tomato-red headphones. Flat sticker style, a tomato-to-orange gradient icon and a chunky rounded wordmark. The other four directions are kept beside it for reference. Final assets live in `designs/branding/final/`.
- **Look, v2 (Mike, 22 Oct): "Cloud Fluff" plus the companion.** This replaces the radio-style "Earful" look. The mock is `designs/explore-poodle/fluff.jpg`.
  - **Feel:** soft and pillowy, from the poodle's cloud curls. Cards and the mini player have gently scalloped curl edges, buttons are puffy with soft shadows, and the progress bar is a line of curls that fills in as you listen. Now Playing has a blush background.
  - **Colour and type:** warm cream, apricot and blush, with tomato red as the one strong accent. Rounded type.
  - **The companion:** a small animated Poddle (the mascot) follows you round the app doing different things. Mike liked the poodle peeking over the mini player in `designs/explore-poodle/sticker.jpg`. The animation is light (bobbing, swaying, reactions), respects Reduce Motion, and can be turned off in Profile.
- **Look, v1 (superseded):** direction C, "Earful", warm and tactile: `designs/c-earful-warm.html`. Swap the name Earful for Poddle everywhere. Directions A and B are only kept for reference.
- **Platforms:** native SwiftUI. iPhone first, iPad and Mac to follow from the same multiplatform target. Minimum **iOS 18.0** (Mike's phone is an iPhone XS Max on iOS 18.7, which can't run iOS 26 or later) and **macOS 26.0**. Newer APIs go behind `if #available`. His iPad is on iPadOS 26.6. No Watch or CarPlay for now.
- **Import:** Overcast "All data" OPML, with history. Apple Podcasts only by searching the directory.
  - Assumed speed for imported history: **2.0×** (Mike's usual Overcast speed).
  - A show is subscribed only if it has `subscribed="1"`. A missing attribute means unsubscribed.
  - Overcast has no Inbox. Its main smart playlist ("All Episodes") is effectively the queue. So on import, unplayed episodes that aren't deleted go into **Up Next**, ordered the way that playlist sorts them: `priorityPodcastIds` shows first, then by its `sorting`, with `sortedEpisodeIds` and manual playlists' `includeEpisodeIds` placed first. Everything else is archived.
  - Shows in `priorityPodcastIds` get the new-episode rule `Up Next top`. Every other show gets `Inbox`.

## Behaviour

- **Queue:** a single ordered Up Next queue. There's no Inbox (Mike dropped it on 22 Oct: "what's the point in having an inbox anyway?"), and no Overcast-style playlists in v1.
- **New episodes, per show:** `Up Next bottom` (default), `Up Next top` or `Don't add`. Shows set to `Up Next top` are the "priority" shows. Episodes sitting in the old Inbox move to the bottom of Up Next, oldest first.
- **Tabs:** Up Next, Library, Discover, Stats, Profile (22 Oct). Profile holds the account (name, email, sign out) and then the global settings and Overcast import, which used to sit behind a gear on Library.
- **Now Playing has three pages,** like Overcast. Swipe between them; page dots show where you are.
  - **Left page (swipe right):** show notes and chapters.
  - **Middle:** artwork and transport. The artwork has **no destructive gestures**: dragging it never archives, deletes or skips an episode.
  - **Right page (swipe left):** that episode's playback settings: speed, Smart Speed, Voice Boost, speed-up method, skip intro and outro. At the top is a **"Customize for <show>"** toggle:
    - Off: edits change the global defaults, and the page says so.
    - On: the show gets its own values, starting from the current ones, and edits change only that show.
    - Turning it off again returns the show to the defaults.
  - Settings are never per-episode.
- **Undo:** every destructive or hard-to-find action shows a toast at the bottom with **Undo** for about 5 seconds, then it's final. That covers archive, remove from Up Next, mark played, delete download, unsubscribe and clearing things.
- **Speed edits:** they follow the Now Playing settings page's "Customize for <show>" toggle. There is no per-episode speed.
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

## Accounts, website and Chef (Mike, 22 Oct)

- **Accounts:** just Mike for now, but built so other people can sign up later, each with their own library, queue, stats and settings. Every per-person table gets an owner. Shared feed data (shows, episodes) stays shared. Sign-up is limited to an allowlist of emails (only Mike's) until he opens it up.
- **Sign-in:** Convex Auth v2 with Apple and Google, on the website and in the iPhone app, the same way Walkies does it (`~/dev/me/walkies`: `convex/convex.config.ts`, `convex/auth.ts`, `convex/users.ts`, the README's "Setting up Apple and Google sign-in"). Apple and Google with the same email are one account. The app's hidden API token goes away once the app signs in. Scripts and tests may keep an admin path.
- **Website:** `poddle.mikecann.app` (DNS on Cloudflare), on Convex static hosting (`@convex-dev/static-hosting`) on the prod deployment, through its HTTP-actions custom domain.
  - Public share pages for an episode or a show, with no sign-in. They play the episode in the browser and open the app when it's installed (universal links).
  - Signed-in pages for your shows and what you're listening to.
  - The app's share sheet hands out these links.
- **Chef 2.0:** the feedback board, plus cloud builds, as in Walkies (`npx chef init --cloud`, ChefKit opened from Settings rather than a floating button). Chef's cloud builds run on Convex's own marketplace (Daytona, Code Storage, Resend, the AI gateway), billed to the Convex team, so they need no keys of Mike's.
- **Data:**
  - Prod `coordinated-dodo-120` is in Sydney, with daily backups at 06:01 (Perth time) since 22 Oct.
  - Dev moved to Sydney as `striped-turtle-260` on 22 Oct, seeded from a prod snapshot. The old US dev `qualified-hedgehog-912` is unused.

## Tech

- **Backend: Convex,** on Mike's Personal team (`mikec`) in Sydney. It's the source of truth for the library, episodes, user state, queue, settings and listening sessions. It does all feed fetching and parsing, polling, the Overcast import, stats and year-in-review maths, and APNs push.
- **App:** a thin client over Convex (the `convex-swift` client), with a local cache and a mutation outbox so it works offline. It also handles playback, downloads and rendering.
- **Auth:** Convex Auth v2 (Apple and Google), with sign-up limited to `PODDLE_ALLOWED_EMAILS`. Every public function acts as the signed-in person. `PODDLE_API_TOKEN` survives only as the admin token scripts use to act as a named user (`admin: { token, email }`). Callbacks stay on each deployment's own `convex.site` address: `CONVEX_SITE_URL` isn't overridden for the custom domain.
- **Distribution:** Xcode installs to start with, then TestFlight.
