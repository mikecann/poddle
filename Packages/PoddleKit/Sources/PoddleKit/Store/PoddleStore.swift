import Foundation
import Observation

/// The app's model. Holds the local copy of everything synced plus device-local state, answers
/// every query the screens make, and turns user actions into mutations: applied locally straight
/// away, then sent to the data source in order.
@MainActor
@Observable
public final class PoddleStore {
    public private(set) var snapshot: LibrarySnapshot {
        didSet { byPodcastCache = nil }
    }
    /// Sample downloads for previews and screenshots. Real ones come from `downloader`.
    private var fakeDownloads: [String: Download]
    /// The background downloader. Nil in previews and tests, which fake downloads instead.
    public var downloader: DownloadManager?
    /// Every download. Maps all of them, so rows should use `download(for:)`.
    public var downloads: [String: Download] {
        let all = downloader?.downloads ?? fakeDownloads
        return pendingDownloadRemovals.isEmpty ? all : all.filter { !pendingDownloadRemovals.contains($0.key) }
    }
    /// Downloads the user removed while the Undo toast is up. They look gone, but the file is only
    /// deleted once the toast expires (`commitDownloadRemoval`).
    public internal(set) var pendingDownloadRemovals: Set<String> = []
    /// Live progress for fake downloads, like `DownloadManager.progress(for:)`.
    @ObservationIgnored private var fakeProgress: [String: DownloadProgress] = [:]
    public private(set) var chapterCache: [String: [Chapter]] = [:]

    public private(set) var stats: StatsSummary?
    /// Goes up whenever someone signs in or out (`resetForAccountChange`). Screens that load
    /// per-person data in a `.task` key it on this, so they load again for the new person
    /// instead of keeping the cleared value (Stats used to sit on "Counting up…" after signing in).
    public private(set) var accountGeneration = 0
    public private(set) var years: [Int] = []
    public private(set) var yearInReview: YearInReview?
    public private(set) var importProgress: ImportProgress?
    public private(set) var lastError: String?
    /// Mutations sent but not yet acknowledged.
    public private(set) var pending: [Mutation] = []
    /// Live backend health. Nil for the mock.
    public private(set) var connection: ConnectionStatus?
    /// Full show notes fetched on demand (the synced episodes only carry a summary).
    public private(set) var showNotes: [String: String] = [:]

    public let deviceId: String

    @ObservationIgnored public let dataSource: any PoddleDataSource
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored private var outbox: AsyncStream<Mutation>.Continuation?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var byPodcastCache: [String: [Episode]]?

    public init(
        dataSource: any PoddleDataSource, seed: LibrarySnapshot = .init(), downloads: [String: Download] = [:],
        deviceId: String = "this-device", sync: Bool = true
    ) {
        self.dataSource = dataSource
        self.snapshot = seed
        self.fakeDownloads = downloads
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
        tasks.append(Task { [weak self] in
            for await status in await source.connectionStatus() {
                guard let self else { return }
                if self.connection != status { self.connection = status }
            }
        })
    }

