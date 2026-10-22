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

Signing in (Debug simulator builds only): `-PoddleTestSignIn <email>` signs in at launch with test sign-in if signed out (the dev deployment needs `PODDLE_TEST_SIGNIN=1`; it reuses the user with that email, e.g. `mike.cann@gmail.com` on the dev copy of prod, or makes a test user). `-PoddleSignOut YES` (Debug) signs out at launch, the same way Settings does. The sign-in screen also has the test button with an email field.

Smaller ones: `-PoddlePaused YES` stops a mock screenshot run starting playback, `-PoddleAutoplay YES` starts the real engine playing at launch, and `-PoddleQuery <text>` pre-fills Discover.

## Backend

The Convex backend lives in `convex/`. Node 24+.

```sh
npm install
npm run dev:local    # local anonymous Convex deployment, no account needed
node scripts/set-auth-keys.mjs dev              # Convex Auth signing keys
node scripts/set-oauth-keys.mjs dev --placeholders   # lets it deploy before Apple/Google exist
npx convex env set PODDLE_ALLOWED_EMAILS mike.cann@gmail.com
npx convex env set PODDLE_TEST_SIGNIN 1         # dev only, never prod
npx convex env set PODDLE_API_TOKEN <long random string>   # for scripts' admin path
```

The app needs no secrets: Debug talks to dev (`striped-turtle-260`) and Release to prod (`coordinated-dodo-120`), both set in `Config/*.xcconfig`, and people sign in.

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

## Accounts and sign-in

Everyone signs in with Apple or Google (Convex Auth v2, set up like Walkies). Each person has their own library, queue, settings, stats and devices; shows and episodes are shared. Sign-up is limited to `PODDLE_ALLOWED_EMAILS`. The API reference is in `docs/api.md`, "Accounts and sign-in".

### Setting up Apple and Google sign-in

Each deployment needs its return URLs registered:

- dev: `https://striped-turtle-260.ap-southeast-2.convex.site/oauth/apple/callback` and `/oauth/google/callback`
- prod: `https://coordinated-dodo-120.ap-southeast-2.convex.site/oauth/apple/callback` and `/oauth/google/callback`
- if prod's `CONVEX_SITE_URL` moves to `https://poddle.mikecann.app`, also `https://poddle.mikecann.app/oauth/{apple,google}/callback`

**Apple** (developer.apple.com > Certificates, IDs & Profiles):
1. Identifiers > App IDs > `com.mikecann.poddle`: tick Sign in with Apple.
2. Identifiers > + > Services IDs: make one, e.g. `com.mikecann.poddle.signin`. Tick Sign in with Apple > Configure: primary App ID `com.mikecann.poddle`, domains `striped-turtle-260.ap-southeast-2.convex.site` and `coordinated-dodo-120.ap-southeast-2.convex.site` (plus `poddle.mikecann.app` if used), and the return URLs above.
3. Keys > +: tick Sign in with Apple (for `com.mikecann.poddle`), download `AuthKey_<ID>.p8` and note the key ID.

**Google** (console.cloud.google.com, a project for Poddle):
1. APIs & Services > OAuth consent screen: External; add the allowed emails as test users while it's in Testing.
2. Credentials > Create credentials > OAuth client ID > Web application, with the Google return URLs above. Copy the client ID and secret.

Then put them in a JSON file (see the top of `scripts/set-oauth-keys.mjs`) and run it for each deployment. Nothing is printed.

```bash
node scripts/set-oauth-keys.mjs dev ~/Downloads/poddle-oauth.json
node scripts/set-oauth-keys.mjs prod ~/Downloads/poddle-oauth.json
```

The app uses the web sign-in pages in a secure sheet rather than the native Sign in with Apple sheet, because Convex Auth v2 can't redeem a native Apple identity token.

### Test sign-in

On dev only (`PODDLE_TEST_SIGNIN=1`), `auth:signInForTesting { email? }` signs in without Apple or Google, as the user with that email (or a new test user). The server refuses it unless the flag is exactly `1`, and on prod's addresses even then. In the app: the button on the sign-in screen (Debug simulator builds), or `-PoddleTestSignIn <email>`.

### Scripts: the admin path

Scripts act as a named user by passing `admin: { token, email }` to any public function, where `token` is `PODDLE_API_TOKEN` (`~/.config/poddle/api-token`). `node scripts/import-overcast.mjs <deployment url> <opml> [speed] [email]` imports into that person's library (Mike's by default).

### The accounts migration

Before accounts everything was Mike's. `npx convex run migrations:run` makes his user and gives it every existing personal row; `npx convex run migrations:report` shows the counts. The prod steps are in `docs/runbooks/accounts-prod.md`.
