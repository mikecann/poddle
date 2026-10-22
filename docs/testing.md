# Testing

How Poddle is tested, and how the end-to-end suites' isolated world works. `AGENTS.md` has the rules (which layer, when to run what) and the cheatsheet.

## The layers

| Layer | Where | Runs with |
| --- | --- | --- |
| Backend domain logic | `tests/*.test.ts` (`convex-test` + Vitest) | `npm test` |
| Website logic | `web/src/lib/*.test.ts` (Vitest) | `npm test` |
| App logic | `Packages/PoddleKit/Tests`, `Packages/PoddlePlayback/Tests` (Swift Testing) | `swift test` in each package |
| App journeys | `features/app/*.feature` + `PoddleUITests/` (XCUITest) | `npm run test:e2e:ios` |
| Website journeys | `features/web/*.feature` + `e2e/web/` (playwright-bdd) | `npm run test:e2e:web` |
| BDD pairing and drift | `scripts/verify-bdd-pairing.mjs`, `scripts/bdd-drift.mjs` | `npm run check` |

## Features and steps

Feature files are Gherkin in plain user language. Each one is owned by exactly one step module, paired by name:

- `features/app/<name>.feature` ↔ `PoddleUITests/Steps/<name>.steps.swift`
- `features/web/<name>.feature` ↔ `e2e/web/steps/<name>.steps.ts`

Step files starting with `_` hold shared steps and own no feature. Steps are global within a harness, so any feature can use a shared step. Both harnesses write steps as Cucumber expressions (`{string}`, `{int}`, `{float}`, `{word}`).

`npm run check` runs two cheap checks with no browser or simulator:

