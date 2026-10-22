# Poddle

Mike's own podcast player for iPhone, iPad and Mac, built to replace Overcast. SwiftUI app plus a Convex backend.

- `docs/decisions.md`: what's been decided
- `docs/product-spec.md`: how it should behave
- `docs/architecture.md`: how the code is laid out
- `designs/c-earful-warm.html`: the chosen look (open it in a browser)
- `docs/api.md`: the backend API the app is written against, including the offline/outbox contract

## Brand

Poddle's headphones poodle is direction A from `docs/decisions.md`, in the warm paper and tomato look.

- `designs/branding/final/src/`: approved board, light/dark icon art and six transparent mascot originals, kept unchanged.
- `designs/branding/final/`: light, dark and grayscale tinted icons (1024×1024), trimmed mascots (up to 800px), and the default link preview (1200×630).
- `App/Assets.xcassets/`: iOS icon appearances, macOS icon sizes, `BrandIcon` and namespaced `Mascot/listening`, `sleeping`, `waving`, `empty`, `searching`, `confused` image sets. `App/DesignSystem/Brand.swift` provides the views and rounded heavy wordmark.
- `web/public/`: PNG favicons (16/32), Apple touch icon (180), manifest icons (192/512), mascots and `og-default.png`. The self-hosted Fredoka wordmark font and its SIL Open Font License are in `fonts/`.

Regenerate the processed PNGs with `swift scripts/prepare-brand.swift` from the repo root. The website and asset catalog keep their own copies of these files.

## Launch arguments

With none, the app runs on live data (`LiveStore` over Convex: the dev deployment in Debug, prod in Release) and plays through the real engine (`EnginePlayer`). Pass these in the scheme's Arguments, or after `xcrun simctl launch <device> com.mikecann.poddle`. They're read in `App/PoddleApp.swift` (and `AppModel.applyLaunchScreen`), and only in Debug builds: the Release (App Store) build ignores them all.

| Argument | What it does |
|---|---|
| `-PoddleMock YES` | Sample data (`MockStore`) instead of Convex |
| `-PoddleLive YES` | Keep live data on a `-PoddleScreen` run, which otherwise uses sample data |
| `-PoddleScreen <name>` | Open a screen straight away for screenshots: `upNext`, `library`, `libraryList`, `podcast`, `showSettings`, `episode`, `settings`, `import`, `importDone`, `discover`, `stats`, `yearInReview`, `nowPlaying`, `npNotes` (or `chapters`), `npSettings` (or `speed`), `queue`, the Undo checks `undoArchive`, `undoArchiveUndone`, `undoRemove`, `undoRemoveUndone`, the companion and empty states `upNextEmpty`, `discoverEmpty`, `notFound`, `sleepTimer`, `signIn`, `celebrate`, and `companionDemo` (plays, then pauses after 6 s so Poddle dozes off). Implies sample data and `MockPlayer`, unless overridden by the two rows either side |
| `-PoddleMockPlayer YES\|NO` | `YES` fakes playback and downloads (`MockPlayer`) on any launch; `NO` keeps the real engine on a `-PoddleScreen` run |
| `-PoddleAppearance dark\|light` | Force the colour scheme |
| `-PoddleRealAudio YES` | Sample data with the top of Up Next pointed at real, short public episodes (implies `-PoddleMock`) |
| `-PoddleAudioCheck YES` | Debug builds: plays the queue head, logs position and rate, downloads mid-stream and checks the queue advances. Use with `-PoddleRealAudio YES` |

Signing in (Debug simulator builds only): `-PoddleTestSignIn <email>` signs in at launch with test sign-in if signed out (the dev deployment needs `PODDLE_TEST_SIGNIN=1`; it reuses the user with that email, e.g. `mike.cann@gmail.com` on the dev copy of prod, or makes a test user). `-PoddleSignOut YES` (Debug) signs out at launch, the same way Settings does. The sign-in screen also has the test button with an email field.

Share links (Debug): `-PoddleOpenURL <url>` opens a website link at launch as if it had been tapped, e.g. `https://striped-turtle-260.ap-southeast-2.convex.site/e/<id>?t=754` or `poddle://s/<id>`.

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

## Website