    /// Episodes grouped by show, rebuilt only when the snapshot changes (the live library has
    /// thousands of episodes, and the library grid asks per show).
    private var byPodcast: [String: [Episode]] {
        if let byPodcastCache { return byPodcastCache }
        let grouped = Dictionary(grouping: snapshot.episodes.values, by: \.podcastId)
        byPodcastCache = grouped
        return grouped
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

    /// One episode's download, as rows show it.
    public func download(for episodeId: String) -> Download? {
        if pendingDownloadRemovals.contains(episodeId) { return nil }
        if let downloader { return downloader.download(for: episodeId) }
        return fakeDownloads[episodeId]
    }

    /// Live download progress. Only small leaf views should read it, so progress ticks don't
    /// rebuild rows and lists.
    public func downloadProgress(_ episodeId: String) -> DownloadProgress? {
        if let downloader { return downloader.progress(for: episodeId) }
        guard let d = fakeDownloads[episodeId] else { return nil }
        if let p = fakeProgress[episodeId] { return p }
        let p = DownloadProgress(fraction: d.progress)
        fakeProgress[episodeId] = p
        return p
    }

    public func item(_ episodeId: String) -> EpisodeItem? {
        item(episodeId, isQueued: snapshot.isQueued(episodeId))
    }

    /// `isQueued` passed in, because `snapshot.isQueued` scans the whole queue.
    private func item(_ episodeId: String, isQueued: Bool) -> EpisodeItem? {
        guard let ep = snapshot.episodes[episodeId], let pod = snapshot.podcasts[ep.podcastId] else { return nil }
        return EpisodeItem(
            episode: ep, podcast: pod, state: snapshot.state(episodeId), isQueued: isQueued,
            speed: snapshot.resolved(pod.id).speed, download: download(for: episodeId)
        )
    }

    private var queuedIds: Set<String> { Set(snapshot.queue.map(\.episodeId)) }

    /// The whole queue in order. The head is what's playing (or plays next).
    public var queue: [EpisodeItem] { snapshot.queue.compactMap { item($0.episodeId, isQueued: true) } }

    /// The Up Next list: the queue minus whatever's loaded in the player.
    public func upNext(excluding current: String?) -> [EpisodeItem] {
        queue.filter { $0.id != current }
    }

    /// Wall-clock time to get through these at each show's own speed.
    public func wallTime(_ items: [EpisodeItem]) -> Double { items.reduce(0) { $0 + $1.wallRemaining } }

    /// New episodes waiting for a decision, newest first.
    public var inbox: [EpisodeItem] {
        let queued = queuedIds
        return snapshot.states.values
            .filter { $0.inboxAt != nil && !$0.archived && !$0.played && !queued.contains($0.episodeId) }
            .compactMap { item($0.episodeId, isQueued: false) }
            .filter { $0.podcast.subscribed }
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
    }

    /// Subscribed shows, most recently updated first.
    public var library: [Podcast] {
        snapshot.podcasts.values.filter(\.subscribed)
            .sorted { (latestPubDate($0.id) ?? 0) > (latestPubDate($1.id) ?? 0) }
    }

    /// Unsubscribed shows that still have history, so imported history isn't orphaned. The server
    /// says which (their episodes aren't synced, so an imported show's history isn't here), plus
    /// any just unsubscribed here with history on this device.
    public var pastShows: [Podcast] {
        let byPodcast = byPodcast
        let fromServer = snapshot.pastShowIds ?? []
        return snapshot.podcasts.values.filter { p in
            !p.subscribed && (fromServer.contains(p.id)
                || (byPodcast[p.id] ?? []).contains { snapshot.states[$0.id].map { $0.played || $0.position > 1 || $0.isStarred } ?? false })
        }.sorted { $0.title < $1.title }
    }

    public func episodes(of podcastId: String, order: EpisodeOrder? = nil) -> [EpisodeItem] {
        let order = order ?? resolved(podcastId).episodeOrder.value
        let queued = queuedIds
        return (byPodcast[podcastId] ?? [])
            .sorted { order == .newestFirst ? $0.pubDate > $1.pubDate : $0.pubDate < $1.pubDate }
            .compactMap { item($0.id, isQueued: queued.contains($0.id)) }
    }

    public func latestPubDate(_ podcastId: String) -> Millis? {
        byPodcast[podcastId]?.map(\.pubDate).max()
    }

    public func latestEpisode(of podcastId: String) -> EpisodeItem? {
        episodes(of: podcastId, order: .newestFirst).first
    }

    public func unplayedCount(_ podcastId: String) -> Int {
        (byPodcast[podcastId] ?? []).count { !snapshot.state($0.id).played && !snapshot.state($0.id).archived }
    }

    /// "3 a week", "Weekly", "Daily"… from the last 30 days of episodes.
    public func cadence(_ podcastId: String) -> String? {
        let month = nowMillis - 30 * 86_400_000
        let recent = (byPodcast[podcastId] ?? []).count { $0.pubDate >= month }
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

    public func subscribe(_ result: SearchResult, isPrivate: Bool = false) {
        var request = SubscribeRequest(result)
        request.isPrivate = isPrivate
        perform(.subscribe(request))
    }
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

    /// Download one episode. Over mobile data in Wi-Fi-only mode this returns `.needsMobilePrompt`
    /// and the UI asks (see `resolveMobilePrompt`).
    @discardableResult
    public func download(_ episodeId: String) -> DownloadManager.RequestResult {
        guard download(for: episodeId)?.state != .done else { return .alreadyDownloaded }
        if let downloader {
            guard let url = episode(episodeId).flatMap({ URL(string: $0.enclosureURL) }) else { return .started }
            return downloader.request(episodeId, url: url)
        }
        fakeDownloads[episodeId] = Download(episodeId: episodeId, state: .downloading, progress: 0)
        fakeProgress[episodeId] = DownloadProgress(fraction: 0)
        tasks.append(Task { [weak self] in
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, self.fakeDownloads[episodeId] != nil else { return }
                self.fakeProgress[episodeId]?.setFraction(Double(step) / 10)
            }
            self?.fakeDownloads[episodeId]?.progress = 1
            self?.fakeDownloads[episodeId]?.state = .done
        })
        return .started
    }

    public func resolveMobilePrompt(_ choice: MobilePromptChoice, episodeId: String) {
        guard let downloader, let url = episode(episodeId).flatMap({ URL(string: $0.enclosureURL) }) else { return }
        downloader.resolvePrompt(choice, episodeId: episodeId, url: url)
    }

    public func removeDownload(_ episodeId: String) {
        if let downloader { downloader.remove(episodeId) } else {
            fakeDownloads[episodeId] = nil
            fakeProgress[episodeId] = nil
        }
    }

    /// Auto-downloads and cleanup: the first Up Next items plus new episodes from priority shows,
    /// then deletes played files, extras beyond each show's "keep latest" and anything over the cap.
    /// Whether the person's settings are here yet (always, on sample data). Until they are,
    /// the defaults would auto-download for someone who's turned it off.
    public var settingsReady: Bool { dataSource is MockStore || snapshot.settingsSynced == true }

    public func runDownloadHousekeeping(playing: String?) {
        guard let downloader, settingsReady else { return }
        let g = global
        func candidate(_ id: String) -> DownloadPlanner.Candidate? {
            guard let ep = episode(id) else { return nil }
            let st = snapshot.state(id)
            return .init(episodeId: id, podcastId: ep.podcastId, pubDate: ep.pubDate, played: st.played,
                         archived: st.archived, hasEnclosure: !ep.enclosureURL.isEmpty && !ep.isGhost)
        }
        let queueIds = snapshot.queue.map(\.episodeId)
        let subscribed = snapshot.episodes.values.filter { snapshot.podcasts[$0.podcastId]?.subscribed == true }
        let capBytes = Int64(g.storageCapGB * 1_073_741_824)

        let wanted = DownloadPlanner.autoDownloads(
            queue: queueIds.compactMap(candidate), episodes: subscribed.compactMap { candidate($0.id) },
            autoDownload: { self.resolved($0).autoDownload.value }, isPriority: { self.resolved($0).isPriority },
            keepLatest: { self.resolved($0).keepLatest.value }, now: nowMillis)
        downloader.setOrder(queueIds)
        let used = downloader.storageUsed
        for id in wanted where downloader.download(for: id) == nil && used < capBytes {
            guard let url = episode(id).flatMap({ URL(string: $0.enclosureURL) }) else { continue }
            downloader.request(id, url: url, auto: true)
        }

        let files = downloader.downloadedFiles.compactMap { f -> DownloadedFile? in
            guard let ep = episode(f.episodeId) else { return nil }
            let st = snapshot.state(f.episodeId)
            return DownloadedFile(episodeId: f.episodeId, podcastId: ep.podcastId, bytes: f.bytes, pubDate: ep.pubDate,
                                  playedAt: st.played ? (st.playedAt ?? st.updatedAt) : nil)
        }
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: queueIds, playing: playing, keepLatest: { self.resolved($0).keepLatest.value },
            deletePlayedAfter: g.deletePlayed.interval, capBytes: capBytes, now: nowMillis)
        for id in doomed { downloader.remove(id) }
    }

