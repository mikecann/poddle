# Poddle

Mike's own podcast player for iPhone, iPad and Mac, built to replace Overcast. SwiftUI app plus a Convex backend.

- `docs/decisions.md`: what's been decided
- `docs/product-spec.md`: how it should behave
- `docs/architecture.md`: how the code is laid out
- `designs/c-earful-warm.html`: the chosen look (open it in a browser)
- `docs/api.md`: the backend API the app is written against, including the offline/outbox contract

## Launch arguments

With none, the app runs on live data (`LiveStore` over Convex: the dev deployment in Debug, prod in Release) and plays through the real engine (`EnginePlayer`). Pass these in the scheme's Arguments, or after `xcrun simctl launch <device> com.mikecann.poddle`. They're read in `App/PoddleApp.swift` (and `AppModel.applyLaunchScreen`).

| Argument | What it does |
|---|---|
| `-PoddleMock YES` | Sample data (`MockStore`) instead of Convex |
| `-PoddleLive YES` | Keep live data on a `-PoddleScreen` run, which otherwise uses sample data |
| `-PoddleScreen <name>` | Open a screen straight away for screenshots: `upNext`, `inbox`, `library`, `libraryList`, `podcast`, `showSettings`, `episode`, `settings`, `import`, `importDone`, `discover`, `stats`, `yearInReview`, `nowPlaying`, `speed`, `chapters`. Implies sample data and `MockPlayer`, unless overridden by the two rows either side |
| `-PoddleMockPlayer YES\|NO` | `YES` fakes playback and downloads (`MockPlayer`) on any launch; `NO` keeps the real engine on a `-PoddleScreen` run |
| `-PoddleAppearance dark\|light` | Force the colour scheme |
| `-PoddleRealAudio YES` | Sample data with the top of Up Next pointed at real, short public episodes (implies `-PoddleMock`) |
| `-PoddleAudioCheck YES` | Debug builds: plays the queue head, logs position and rate, downloads mid-stream and checks the queue advances. Use with `-PoddleRealAudio YES` |

Smaller ones: `-PoddlePaused YES` stops a mock screenshot run starting playback, `-PoddleAutoplay YES` starts the real engine playing at launch, and `-PoddleQuery <text>` pre-fills Discover.

## Backend

The Convex backend lives in `convex/`. Node 24+.

```sh
npm install
npm run dev:local    # local anonymous Convex deployment, no account needed
npx convex env set PODDLE_API_TOKEN <long random string>
```

| Script | What it does |
|---|---|
| `npm run dev` | `convex dev` against the linked deployment (watch, push, codegen) |
| `npm run dev:local` | `convex dev` against a local anonymous deployment |
| `npm run codegen` | Regenerate `convex/_generated` |
| `npm run deploy` | `convex deploy` to production |
| `npm run typecheck` | `tsc` over `convex/` and the tests |
| `npm test` | Vitest + convex-test, once |
| `npm run test:watch` | Vitest in watch mode |
| `npm run check` | Typecheck, then tests |