- **Pairing** (`scripts/verify-bdd-pairing.mjs`): no feature without a step module, no step module without a feature.
- **Drift** (`scripts/bdd-drift.mjs`): every app step matches exactly one Swift step definition (read from the Swift sources with the runner's own matching rules; unused definitions are warnings), and `bddgen` generates the web specs, which fails on any web step without a definition.

### The app's Gherkin runner

`PoddleUITests/Gherkin/` is a small in-repo runner rather than a package: the Swift Cucumber ports are unmaintained or not Swift 6 ready, and the subset needed is small.

- `Gherkin.swift` parses `Feature`, descriptions, `Background`, `Scenario`/`Example`, `Scenario Outline` with `Examples`, `@tags` and comments. Data tables under steps, doc strings and `Rule` are errors, so a step is never silently dropped.
- `Steps.swift` holds the registry. Every `StepModule` subclass in the test bundle registers its steps at startup (found through the Objective-C runtime, so a new step file needs nothing else). A step that matches nothing, or more than one definition, fails the scenario with the reason.
- `FeatureTests.swift` turns every scenario into its own XCTest case, `test_<feature>__<scenario>`, so results and the xcresult are per scenario. Each step is an XCTest activity. On failure it attaches a screenshot and the accessibility tree, and also writes both to `e2e/.runtime/ios-failures/`.
- The feature files are read from the checkout at run time (the simulator can read the Mac's disk), so editing a `.feature` needs no rebuild; editing steps does.

## The isolated world

Neither suite touches the internet, dev or prod. `e2e/world/world.mjs` starts:

- **A throwaway local Convex backend.** `convex/` and `package.json` are copied to a temp folder (`node_modules` is linked) and `npx convex dev` runs there in anonymous local mode on ports 3410/3411, so the checkout's `.env.local` is never read or written and everything goes when the temp folder does. Its environment: fresh Convex Auth keys, placeholder Apple and Google settings, `PODDLE_TEST_SIGNIN=1`, `PODDLE_ALLOWED_EMAILS=listener@poddle.test,friend@poddle.test`, a random `PODDLE_API_TOKEN`, `PODDLE_E2E=1` and `PODDLE_DIRECTORY_URL` pointing at the fixture server. No APNs settings, so push is a logged no-op. The crons run but only ever see fixture feeds.
- **The fixture server** (`e2e/world/fixtureServer.mjs`, port 3412): RSS feeds for five shows (`e2e/world/shows.mjs`: a normal one, a "priority" one, one with chapters and timestamped show notes, another normal one for the speed scenarios, and a private feed with a token in its URL), their audio (short quiet MP3 tones in `e2e/fixtures/audio`, made by `make.sh`, with Range support for streaming), artwork, chapters, and a fake Apple Podcasts directory that `directory:search` and `directory:lookup` hit.
- **The website** (web suite only): built with `VITE_CONVEX_URL` pointing at the local backend and the test sign-in form, and uploaded to its static hosting, so `/e/<id>` and `/s/<id>` go through the real HTTP actions and link-preview tags.

It writes its addresses to `e2e/.runtime/world.json`, which both harnesses read. `npm run e2e:world` starts one on its own to poke at.

### Test-only backend hooks

`convex/testing.ts` has what no public function does: `testing:reset` (empty every app table and cancel scheduled jobs) and `testing:refreshFeed` (fetch one feed now, so a new episode arrives without the 15-minute poll). They need `PODDLE_E2E=1`, a deployment whose own URLs are `127.0.0.1`/`localhost`, and the admin token (`convex/lib/e2e.ts`), so they do nothing on dev or prod even if the flag were set there. The same check guards `PODDLE_DIRECTORY_URL`.

### The world API

Both harnesses arrange and inspect the backend through `POST <fixtures>/_world/<op>` (`e2e/world/worldApi.mjs`): `reset`, `signUp`, `follow` (with exactly the Up Next you ask for), `queue`, `publish` (a new episode in a fixture feed, fetched straight away), `setNewEpisodes`, `setGlobal`, `setPosition`, `overcastExport`, and lookups (`episode`, `podcast`, `upNext`, `library`, `pastShows`, `catalog`, `stats`, `user`). It acts through the public functions with the admin path, the way the scripts do. Shows and episodes are named by their fixture titles.

### Each scenario starts clean

- Every scenario calls `reset` first: the fixture feeds go back to `shows.mjs` and every app table is emptied.
- The app is launched as a fresh install on the local backend (Debug-only launch arguments, README "Launch arguments"): `-PoddleConvexURL`/`-PoddleSiteURL` point it at the world, `-PoddleResetState YES` wipes its session, caches, outbox, downloads and preferences, and `-PoddleTestSignIn <email>` signs straight in. `-showPoddle NO` keeps the companion still (his idle animation stops XCTest seeing the app as idle), and `-PoddleUndoSeconds 12` gives Undo toasts 12 seconds instead of 5 so a slow run still reaches Undo. Share links use `-PoddleOpenURL`, the import uses `-PoddleImportFile` in place of the system file picker.
- The web suite gets a fresh browser context per scenario.

## Running

- `npm run test:e2e:web`: starts a world (with the website), runs `bddgen` and Playwright. `-- -g "name"` for one scenario. Failures leave a trace, screenshot and the HTML report in `e2e/.runtime/`.
- `npm run test:e2e:ios`: makes (once) and boots its own simulator, "Poddle E2E" (an iPhone 17 Pro on the newest iOS runtime that has one; iOS 27.1 only offers the "iPhone Duo", so today that's iOS 27.0), builds the app and the UI tests once into their own DerivedData folder, starts a world, runs, then shuts that simulator down. Other simulators are left alone. `--feature <name>`, `-g "part of a scenario name"`, `--no-build`, `--keep-sim`. Logs are `e2e/.runtime/xcodebuild-*.log`, the result bundle `e2e/.runtime/ios.xcresult`.
- `npm run test:e2e`: both suites on one world.

The ports are 3410 (backend), 3411 (site) and 3412 (fixtures); set `E2E_CONVEX_PORT`, `E2E_SITE_PORT` and `E2E_FIXTURE_PORT` to move them. Only one run at a time per set of ports.

## Writing scenarios

- Describe what the person does and sees. Arrange the world with `Given` steps through the world API; drive the app or page with `When`; check the screen, and where it matters the server too, with `Then`.
- Find things in the app by accessibility identifier. Rows carry `upNext.row.<episode id>`; steps look ids up by title through the world API (`World.episodeId`).
- Wait with `World.eventually`/`waitFor`, never fixed sleeps, except where the behaviour is about time passing (a paused position staying put).
- A bug a scenario finds gets fixed in the same change, with the scenario kept as its regression test, plus a unit test at the lowest layer that can see it.

## Regressions these suites caught

- **Website `/me` went blank** when the tab's session stopped matching a live account (deleted in another tab, or its data reset): `queue:upNext` threw `unauthenticated` into React and nothing caught it. `/me` now signs the tab out and shows the sign-in form (`web/src/components/SessionBoundary.tsx`). Scenario: "A tab left open after the session ends asks you to sign in again"; unit test `web/src/lib/sessionErrors.test.ts`.
- **Stats stuck on "Counting up your listening…" after signing in:** signing in cleared the store's stats, but the Stats tab's loader had already started and never ran again. Screens now reload on `PoddleStore.accountGeneration`. Scenario: `features/app/stats.feature`; unit test in `StoreTests.swift`.
- **Imported past shows never appeared** under Library > Past shows: the app only counted unsubscribed shows whose history it had locally, and it never syncs those shows' episodes. It now also trusts the server's `podcasts:pastShows`. Scenario: `features/app/import.feature`; unit test in `StoreTests.swift`.
- **"Play from 0:40" on a shared link left you on the episode sheet:** it started playing, but Now Playing is a full-screen cover, which can't come up over a sheet. The sheet now closes first (`AppModel.openNowPlaying`). Scenario: "A link with a start time offers to play from there".
- **The episode page ran list items together** in show notes ("…middle bit0:40 The finale"). Same scenario.
- **Discover's Paste could leave you stuck:** with a link on the clipboard, "Type" becomes "Paste"; if the clipboard can't be read (someone taps "Don't Allow"), Paste did nothing and there was no way to enter a link. It now opens the URL field instead. Scenario: "Add a show by pasting its feed URL".
- **A fresh sign-in auto-downloaded for someone who'd turned auto-download off:** Up Next arrived before their settings, and download housekeeping ran on the defaults. It now waits for their settings (`PoddleStore.settingsReady`). Scenario: "Download an episode" (it starts by checking nothing was downloaded); unit test in `LiveStoreTests.swift`.
- **A share link opened as the app started said the episode wasn't available:** fetching it mid sign-in (no session yet, or the account switching) failed, and any failure read as "not found, maybe private". `LiveStore.loadShared` now retries until the server actually answers. Caught by "A link with a start time offers to play from there" on a slow run; unit test in `LiveStoreTests.swift`.
- **"< Library" didn't go back** from a show's page on iOS 27 (nor did swiping from the edge): `BackButton`'s `dismiss()` ran and nothing happened. It now pops the tab's path in `AppModel`. Scenario: "Back from a show's page returns to the Library". Seen on the iOS 27.0 simulator; not checked on iOS 18.
- **Discover's Follow buttons had no identifier of their own** (the result card's swallowed it). Scenario: "Search Discover and follow a show".
