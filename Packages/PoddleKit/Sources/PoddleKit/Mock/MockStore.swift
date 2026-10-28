import Foundation

/// In-memory backend with believable sample data. It plays the server's part: it applies every
/// mutation to its own copy and pushes the result back, so the whole UI works without Convex.
public actor MockStore: PoddleDataSource {
    private var server: LibrarySnapshot
    private var listeners: [UUID: AsyncStream<LibrarySnapshot>.Continuation] = [:]
    private var nextId = 1
    /// What `sessions:record` would hold, keyed by `sessionId` (the newest copy wins).
    public private(set) var sessions: [String: SessionInput] = [:]
    public private(set) var apnsToken: (token: String, environment: APNsEnvironment)?
    private let now: @Sendable () -> Date
    /// Scales the fake network delays. 0 makes everything instant (tests).
    private let latency: Double

    public init(snapshot: LibrarySnapshot? = nil, latency: Double = 1, now: @escaping @Sendable () -> Date = { Date() }) {
        self.server = snapshot ?? MockData.snapshot(now: now())
        self.latency = latency
        self.now = now
    }

    /// A store wired to a fresh mock backend, seeded synchronously so first paint has data.
    @MainActor
    public static func makeStore(now: Date = Date(), sync: Bool = true) -> PoddleStore {
        makeStore(seed: MockData.snapshot(now: now), downloads: MockData.downloads(), sync: sync)
    }

    @MainActor
    public static func makeStore(seed: LibrarySnapshot, downloads: [String: Download], sync: Bool = true) -> PoddleStore {
        PoddleStore(dataSource: MockStore(snapshot: seed), seed: seed, downloads: downloads, sync: sync)
    }

    private var nowMillis: Millis { now().timeIntervalSince1970 * 1000 }

    private func pause(_ ms: Int) async {
        guard latency > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(Double(ms) * latency)))
    }

    private func makeId() -> String {
        defer { nextId += 1 }
        return "mock\(nextId)"
    }

    public func snapshots() -> AsyncStream<LibrarySnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: LibrarySnapshot.self)
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func broadcast() {
        for l in listeners.values { l.yield(server) }
    }

    public func send(_ mutation: Mutation) async throws {
        await pause(40)
        if case let .subscribe(request) = mutation, !server.podcasts.values.contains(where: { $0.feedURL == request.feedURL }) {
            addShow(request)
        } else {
            server.apply(mutation, now: nowMillis, newId: makeId)
        }
        broadcast()
    }

    /// What Convex does on subscribe: fetch the feed, store the show and its episodes, and put
    /// the newest one where the show's auto-add rule says.
    private func addShow(_ request: SubscribeRequest) {
        let entry = MockData.catalogue.first { $0.result.feedURL == request.feedURL }?.result
        let id = "pod_" + (entry?.appleId ?? makeId())
        let title = request.title ?? entry?.title ?? URL(string: request.feedURL)?.host() ?? "New show"
        server.podcasts[id] = Podcast(
            id: id, feedURL: request.feedURL, isPrivate: request.isPrivate, title: title,
            author: request.author ?? entry?.author ?? "", artworkURL: request.artworkURL,
            description: "Freshly followed. Episodes arrive as the feed updates.", category: entry?.genre,
            appleId: request.appleId ?? entry?.appleId, subscribed: true, subscribedAt: nowMillis, lastFetchedAt: nowMillis
        )
        for (ep, state) in MockData.freshEpisodes(podcastId: id, title: title, now: nowMillis) {
            server.episodes[ep.id] = ep
            server.states[ep.id] = state
        }
    }

    public func stats(year: Int) async throws -> StatsSummary {
        await pause(150)
        return MockData.stats(year: year, currentYear: Calendar.current.component(.year, from: now()))
    }

    public func availableYears() async throws -> [Int] {
        let current = Calendar.current.component(.year, from: now())
        return Array((2014...current).reversed())
    }

    public func yearInReview(year: Int) async throws -> YearInReview {
        await pause(150)
        return MockData.yearInReview(year: year)
    }

    public func search(_ term: String) async throws -> SearchResponse {
        await pause(250)
        return MockData.search(term)
    }

    /// Episodes in the sample library whose titles match every word.
    public func searchEpisodes(_ term: String) async throws -> [EpisodeSearchResult] {
        await pause(250)
        let tokens = term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !tokens.isEmpty else { return [] }
        return server.episodes.values
            .filter { e in tokens.allSatisfy { e.title.lowercased().contains($0) } }
            .sorted { $0.pubDate > $1.pubDate }
            .prefix(10)
            .compactMap { e in
                guard let show = server.podcasts[e.podcastId] else { return nil }
                return EpisodeSearchResult(
                    id: "apple_\(e.id)", title: e.title, showTitle: show.title, author: show.author, feedURL: show.feedURL,
                    guid: e.guid, audioURL: e.enclosureURL, pubDate: e.pubDate, duration: e.duration, artworkURL: show.artworkURL
                )
            }
    }

    /// Only shows the sample data already has: there's no feed to fetch.
    public func open(_ target: DiscoverTarget) async throws -> OpenedFeed {
        await pause(300)
        let feedURL: String
        var guid: String?
        switch target {
        case let .show(r): feedURL = r.feedURL
        case let .episode(e): feedURL = e.feedURL; guid = e.guid
        }
        guard let show = server.podcasts.values.first(where: { $0.feedURL == feedURL }) else { throw CancellationError() }
        let episode = guid.flatMap { g in server.episodes.values.first { $0.podcastId == show.id && $0.guid == g } }
        return OpenedFeed(podcastId: show.id, episodeId: episode?.id)
    }

    public func resolve(url: String) async throws -> SearchResult? {
        await pause(300)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed), let host = u.host() else { return nil }
        if let known = server.podcasts.values.first(where: { $0.feedURL == u.absoluteString || $0.feedURL.hasPrefix(u.absoluteString) }) {
            return SearchResult(id: known.id, title: known.title, author: known.author, genre: known.category ?? "", feedURL: known.feedURL)
        }
        if let appleId = trimmed.firstMatch(of: /id(\d{6,})/)?.1,
           let hit = MockData.catalogue.first(where: { $0.result.appleId == String(appleId) }) {
            return hit.result
        }
        let name = host.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map { $0.capitalized } ?? host
        return SearchResult(id: "url_\(host)", title: name, author: host, genre: "Podcast", feedURL: u.absoluteString)
    }

    public func importOvercast(fileName: String, data: Data, assumedSpeed: Double) async -> AsyncThrowingStream<ImportProgress, Error> {
        let started = nowMillis
        let latency = latency
        let speed = max(0.5, assumedSpeed)
        // March 2014, where Mike's Overcast history starts.
        let earliest = Date(timeIntervalSince1970: 1_394_150_400).timeIntervalSince1970 * 1000
        return AsyncThrowingStream { continuation in
            let task = Task {
                let steps = 24
                let finalHours = (3_456 / speed).rounded()
                continuation.yield(ImportProgress(phase: .reading, fileName: fileName, importedAt: started))
                if latency > 0 { try? await Task.sleep(for: .milliseconds(Int(500 * latency))) }
                for i in 1...steps {
                    let f = Double(i) / Double(steps)
                    let eased = 1 - pow(1 - f, 2)
                    continuation.yield(ImportProgress(
                        phase: i == steps ? .done : .matching, fileName: fileName,
                        podcasts: Int((84 * min(1, f * 2.2)).rounded()), playedEpisodes: Int((3_412 * eased).rounded()),
                        hours: (finalHours * eased).rounded(), halfFinished: Int((37 * eased).rounded()), fraction: f,
                        earliest: f > 0.3 ? earliest : nil, importedAt: started
                    ))
                    if latency > 0 { try? await Task.sleep(for: .milliseconds(Int(110 * latency))) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func chapters(for episode: Episode) async -> [Chapter] {
        MockData.chapters(for: episode.id, duration: episode.duration ?? 0)
    }

    public func recordSessions(_ batch: [SessionInput]) async throws {
        await pause(40)
        for s in batch {
            // Like the server: an identical or older copy is ignored.
            if let old = sessions[s.sessionId], old.endedAt >= s.endedAt { continue }
            sessions[s.sessionId] = s
        }
    }

    public func registerDevice(apnsToken: String, environment: APNsEnvironment) async throws {
        await pause(40)
        self.apnsToken = (apnsToken, environment)
    }
}
