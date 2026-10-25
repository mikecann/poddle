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

Both harnesses arrange and inspect the backend through `POST <fixtures>/_world/<op>` (`e2e/world/worldApi.mjs`): `reset`, `signUp`, `follow` (with exactly the Up Next you ask for), `queue`, `publish` (a new episode in a fixture feed, fetched straight away), `setNewEpisodes`, `setShowSettings` (any of a show's own settings), `setGlobal`, `setPosition`, `overcastExport`, and lookups (`episode`, `podcast`, `upNext`, `library`, `pastShows`, `catalog`, `stats`, `user`). It acts through the public functions with the admin path, the way the scripts do. Shows and episodes are named by their fixture titles.

### Each scenario starts clean

- Every scenario calls `reset` first: the fixture feeds go back to `shows.mjs` and every app table is emptied.
- The app is launched as a fresh install on the local backend (Debug-only launch arguments, README "Launch arguments"): `-PoddleConvexURL`/`-PoddleSiteURL` point it at the world, `-PoddleResetState YES` wipes its session, caches, outbox, downloads and preferences, and `-PoddleTestSignIn <email>` signs straight in. `-showPoddle NO` keeps the companion still (his idle animation stops XCTest seeing the app as idle), and `-PoddleUndoSeconds 12` gives Undo toasts 12 seconds instead of 5 so a slow run still reaches Undo. Share links use `-PoddleOpenURL`, the import uses `-PoddleImportFile` in place of the system file picker.
- The web suite gets a fresh browser context per scenario.

## Running

Full runs go to **tinker-desk**, Mike's spare Mac, over SSH (`E2E_REMOTE_HOST` or `--host` points them at another Mac). Use local runs only for the scenarios you touched. `npm run check` remains the cheap check on every change.

```sh
npm run test:e2e:remote                           # both suites, one isolated world
npm run test:e2e:remote -- --dry-run              # plan only, no SSH or test run
npm run test:e2e:remote -- --suite web
npm run test:e2e:remote -- --suite ios -g "Download an episode"
npm run test:e2e:remote -- --suite ios --feature up-next
npm run test:e2e:remote -- --commit <pushed-sha> --suite web -g "Sign in"
```

The runner fetches `origin` and refuses a commit that is not reachable from a pushed branch. It tests the commit, not your uncommitted files. Push the commit first. It uses SSH (no GitHub CLI login), fetches on tinker-desk, checks out the commit in its own worktree under `~/.local/share/poddle-e2e/worktree`, runs `npm ci`, verifies and syncs the Swift package cache, installs Playwright Chromium in its own browser cache when needed, and runs the selected suite. The main checkout at `~/dev/me/poddle` is left alone. Arguments after `--suite` are passed to that suite; a `-g` filter on the default combined run reaches both harnesses. Use `--suite ios` for `--feature` and iOS-only flags.

The whole remote run holds `~/.blender-queue.lock` with `lockf`, the same lock render-box (another job on tinker-desk) uses. It refuses immediately if another render or e2e run owns it. The OS releases the lock when the process exits; do not delete the lock file. `caffeinate -i` keeps the Mac awake during the run.

Results return to `e2e/.remote-results/<sha>/`: `latest.json` contains pass/fail per scenario and setup failures, alongside the xcresult, Xcode logs, web JSON/HTML report and traces, failure screenshots and iOS accessibility dumps. A failing run exits nonzero. Disposable backend configuration and `world.json` are never downloaded or published. Remote copies remain under `~/.local/share/poddle-e2e/results/<sha>/<run-id>/`; these can be removed after inspecting/downloading them. One reusable worktree and package cache avoid growing a checkout and DerivedData per commit.

Local commands for focused checks:

- `npm run test:e2e:web -- -g "name"`: starts a world with the website, runs `bddgen` and Playwright. Failures leave a trace, screenshot and HTML report in `e2e/.runtime/`.
- `npm run test:e2e:ios -- -g "name"`: creates and boots its own simulator, builds the app and UI tests, starts a world, runs, then shuts that simulator down. Other simulators are left alone. Also accepts `--feature <name>`, `--no-build`, `--keep-sim`. Logs are `e2e/.runtime/xcodebuild-*.log`, the result bundle `e2e/.runtime/ios.xcresult`.
- `npm run test:e2e`: both suites on one world. Prefer the remote command for this full run.

The iOS runner accepts `E2E_SIM_RUNTIME` (version such as `18.1` or full runtime identifier), `E2E_SIM_DEVICE_TYPE` (CoreSimulator device-type identifier), `E2E_SIM_NAME` (default `Poddle E2E`), and `E2E_SOURCE_PACKAGES` (resolved SPM cache, built with `-disableAutomaticPackageResolution`). Locally the default remains the newest available runtime supporting an iPhone 17 Pro. Remotely the defaults are **iOS 27.0 / iPhone 17 Pro**. On iOS 18.1, Xcode 27.1's UI-test tooling crashes the app under heavy query logging, so iOS 18 runs are opt-in until [#6](https://github.com/mikecann/poddle/issues/6) is done. Existing simulators are matched by name, device type and runtime.

Remote overrides: `E2E_REMOTE_HOST` (or `--host`), `E2E_REMOTE_ROOT`, `E2E_REMOTE_REPO`, `E2E_REMOTE_NODE` (absolute remote Node executable), `E2E_DEVELOPER_DIR` (remote Xcode, default `~/Applications/Xcode-27.1.app/Contents/Developer`), and the simulator variables above. Local `E2E_SOURCE_PACKAGES` defaults to `/tmp/poddle-dd-check/SourcePackages`; remote Node defaults to `~/.nvm/versions/node/v24.12.0/bin/node`. The controller validates both cached checkout revisions and clean tracked files against `Packages/PoddleKit/Package.resolved`, including ChefKit's project pin, before copying. The worker validates against the selected commit again and seeds Xcode's workspace lock from the tracked package lock. No access to the private ChefKit repo is needed on tinker-desk. If pins change, resolve them on the MacBook and sync a matching cache with the next remote run before relying on nightly.

The ports are 3410 (backend), 3411 (site) and 3412 (fixtures); set `E2E_CONVEX_PORT`, `E2E_SITE_PORT` and `E2E_FIXTURE_PORT` to move them for local runs. Only one run at a time per set of ports.

### Nightly and GitHub reporting

A user crontab entry tagged `# poddle-e2e-nightly` runs at **03:00 in tinker-desk's local time zone**. It's cron rather than a launch agent because nobody logs in to tinker-desk's desktop, and launchd never fires calendar jobs in the Background user domain without a GUI login. tinker-desk never sleeps (`pmset sleep 0`), so a missed run isn't caught up. It fetches `origin/main`, skips a SHA already reported, takes the shared render/e2e lock, and runs both suites. If the lock is busy, that night is skipped and the SHA stays eligible for the next launch. It waits for the remote-runner changes to land on main before its first suite run.

The deploy key pushes a small results commit to the **orphan `e2e-nightly` branch**, containing `results/latest.json`, up to 12 failure screenshots within a 5 MiB budget, and the reporting workflow. Each commit replaces the latest result tree; earlier results remain in branch history. Raw logs, traces, accessibility dumps and credentials stay off the branch. The last-nightly SHA is saved only after a successful push, including failed test results, so a push failure can retry. A failed test is rerun when main changes, not every night on the same commit.

`.github/workflows/e2e-nightly-report.yml` runs on pushes to that branch with `GITHUB_TOKEN` (`contents: read`, `issues: write`) and no other secrets. It opens or updates one `e2e-failure` issue, names the tested commit, lists failed scenarios and links screenshots at the immutable report commit. A green run comments on and closes open issues with that label. The workflow is also copied to the orphan branch because push workflows are read from the pushed branch. Deploy-key pushes trigger workflows normally, unlike pushes authenticated with `GITHUB_TOKEN` ([GitHub docs](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)).

### One-off tinker-desk setup

1. Poddle needs Xcode 27 (Swift 6.4). tinker-desk's `/Applications/Xcode.app` is 26.6, whose compiler crashes on the app, so the runner uses a copy of this Mac's Xcode at **`~/Applications/Xcode-27.1.app`**, through `DEVELOPER_DIR` (override with `E2E_DEVELOPER_DIR`). The default `xcode-select` is left alone. After copying an Xcode there, Mike runs once, in Terminal on the MacBook:

   ```sh
   ssh -t tinker-desk "sudo env DEVELOPER_DIR=\$HOME/Applications/Xcode-27.1.app/Contents/Developer sh -c 'xcodebuild -license accept && xcodebuild -runFirstLaunch'"
   ```

   Then, without sudo: `DEVELOPER_DIR=… xcodebuild -downloadPlatform iOS` (the matching simulator platform, which the build needs) and check with `xcodebuild -checkFirstLaunchStatus` and `xcrun simctl list runtimes`.
2. Keep the iOS 27.0 runtime (the default; the 27.1 runtime that downloads alongside supports no iPhones) and the iOS 18.1 one (for #6), and Node 24 via nvm (`~/.nvm/versions/node/v24.12.0`). Noninteractive SSH has no Node PATH, so use its absolute path or export its bin directory. `lockf`, `caffeinate`, git and rsync ship with macOS.
3. Keep `~/dev/me/poddle` cloned from `git@github-poddle:mikecann/poddle.git`. The `github-poddle` SSH alias uses the repo-only read-write deploy key. There is no `gh` login and no other GitHub access. Do not copy or print credentials.
4. Sync the resolved `SourcePackages` directory once from the MacBook, then use a remote iOS run to refresh it when pins change. Keep checkouts, repositories and `workspace-state.json`; the worker remaps absolute git alternates and binary-artifact paths. `Packages/PoddleKit/Package.resolved` has the authoritative checkout revisions.
5. From a checkout containing these changes on tinker-desk, run:

   ```sh
   export PATH="$HOME/.nvm/versions/node/v24.12.0/bin:/usr/bin:/bin:/usr/sbin:/sbin"
   node scripts/install-e2e-nightly.mjs
   crontab -l | grep poddle-e2e-nightly
   ```

   This copies the worker and reporter to `~/.local/share/poddle-e2e/tools`, writes `nightly.json` there, creates `~/Library/Logs/Poddle E2E/`, replaces the tagged crontab line (keeping any other entries), and removes the launch agent earlier installs used, without starting a suite. Rerun the installer after changing worker/reporting code. Logs are `nightly.log` and `nightly.error.log`. No sudo is needed.
6. The first iOS run creates the dedicated simulator. To create it once after Xcode setup, without running tests:

   ```sh
   xcrun simctl create "Poddle E2E" com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-18-1
   ```

   Check `xcrun simctl list devices` first to avoid a duplicate. Once the code is pushed, verify one app and one web scenario remotely, then run the full suite remotely before an App Store build.

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
- **The last rows of every list hid behind the mini player:** the bottom bar was a `safeAreaInset` outside each tab's `NavigationStack`, and the stack doesn't pass that on to its screens, so their lists only made room for the home indicator. The bar is now an overlay and every screen makes room for its measured height inside the stack (`bottomBarRoom` in `RootView.swift`). Scenario: "The end of a long Up Next scrolls clear of the mini player". Seen on the iOS 27.0 simulator.
