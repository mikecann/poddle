import Foundation
import Observation

/// The app's model. Holds the local copy of everything synced plus device-local state, answers
/// every query the screens make, and turns user actions into mutations: applied locally straight
/// away, then sent to the data source in order.
@MainActor
@Observable
public final class PoddleStore {
    public private(set) var snapshot: LibrarySnapshot
    public private(set) var downloads: [String: Download]
    public private(set) var chapterCache: [String: [Chapter]] = [:]

    public private(set) var stats: StatsSummary?
    public private(set) var years: [Int] = []
    public private(set) var yearInReview: YearInReview?
    public private(set) var importProgress: ImportProgress?
    public private(set) var lastError: String?
    /// Mutations sent but not yet acknowledged.
    public private(set) var pending: [Mutation] = []

    public let deviceId: String

    @ObservationIgnored public let dataSource: any PoddleDataSource
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored private var outbox: AsyncStream<Mutation>.Continuation?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(
        dataSource: any PoddleDataSource, seed: LibrarySnapshot = .init(), downloads: [String: Download] = [:],
        deviceId: String = "this-device", sync: Bool = true
    ) {
        self.dataSource = dataSource
        self.snapshot = seed
        self.downloads = downloads
        self.deviceId = deviceId
        if sync { startSync() }
    }

    private func startSync() {
        let (stream, continuation) = AsyncStream.makeStream(of: Mutation.self)
        outbox = continuation
        let source = dataSource
        tasks.append(Task { [weak self] in
            for await m in stream {
                do { try await source.send(m) } catch { self?.lastError = error.localizedDescription }
                if let self, !self.pending.isEmpty { self.pending.removeFirst() }
            }
        })
        tasks.append(Task { [weak self] in
            for await remote in await source.snapshots() {
                guard let self else { return }
                var next = remote
                for m in self.pending { next.apply(m, now: self.nowMillis) }
                if next != self.snapshot { self.snapshot = next }
            }
        })
    }

    var nowMillis: Millis { now().timeIntervalSince1970 * 1000 }

    /// Applies a mutation locally and queues it for the backend.
    public func perform(_ m: Mutation) {
        snapshot.apply(m, now: nowMillis)
        guard let outbox else { return }
        pending.append(m)
        outbox.yield(m)
    }

    // MARK: - Lookups

    public var global: GlobalSettings { snapshot.global }
    public func podcast(_ id: String) -> Podcast? { snapshot.podcasts[id] }
    public func episode(_ id: String) -> Episode? { snapshot.episodes[id] }
    public func resolved(_ podcastId: String) -> ResolvedSettings { snapshot.resolved(podcastId) }
    public func settings(for podcastId: String) -> PodcastSettings {
        snapshot.podcastSettings[podcastId] ?? PodcastSettings(podcastId: podcastId)
    }

    public func item(_ episodeId: String) -> EpisodeItem? {
        guard let ep = snapshot.episodes[episodeId], let pod = snapshot.podcasts[ep.podcastId] else { return nil }
        return EpisodeItem(
            episode: ep, podcast: pod, state: snapshot.state(episodeId), isQueued: snapshot.isQueued(episodeId),
            speed: snapshot.resolved(pod.id).speed, download: downloads[episodeId]
        )
    }

    /// The whole queue in order. The head is what's playing (or plays next).
    public var queue: [EpisodeItem] { snapshot.queue.compactMap { item($0.episodeId) } }

    /// The Up Next list: the queue minus whatever's loaded in the player.
    public func upNext(excluding current: String?) -> [EpisodeItem] {
        queue.filter { $0.id != current }
    }

    /// Wall-clock time to get through these at each show's own speed.
    public func wallTime(_ items: [EpisodeItem]) -> Double { items.reduce(0) { $0 + $1.wallRemaining } }

    /// New episodes waiting for a decision, newest first.
    public var inbox: [EpisodeItem] {
        snapshot.states.values
            .filter { snapshot.isInInbox($0.episodeId) }
            .compactMap { item($0.episodeId) }
            .filter { $0.podcast.subscribed }
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
    }

    /// Subscribed shows, most recently updated first.
    public var library: [Podcast] {
        snapshot.podcasts.values.filter(\.subscribed)
            .sorted { (latestPubDate($0.id) ?? 0) > (latestPubDate($1.id) ?? 0) }
    }

