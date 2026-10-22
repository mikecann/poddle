import Foundation

/// The backend behind `PoddleStore`. `MockStore` is in-memory sample data, `LiveStore` talks
/// to Convex. The store applies mutations to its local copy straight away and sends them here in
/// order (the outbox), and the data source pushes fresh snapshots back.
public protocol PoddleDataSource: Sendable {
    /// Pushes a new snapshot whenever the synced state changes on the server.
    func snapshots() async -> AsyncStream<LibrarySnapshot>
    func send(_ mutation: Mutation) async throws

    func stats(year: Int) async throws -> StatsSummary
    func availableYears() async throws -> [Int]
    func yearInReview(year: Int) async throws -> YearInReview

    /// Apple Podcasts directory search.
    func search(_ term: String) async throws -> SearchResponse
    /// Resolves a pasted URL (RSS, podcasts.apple.com, overcast.fm, or a website) to a show.
    func resolve(url: String) async throws -> SearchResult?

    /// Uploads an Overcast "All data" OPML export and streams progress as the backend matches it.
    func importOvercast(fileName: String, data: Data, assumedSpeed: Double) async -> AsyncThrowingStream<ImportProgress, Error>

    /// Chapters for an episode (JSON chapters first, then embedded). Local only.
    func chapters(for episode: Episode) async -> [Chapter]

    // Live extras. `MockStore` takes the defaults below; `LiveStore` implements them all.

    /// Stats that update as listening is recorded. Yields the cached copy first when offline.
    func watchStats(year: Int) async -> AsyncThrowingStream<StatsSummary, Error>
    func watchYearInReview(year: Int) async -> AsyncThrowingStream<YearInReview, Error>
    /// Asks the backend to re-check feeds (one show, or every show if nil), then catches up.
    func refresh(podcastId: String?) async throws
    /// Keeps a podcast page's episodes and settings live until the calling task is cancelled.
    func observePodcast(_ podcastId: String) async
    /// Full show notes HTML, which the synced episode list leaves out.
    func showNotes(episodeId: String) async -> String?
    /// A shared link's episode or show (`episodes:get` / `podcasts:get`), added to the snapshot even
    /// when it isn't in the library. False if there's no such thing (or no connection).
    func loadShared(_ target: ShareLinks.Target) async -> Bool
    func connectionStatus() async -> AsyncStream<ConnectionStatus>

    /// Listening sessions for stats (`sessions:record`). The same `sessionId` is re-sent every 30 s
    /// with a later end while playing; the server keeps the newest copy. Throw to have them retried.
    func recordSessions(_ sessions: [SessionInput]) async throws

    /// This device's APNs token (`devices:register`, hex). The data source fills in its own
    /// `deviceId`, name and platform. Called at launch and whenever the token changes.
    func registerDevice(apnsToken: String, environment: APNsEnvironment) async throws
}

extension PoddleDataSource {
    public func watchStats(year: Int) async -> AsyncThrowingStream<StatsSummary, Error> {
        AsyncThrowingStream { c in
            Task {
                do { c.yield(try await stats(year: year)); c.finish() } catch { c.finish(throwing: error) }
            }
        }
    }

    public func watchYearInReview(year: Int) async -> AsyncThrowingStream<YearInReview, Error> {
        AsyncThrowingStream { c in
            Task {
                do { c.yield(try await yearInReview(year: year)); c.finish() } catch { c.finish(throwing: error) }
            }
        }
    }

    public func refresh(podcastId: String?) async throws {}
    public func observePodcast(_ podcastId: String) async {}
    public func showNotes(episodeId: String) async -> String? { nil }
    public func loadShared(_ target: ShareLinks.Target) async -> Bool { false }
    public func connectionStatus() async -> AsyncStream<ConnectionStatus> { AsyncStream { $0.finish() } }
}

/// How the live backend connection is doing, for the Settings screen.
public struct ConnectionStatus: Sendable, Hashable {
    public var deploymentURL: URL
    public var connected: Bool
    /// Actions waiting for the server.
    public var pending: Int
    /// Actions the server rejected, kept until retried or discarded.
    public var failed: Int
    public var lastSyncAt: Millis?
    public var error: String?

    public init(deploymentURL: URL, connected: Bool, pending: Int = 0, failed: Int = 0, lastSyncAt: Millis? = nil, error: String? = nil) {
        self.deploymentURL = deploymentURL; self.connected = connected; self.pending = pending; self.failed = failed
        self.lastSyncAt = lastSyncAt; self.error = error
    }

    /// "qualified-hedgehog-912"
    public var deploymentName: String {
        deploymentURL.host()?.split(separator: ".").first.map(String.init) ?? deploymentURL.absoluteString
    }
}


/// `SessionInput` in docs/api.md, field for field.
public struct SessionInput: Codable, Sendable, Hashable {
    /// Client UUID, stable for the whole session so re-sends replace the server's copy.
    public var sessionId: String
    public var episodeId: String
    public var deviceId: String?
    public var startedAt: Millis
    public var endedAt: Millis
    /// Content seconds.
    public var contentStart: Double
    public var contentEnd: Double
    public var rate: Double
    public var smartSpeed: Bool
    /// Content seconds Smart Speed cut.
    public var smartRemovedContent: Double
    public var voiceBoost: Bool
    /// `speaker`, `headphones`, `airPods`, `bluetooth`, `carPlay`, `airPlay` or `unknown`.
    public var route: String?
    public var utcOffsetMinutes: Int?

    public init(
        sessionId: String, episodeId: String, deviceId: String? = nil, startedAt: Millis, endedAt: Millis,
        contentStart: Double, contentEnd: Double, rate: Double, smartSpeed: Bool, smartRemovedContent: Double,
        voiceBoost: Bool, route: String? = nil, utcOffsetMinutes: Int? = nil
    ) {
        self.sessionId = sessionId; self.episodeId = episodeId; self.deviceId = deviceId
        self.startedAt = startedAt; self.endedAt = endedAt; self.contentStart = contentStart
        self.contentEnd = contentEnd; self.rate = rate; self.smartSpeed = smartSpeed
        self.smartRemovedContent = smartRemovedContent; self.voiceBoost = voiceBoost; self.route = route
        self.utcOffsetMinutes = utcOffsetMinutes
    }
}

/// Which APNs gateway a token belongs to. Debug builds are `sandbox`.
public enum APNsEnvironment: String, Codable, Sendable, Hashable {
    case sandbox, production

    public static var current: APNsEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}
