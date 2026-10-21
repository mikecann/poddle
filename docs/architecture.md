# Architecture

## Repo layout

```
poddle/
  Poddle.xcodeproj        Xcode project using synchronized folders (objectVersion 77), so adding files never touches the pbxproj
  App/                    SwiftUI app sources, one multiplatform target (iOS + macOS)
    DesignSystem/         Poddle's tokens and components, taken from designs/c-earful-warm.html
    Features/             UpNext, Inbox, Library, Podcast, Discover, Stats, YearInReview, NowPlaying, Settings, Import
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

## Conventions

- Swift 6 language mode, strict concurrency, Observation (`@Observable`), SwiftUI only (AppKit/UIKit only where SwiftUI has no API). Deployment targets iOS 18 and macOS 26 (decisions.md); newer APIs go behind `if #available`.
- Times are content seconds as `Double` (TS `number`). Speeds are `Double` from 0.5 to 3.0 in 0.05 steps.
- Wall-clock timestamps are milliseconds since the epoch (`number` in Convex, `Double` in Swift).
- Backend tests use `convex-test` with Vitest. Swift tests use Swift Testing (`import Testing`).
