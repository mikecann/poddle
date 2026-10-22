# Architecture

## Repo layout

```
poddle/
  Poddle.xcodeproj        Xcode project using synchronized folders (objectVersion 77), so adding files never touches the pbxproj
  App/                    SwiftUI app sources, one multiplatform target (iOS + macOS)
    DesignSystem/         Poddle's tokens and components, taken from designs/c-earful-warm.html
    Features/             UpNext, Library, Podcast, Discover, Stats, YearInReview, NowPlaying, Settings, Import, Undo
    Preview/              mock data for previews and the mock data source
  Packages/
    PoddleKit/            Swift package: models, the API layer over convex-swift, local cache + outbox, settings resolution, formatting
    PoddlePlayback/       Swift package: the audio engine (AVAudioEngine, time-pitch, Smart Speed, Voice Boost), remote commands, Now Playing info
  convex/                 Convex backend (TypeScript)
  package.json            backend tooling
  docs/  designs/  scripts/
```

## Who owns what

- **Convex** owns all shared state and the domain logic: feeds (fetch, parse, poll, auto-add rules), library, episodes, per-episode user state, the queue (fractional order keys), settings with per-show overrides, listening sessions, stats and year-in-review maths, the Overcast import pipeline, Apple Podcasts search (proxied or direct), and APNs push. The API is documented in `docs/api.md`, which the backend keeps current.
- **PoddleKit** mirrors the backend's documents as `Codable` value types (IDs are the Convex document ID strings). It wraps the Convex client behind a `PoddleStore` protocol with two implementations, live (Convex) and mock (in-memory sample data), so the UI can be built and previewed without a backend. It also holds the persistent local cache, the mutation outbox, settings resolution (`show override ?? global`) and display formatting ("38m left at 1.8×").
- **PoddlePlayback** depends on nothing in the app. It takes plain values (a local file or remote URL, start position, rate, Smart Speed / Voice Boost flags) and publishes playback state (content position, duration, playing, Smart Speed seconds removed) plus listening-session segments for stats. The app wires it to the store.
- **App** is SwiftUI views and view models over `PoddleStore` and the playback engine.

## Accounts

- **Who's who:** Convex Auth v2 with Apple and Google (web sign-in pages in `ASWebAuthenticationSession`, coming back on `poddle://signed-in`), plus a dev-only test sign-in. Details and the function list are in `docs/api.md`, "Accounts and sign-in".
- **Backend data:** shows, episodes, show notes, feed bookkeeping and the directory cache are shared. Everything else is personal and keyed by `userId`, with every index starting with it (the few exceptions are commented in `convex/schema.ts`). Public functions are built with `userQuery`/`userMutation`/`userAction` (`convex/lib/auth.ts`), which put the caller on `ctx.userId`; the `lib/` helpers read it from there, and internal functions that work for one person use `asUser(ctx, userId)`. A person's library is their `subscriptions` rows, which also decide which shared shows and episodes `sync:changes` sends them.
- **App:** `Account` (PoddleKit) keeps the Convex Auth session in the Keychain (one per deployment), refreshes the minute-long access token and hands it to convex-swift through its auth callback. `LiveStore` belongs to one person at a time: its cache and outbox live under `Application Support/Poddle/<deployment>/<user id>/`, and `switchAccount` swaps them when someone signs in or out. Signed in but offline, the app opens from that person's cache and the outbox replays once the client has a token again. The pre-accounts cache and outbox (straight under the deployment folder) go to the first person to sign in on the device after the update.
- **Scripts** act as a named user through the admin path (`admin: { token, email }`, checked against `PODDLE_API_TOKEN`).

## Conventions

- Swift 6 language mode, strict concurrency, Observation (`@Observable`), SwiftUI only (AppKit/UIKit only where SwiftUI has no API). Deployment targets iOS 18 and macOS 26 (decisions.md); newer APIs go behind `if #available`.
- Times are content seconds as `Double` (TS `number`). Speeds are `Double` from 0.5 to 3.0 in 0.05 steps.
- Wall-clock timestamps are milliseconds since the epoch (`number` in Convex, `Double` in Swift).
- Backend tests use `convex-test` with Vitest. Swift tests use Swift Testing (`import Testing`).