    /// Unsubscribed shows that still have history, so imported history isn't orphaned.
    public var pastShows: [Podcast] {
        snapshot.podcasts.values.filter { p in
            !p.subscribed && snapshot.episodes.values.contains { $0.podcastId == p.id && snapshot.state($0.id).played }
        }.sorted { $0.title < $1.title }
    }

    public func episodes(of podcastId: String, order: EpisodeOrder? = nil) -> [EpisodeItem] {
        let order = order ?? resolved(podcastId).episodeOrder.value
        return snapshot.episodes.values.filter { $0.podcastId == podcastId }
            .sorted { order == .newestFirst ? $0.pubDate > $1.pubDate : $0.pubDate < $1.pubDate }
            .compactMap { item($0.id) }
    }

    public func latestPubDate(_ podcastId: String) -> Millis? {
        snapshot.episodes.values.filter { $0.podcastId == podcastId }.map(\.pubDate).max()
    }

    public func latestEpisode(of podcastId: String) -> EpisodeItem? {
        episodes(of: podcastId, order: .newestFirst).first
    }

    public func unplayedCount(_ podcastId: String) -> Int {
        snapshot.episodes.values.filter { $0.podcastId == podcastId && !snapshot.state($0.id).played && !snapshot.state($0.id).archived }.count
    }

    /// "3 a week", "Weekly", "Daily"… from the last 30 days of episodes.
    public func cadence(_ podcastId: String) -> String? {
        let month = nowMillis - 30 * 86_400_000
        let recent = snapshot.episodes.values.filter { $0.podcastId == podcastId && $0.pubDate >= month }.count
        switch recent {
        case 0: return nil
        case 1: return "Monthly"
        case 2...3: return "Every 2 weeks"
        case 4...6: return "Weekly"
        case 7...25: return "\(Int((Double(recent) / 30 * 7).rounded())) a week"
        default: return "Daily"
        }
    }

    public func isFollowing(feedURL: String) -> Bool {
        snapshot.podcasts.values.contains { $0.feedURL == feedURL && $0.subscribed }
    }

    public func podcastId(feedURL: String) -> String? {
        snapshot.podcasts.values.first { $0.feedURL == feedURL }?.id
    }

    // MARK: - Queue actions

    public func playNext(_ episodeId: String) { perform(.enqueue(episodeId: episodeId, position: .next)) }
    public func queueLast(_ episodeId: String) { perform(.enqueue(episodeId: episodeId, position: .last)) }
    public func moveToTop(_ episodeId: String) { perform(.enqueue(episodeId: episodeId, position: .top)) }
    public func moveToBottom(_ episodeId: String) { perform(.enqueue(episodeId: episodeId, position: .last)) }
    public func removeFromQueue(_ episodeId: String) { perform(.removeFromQueue(episodeId: episodeId)) }
    public func clearQueue(keeping: String?) { perform(.clearQueue(keeping: keeping)) }

    /// Moves within a displayed slice of the queue (Up Next hides the playing item, so `ids`
    /// may not start at the head).
    public func moveQueue(ids: [String], from source: IndexSet, to destination: Int) {
        var moved = ids
        moved.moveElements(fromOffsets: source, toOffset: destination)
        let full = snapshot.queue.map(\.episodeId)
        let firstShown = ids.first.flatMap { full.firstIndex(of: $0) } ?? 0
        let leadIn = firstShown > 0 ? full[firstShown - 1] : nil
        for id in source.map({ ids[$0] }) {
            guard let i = moved.firstIndex(of: id) else { continue }
            let after = i > 0 ? moved[i - 1] : leadIn
            let before = i + 1 < moved.count ? moved[i + 1] : nil
            perform(.moveQueueItem(episodeId: id, after: after, before: before))
        }
    }

    // MARK: - Episode actions

    public func archive(_ episodeId: String) { perform(.setArchived(episodeId: episodeId, true)) }
    public func unarchive(_ episodeId: String) { perform(.setArchived(episodeId: episodeId, false)) }
    public func markPlayed(_ episodeId: String) { perform(.setPlayed(episodeId: episodeId, true)) }
    public func markUnplayed(_ episodeId: String) { perform(.setPlayed(episodeId: episodeId, false)) }
    public func setStarred(_ episodeId: String, _ starred: Bool) { perform(.setStarred(episodeId: episodeId, starred)) }
    public func toggleStar(_ episodeId: String) { setStarred(episodeId, !snapshot.state(episodeId).isStarred) }
    public func markOlderPlayed(_ episodeId: String) { perform(.markOlderPlayed(episodeId: episodeId)) }
    public func archiveOlder(_ episodeId: String) { perform(.archiveOlder(episodeId: episodeId)) }
    public func markAllPlayed(_ podcastId: String) { perform(.markAllPlayed(podcastId: podcastId)) }

