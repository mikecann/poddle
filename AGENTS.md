# Working on Poddle

Poddle is Mike's podcast player: a SwiftUI app (iPhone first, iPad and Mac later), a Convex backend in `convex/` and a website in `web/`. Read these first, in this order:

- `docs/decisions.md`: what's been decided. It wins over everything else.
- `docs/architecture.md`: how the code is laid out.
- `docs/api.md`: the backend API the app and website are written against.
- `docs/product-spec.md`: how it should behave, for the parts you're touching.
- `docs/testing.md`: the test layers, the BDD suites and how their isolated world works.

## Behaviour first

For anything a user can see (a feature, a bug fix, a changed flow), start from the behaviour:

1. Write down what should happen, as a scenario in `features/app/` or `features/web/` when it's a main journey.
2. Make it executable (a step module, a Convex test, a Swift test) before the implementation, and see it fail when you can.
3. Make the smallest change that makes it pass.

Feature files are plain user language about designed behaviour, not a regression dragnet. Validation matrices, API guards and styling belong in the lower layers.

## Test layer rules

Pick the smallest layer that proves the change:

- **Domain logic and Convex workflows:** Convex tests (`convex-test` + Vitest) in `tests/`. Feed parsing, the queue, settings resolution, stats maths, the import, auth and the allowlist all live here.
- **App logic without UI:** `swift test` in `Packages/PoddleKit` (store, sync, outbox, downloads policy, formatting, share links) and `Packages/PoddlePlayback` (the audio engine, Smart Speed, Voice Boost).
- **Website logic:** Vitest next to the code in `web/src/lib/*.test.ts`.
- **Critical journeys and rendering:** the end-to-end BDD suites, `features/app/*.feature` (XCUITest in the simulator) and `features/web/*.feature` (playwright-bdd), against a throwaway local backend.

Every real bug gets a regression test, at the lowest layer that would have caught it, plus a scenario when it broke a critical journey.

### Critical paths

These must keep end-to-end coverage. Change one, and its feature changes in the same commit.

- Signing in, the invite-only gate, signing out and deleting an account (app and website)
- Following a show (Discover search, a pasted feed URL) and unsubscribing with Undo
- New episodes landing in Up Next by each show's rule
- Up Next: reordering, archive, remove and mark played, each with Undo
- Playback: play, pause, skip, and moving on when an episode ends
- Now Playing's pages, and the artwork never archiving or skipping
- Speed: the default versus "Customize for <show>"
- Downloads and their Undo
- Share links: opening `/e/<id>?t=` in the app, and the website's share pages and link previews
- The Overcast import
- The website's `/me`, including a tab whose session has gone

### End-to-end cadence

The e2e suites are slow (the app's takes about 17 minutes), so the full suite runs overnight, not per change (Mike, 28 Oct 2026). e2e runs go to **tinker-desk** (Mike's spare Mac, over SSH) through `npm run test:e2e:remote`, so the M5 MacBook stays free.

- **Every change:** the smallest relevant checks: `npm run check`, one Vitest file, `swift test` in one package.
- **A change you can see, or one on a critical path above:** also run just the e2e features it touches, remotely (`--suite ios --feature <name>` or `--suite web -g "…"`), one run per feature. Not the whole suite.
- **Nightly:** tinker-desk runs the full suite at 03:00 local when `origin/main` has moved, and that's what catches knock-on breakage elsewhere. Results go to the orphan `e2e-nightly` branch; GitHub updates one `e2e-failure` issue and closes it after a green run. Look at that issue before starting on something new.
- **Before an App Store build:** the full suite, remotely, on the commit being shipped.
- If tinker-desk is busy (its shared lock is held), wait for it, or run the one feature locally. Don't hold a change up on the full suite.
- A regression on a critical path still gets its scenario. The cadence is about when to run the suite, not whether to cover the bug.

`npm run check` (typecheck, Vitest, BDD pairing and drift) runs no simulator or browser, so run it on every change.

### Fast feedback cheatsheet

| Check | Command |
| --- | --- |
| Typecheck, Vitest, BDD pairing and drift | `npm run check` |
| Typecheck only (backend, tests, website) | `npm run typecheck` |
| Vitest, once | `npm test` |
| One Vitest file | `npx vitest run tests/queue.test.ts` |
| BDD pairing and drift (no browsers, no simulators) | `npm run test:bdd-check` |
| PoddleKit / PoddlePlayback | `cd Packages/PoddleKit && swift test` (same for `PoddlePlayback`) |
| Website e2e, every scenario (remote) | `npm run test:e2e:remote -- --suite web` |
| One website scenario | `npm run test:e2e:web -- -g "scenario name"` |
| App e2e, every scenario (remote) | `npm run test:e2e:remote -- --suite ios` |
| One app feature | `npm run test:e2e:ios -- --feature up-next` |
| One app scenario | `npm run test:e2e:ios -- -g "part of its name"` |
| App e2e without rebuilding | `npm run test:e2e:ios -- --no-build -g "…"` |
| Both e2e suites on one world (remote) | `npm run test:e2e:remote` |
| Remote plan without running | `npm run test:e2e:remote -- --dry-run` |
| One remote app scenario | `npm run test:e2e:remote -- --suite ios -g "scenario name"` |
| A world to poke at by hand | `npm run e2e:world` (Ctrl-C stops it) |

Remote results come back to `e2e/.remote-results/<sha>/`. Local failures leave screenshots, accessibility trees, traces and logs in `e2e/.runtime/` (both git-ignored). `docs/testing.md` says what's where.

## Rules that bite

- **Off the main thread:** the app target defaults to MainActor isolation, and SwiftUI may resolve colours and shapes off the main thread. Keep that code `nonisolated` / `@Sendable`.
- **Accessibility identifiers, not text:** UI tests find things by identifiers (`tab.*`, `upNext.row.<id>`, `nowPlaying.*`, `miniPlayer.*`, `discover.*`, `settings.*`). When you rename one, grep `PoddleUITests/` and `features/` in the same change.
- **Debug-only hooks:** launch arguments (README, "Launch arguments") and `convex/testing.ts` exist for tests. Launch arguments are compiled out of Release; `testing.ts` refuses to run anywhere but a local backend with `PODDLE_E2E=1`.
- **Deployments:** tests never touch dev or prod. The e2e world is a local backend in a temp folder; don't point it at a real deployment.
- **Secrets** live in `~/.config/poddle/`. Never print or commit them.