`web/` is the website, [poddle.mikecann.app](https://poddle.mikecann.app): public pages for an episode (`/e/<id>`, with a player that starts at `?t=`) and a show (`/s/<id>`), with link previews for iMessage, Slack, X and WhatsApp, and a signed-in `/me` with your Up Next, shows, recent listening and stats. It's served by Convex static hosting on the same deployment as the backend; `docs/architecture.md` ("Website") has the details and `docs/api.md` ("Website and share links") the routes and the public queries.

| Script | What it does |
|---|---|
| `npm run web:dev` | Vite dev server on http://localhost:5174, against dev |
| `npm run web:build` | Build into `web/dist` |
| `npm run web:upload:dev` | Build (with the dev-only test sign-in form) and upload to dev's static hosting |
| `npm run web:upload:prod` | Build and upload to prod (see `docs/runbooks/website-prod.md`) |

Deploy the backend first (`npx convex dev --once` on dev), since the site's `/e` and `/s` pages and its queries live there. In the app, episode and show context menus and the show page share these links (`ShareLinks.episode(id, at:)`, `ShareLinks.show(id)`), and opening one goes to that episode or show, fetching it if it isn't in your library. Private feeds get no links and no pages.

## Accounts and sign-in

Everyone signs in with Apple or Google (Convex Auth v2, set up like Walkies). Each person has their own library, queue, settings, stats and devices; shows and episodes are shared. Sign-up is limited to `PODDLE_ALLOWED_EMAILS` unless `PODDLE_OPEN_SIGNUP=1`, which lets anyone with a verified Apple or Google email in. People can delete their account in the app (Profile) or on `/me`. Releasing to the App Store: `docs/runbooks/appstore-release.md`. The API reference is in `docs/api.md`, "Accounts and sign-in".

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

## Chef (feature requests and cloud builds)

Settings > Feedback > "Suggest a feature" opens Chef, Seth Raphael's feedback board (`@convex-dev/feedback`, private and pre-release, from `sethconvex/feedback-chef`). People type a request, or send a screenshot with a voice note, and follow it through. There's no floating button. The admin (Mike) gets Chef's admin sheet. At this commit ChefKit never loads its approval queue, though: `ChefApprovalsSection` binds `awaitingApproval` in a `.task` on a `Group` that's empty until the list loads, so the task never runs. Until Seth fixes it, Mike approves, watches builds and ships from Chef's web panel. It's on the website's `/me`, for the admin only (`web/src/components/ChefAdminPanel.tsx`). Chef also has **cloud builds** (`@convex-dev/chef-cloud`): an approved request (Mike's own skip approval) is built by Claude Code in a Daytona sandbox, checked with `npm run typecheck` and `npm test`, pushed to the app's repo on Convex's Code Storage, and deployed to a preview deployment with the website on it. "Ship it" in the sheet then deploys it. It all runs on Convex's marketplace components, billed to the `mikec` team, with no keys of Mike's. A build costs about $1 in model calls (capped at $20) plus sandbox time.

- **Backend:** both packages are vendored in `vendor/` from the same commit (`dc9056d4bfb5`). `convex/convex.config.ts` uses both components. `convex/chef.ts` has the API (`exposeChefApi`, on `currentUserId`, so merged accounts are one person) and the cloud functions (`chefCloud`: the website is the frontend a build previews, `npm run web:build` into `web/dist`). `convex/http.ts` mounts the runner's `/chef-agent/*` routes. `scripts/chef-local-env.mjs` gives a build's local backend throwaway values for the env vars `convex.config.ts` requires; add new required ones there.
- **Sydney patch:** Chef only knows `<name>.convex.cloud`/`.convex.site` URLs, and Poddle's dev and prod are `<name>.ap-southeast-2.convex.*`. `scripts/chef-patch-vendor.sh` widens the two host checks that stop builds and "Ship it" (`tests/chef.test.ts` fails without it). Run it again after packing a new Chef, until Chef handles regions itself.
- **App:** the `ChefKit` Swift package, pinned to the same commit and linked on iOS only (it doesn't build for the Mac). `App/Features/Chef/ChefConnection.swift` runs Chef's calls on `LiveStore`'s own connection and session (`rawMutation`, `rawSubscribe`). The app installs it at launch and again when the account changes.
- **Admin:** `npx convex run chef:chefSetAdmin '{"userId":"<users _id>"}'` (add `--prod` for prod). `npx chef status` shows the setup, by name only.
- **Your checkout after a ship:** "Ship it" moves the Chef repo's `main`. Run `git pull chef main` before deploying from your checkout. `npm run dev` runs `chef guard` first and refuses until you have.

### Trying an iOS change from a cloud build

Chef's sandboxes can't compile Swift. A build that changes `App/` or `Packages/` is checked by its gates only (the backend and website). The Ship card flags it as iOS code the cloud didn't compile. To try it on the phone (plugged in, or on the same Wi-Fi):

```bash
scripts/chef-ios.sh <runId or request id>          # Release against prod, like the phone normally runs
CONFIG=Debug scripts/chef-ios.sh <id>              # Debug against dev
```

It fetches the build's commit from the `chef` remote into a throwaway worktree, builds and installs it with `scripts/install-phone.sh`'s signing (the App Store Connect key, no Xcode account), and marks the run "compiled ✓ / installed ✓" on its card. The run id is on the card in the web panel and in `npx convex run chef:recentRuns`. `npx chef ios <id>` (configured under `chef.ios` in package.json) does the same with Xcode's own signing, but that needs an Apple account signed in to Xcode, and this Mac doesn't have one. Debug builds read `-ChefConvexURL <url>` to talk to a build's preview backend (`PREVIEW=1`), but signing in there needs test sign-in, so use dev or prod unless the change needs the preview's backend. To ship, press "Ship it" for the backend and website, and install the app from `main` as usual.
