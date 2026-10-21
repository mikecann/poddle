import Foundation

/// The Convex-backed data source. A stub until the backend API (docs/api.md) is ready.
///
/// Wiring plan:
/// - Add the `convex-swift` package and hold a `ConvexClient` for the deployment URL.
/// - Every call passes `PODDLE_API_TOKEN` from the Keychain.
/// - `snapshots()` subscribes to the library queries and merges them into a `LibrarySnapshot`.
/// - `send(_:)` maps each `Mutation` case to its Convex mutation. The store already applies it
///   locally and calls `send` in order, so this is the outbox. Persist pending mutations so they
///   survive a relaunch offline.
/// - Cache the last snapshot on disk (SwiftData or a JSON file) and seed `PoddleStore` with it.
public final class LiveStore: PoddleDataSource {
    public let deploymentURL: URL
    private let token: String

    public init(deploymentURL: URL, token: String) {
        self.deploymentURL = deploymentURL
        self.token = token
    }

    public func snapshots() async -> AsyncStream<LibrarySnapshot> {
        // TODO: subscribe to podcasts, episodes, episodeStates, queue, globalSettings and
        // podcastSettings, and yield a merged snapshot whenever any of them changes.
        AsyncStream { $0.finish() }
    }

    public func send(_ mutation: Mutation) async throws {
        // TODO: switch over `mutation` and call the matching Convex mutation, e.g.
        // .enqueue -> "queue:enqueue", .setPlayed -> "episodes:setPlayed",
        // .updatePodcastSettings -> "settings:updatePodcast". Retry on network errors.
        throw LiveStoreError.notWired
    }

    public func stats(year: Int) async throws -> StatsSummary {
        // TODO: query "stats:summary" { year }.
        throw LiveStoreError.notWired
    }

    public func availableYears() async throws -> [Int] {
        // TODO: query "stats:years".
        throw LiveStoreError.notWired
    }

    public func yearInReview(year: Int) async throws -> YearInReview {
        // TODO: query "stats:yearInReview" { year }. Private shows come back flagged.
        throw LiveStoreError.notWired
    }

    public func search(_ term: String) async throws -> SearchResponse {
        // TODO: call the Convex action that proxies iTunes Search (debounced 400 ms by the UI,
        // cached 24 h server-side), or hit itunes.apple.com directly.
        throw LiveStoreError.notWired
    }

    public func resolve(url: String) async throws -> SearchResult? {
        // TODO: "directory:resolveUrl" handles RSS, podcasts.apple.com, overcast.fm and websites.
        throw LiveStoreError.notWired
    }

    public func importOvercast(fileName: String, data: Data, assumedSpeed: Double) async -> AsyncThrowingStream<ImportProgress, Error> {
        // TODO: upload `data` to Convex storage, start "import:overcast" with the assumed speed,
        // then subscribe to the import batch document and map it to ImportProgress.
        AsyncThrowingStream { $0.finish(throwing: LiveStoreError.notWired) }
    }

    public func chapters(for episode: Episode) async -> [Chapter] {
        // TODO: fetch episode.chaptersURL (Podcasting 2.0 JSON); otherwise read ID3/MP4 chapters
        // from the downloaded file via PoddlePlayback.
        []
    }
}

public enum LiveStoreError: LocalizedError {
    case notWired
    public var errorDescription: String? { "The Convex backend isn't wired up yet." }
}