    // MARK: - Backend reads

    /// Keeps `stats` live for a year until the calling task (the Stats screen) is cancelled.
    public func loadStats(year: Int) async {
        let source = dataSource
        let yearsTask = Task { [weak self] in
            guard let years = try? await source.availableYears(), let self else { return }
            if self.years != years { self.years = years }
        }
        defer { yearsTask.cancel() }
        if stats?.year != year { stats = nil }
        do {
            for try await s in await source.watchStats(year: year) {
                if stats != s { stats = s }
            }
        } catch { lastError = error.localizedDescription }
    }

    public func loadYearInReview(year: Int) async {
        do {
            for try await r in await dataSource.watchYearInReview(year: year) where yearInReview != r { yearInReview = r }
        } catch { lastError = error.localizedDescription }
    }

    /// Pull-to-refresh and app foreground: re-check feeds (one show or all) and catch up.
    public func refresh(podcastId: String? = nil) async {
        do { try await dataSource.refresh(podcastId: podcastId) } catch { lastError = error.localizedDescription }
    }

    /// Keeps a podcast page live while it's on screen.
    public func observePodcast(_ podcastId: String) async { await dataSource.observePodcast(podcastId) }

    /// A shared link's episode or show, fetched if it isn't in the store yet (it may not be in the
    /// library at all). False if it can't be found, e.g. a private feed's or a deleted one.
    public func loadShared(_ target: ShareLinks.Target) async -> Bool {
        let loaded = {
            switch target {
            case let .episode(id, _): self.item(id) != nil
            case let .show(id): self.podcast(id).map { !$0.feedURL.isEmpty } ?? false
            }
        }
        if loaded() { return true }
        guard await dataSource.loadShared(target) else { return false }
        // The snapshot arrives through the data source's stream a moment later.
        for _ in 0..<30 where !loaded() { try? await Task.sleep(for: .milliseconds(100)) }
        return loaded()
    }

    public func loadShowNotes(_ episodeId: String) async {
        guard showNotes[episodeId] == nil, let html = await dataSource.showNotes(episodeId: episodeId), !html.isEmpty else { return }
        showNotes[episodeId] = html
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

    /// Someone else signed in (or out): drop everything that was the last person's. The data
    /// source pushes the new person's snapshot straight after.
    public func resetForAccountChange(seed: LibrarySnapshot = .init()) {
        accountGeneration += 1
        pending = []
        snapshot = seed
        stats = nil
        years = []
        yearInReview = nil
        importProgress = nil
        lastError = nil
        showNotes = [:]
    }
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