    public func savePosition(_ episodeId: String, _ position: Double) {
        perform(.savePosition(episodeId: episodeId, position: position, device: deviceId))
    }

    // MARK: - Library actions

    public func subscribe(_ result: SearchResult) { perform(.subscribe(SubscribeRequest(result))) }
    public func subscribe(feedURL: String, isPrivate: Bool = false) {
        perform(.subscribe(SubscribeRequest(feedURL: feedURL, isPrivate: isPrivate)))
    }
    public func unsubscribe(_ podcastId: String) { perform(.unsubscribe(podcastId: podcastId)) }

    // MARK: - Settings actions

    public func defaultSpeedScope(for podcastId: String) -> SpeedScope {
        SpeedScope.defaultScope(podcastId: podcastId, override: snapshot.podcastSettings[podcastId])
    }

    public func setSpeed(_ value: Double, scope: SpeedScope) { perform(.setSpeed(value, scope: scope)) }

    /// Clears the show's own speed, or puts the global default back to 1.0×.
    public func resetSpeed(scope: SpeedScope) {
        switch scope {
        case .allPodcasts: perform(.setSpeed(GlobalSettings.defaults.speed, scope: .allPodcasts))
        case let .show(id): updateSettings(id) { $0.speed = nil }
        }
    }

    public func updateSettings(_ podcastId: String, _ change: (inout PodcastSettings) -> Void) {
        var s = settings(for: podcastId)
        change(&s)
        perform(.updatePodcastSettings(s))
    }

    public func updateGlobal(_ change: (inout GlobalSettings) -> Void) {
        var g = snapshot.global
        change(&g)
        perform(.updateGlobalSettings(g))
    }

    // MARK: - Downloads (device only)

    public func download(_ episodeId: String) {
        guard downloads[episodeId]?.state != .done else { return }
        downloads[episodeId] = Download(episodeId: episodeId, state: .downloading, progress: 0)
        // TODO(playback wiring): hand this to the real background URLSession downloader.
        tasks.append(Task { [weak self] in
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, self.downloads[episodeId] != nil else { return }
                self.downloads[episodeId]?.progress = Double(step) / 10
            }
            self?.downloads[episodeId]?.state = .done
        })
    }

    public func removeDownload(_ episodeId: String) { downloads[episodeId] = nil }

    // MARK: - Backend reads

    public func loadStats(year: Int) async {
        do {
            if years.isEmpty { years = try await dataSource.availableYears() }
            stats = try await dataSource.stats(year: year)
        } catch { lastError = error.localizedDescription }
    }

    public func loadYearInReview(year: Int) async {
        do { yearInReview = try await dataSource.yearInReview(year: year) } catch { lastError = error.localizedDescription }
    }

    public func search(_ term: String) async throws -> SearchResponse { try await dataSource.search(term) }
    public func resolve(url: String) async throws -> SearchResult? { try await dataSource.resolve(url: url) }

    public func chapters(for episodeId: String) async -> [Chapter] {
        if let cached = chapterCache[episodeId] { return cached }
        guard let ep = episode(episodeId) else { return [] }
        let chapters = await dataSource.chapters(for: ep)
        chapterCache[episodeId] = chapters
        return chapters
    }

    public func cachedChapters(_ episodeId: String) -> [Chapter] { chapterCache[episodeId] ?? [] }

    // MARK: - Overcast import

    public func startImport(fileName: String, data: Data, assumedSpeed: Double) {
        importProgress = ImportProgress(phase: .reading, fileName: fileName, importedAt: nowMillis)
        let source = dataSource
        tasks.append(Task { [weak self] in
            do {
                for try await progress in await source.importOvercast(fileName: fileName, data: data, assumedSpeed: assumedSpeed) {
                    self?.importProgress = progress
                }
            } catch {
                self?.importProgress?.phase = .failed
                self?.importProgress?.message = error.localizedDescription
            }
        })
    }

    public func resetImport() { importProgress = nil }
}

extension Array {
    /// Same as SwiftUI's `move(fromOffsets:toOffset:)`, without needing SwiftUI.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let items = source.map { self[$0] }
        let target = destination - source.count { $0 < destination }
        for i in source.sorted(by: >) { remove(at: i) }
        insert(contentsOf: items, at: target)
    }
}
