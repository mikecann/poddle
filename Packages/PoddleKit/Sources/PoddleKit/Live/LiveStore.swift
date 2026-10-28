import Foundation

/// The Convex-backed data source (docs/api.md).
///
/// - Reads: live subscriptions for what the screens show (`podcasts:list`, `queue:upNext`,
///   `episodes:inbox`, `settings:getGlobal`, a podcast page's episodes), merged into one
///   `LibrarySnapshot`. `sync:changes` catches up on everything else after a relaunch or a
///   reconnect, following the API's offline contract.
/// - Writes: `send(_:)` turns each `Mutation` into backend calls stamped with the device time and
///   appends them to a persisted outbox, which drains in order. Network and auth errors keep the
///   entry and retry; an outright rejection moves it to `failed`, which is kept too.
/// - Snapshots pushed to the store are the server state with every queued action applied on top,
///   so the app looks right offline and across relaunches.
/// - Everything is cached as JSON under Application Support, per deployment and per person.
///   Calls are made as the signed-in person (`switchAccount`); signed out, nothing is synced or
///   sent and the snapshot is empty.
public actor LiveStore: PoddleDataSource {
    public struct Timing: Sendable {
        public var retry: Duration
        public var maxRetry: Duration
        public var saveDelay: Duration
        public var emitDelay: Duration
        public var resyncEvery: Duration
        public init(retry: Duration, maxRetry: Duration, saveDelay: Duration, emitDelay: Duration, resyncEvery: Duration) {
            self.retry = retry; self.maxRetry = maxRetry; self.saveDelay = saveDelay
            self.emitDelay = emitDelay; self.resyncEvery = resyncEvery
        }
        public static let standard = Timing(retry: .seconds(1), maxRetry: .seconds(60), saveDelay: .seconds(1), emitDelay: .milliseconds(120), resyncEvery: .seconds(300))
        public static let fast = Timing(retry: .milliseconds(5), maxRetry: .milliseconds(20), saveDelay: .zero, emitDelay: .zero, resyncEvery: .seconds(3600))
    }

    /// Tables mirrored locally. Show notes, sessions and events stay on the server.
    static let syncTables = ["podcasts", "podcastSettings", "globalSettings", "episodes", "episodeStates", "queueItems", "deletions"]
    static let syncPageSize = 250.0
    /// Tombstones live 90 days; offline longer than this and a table resyncs from scratch.
    static let tombstoneWindow: Millis = 89 * 86_400_000

    public private(set) var deploymentURL: URL
    /// Who's signed in. The cache, outbox and every call are theirs.
    public private(set) var userId: String?
    private var auth: (any AuthTokenSource)?
    public nonisolated let deviceId: String
    private let makeTransport: @Sendable (URL) -> any ConvexTransport
    private let makeDisk: @Sendable (URL, String) -> LiveDisk
    private var transport: any ConvexTransport
    /// Nil while signed out: nothing is read or written.
    private var disk: LiveDisk?
    /// The transport hasn't been given `auth` yet.
    private var authPending = true
    private let timing: Timing
    private let now: @Sendable () -> Date

    private var cache: LiveCache
    private var outbox: OutboxFile
    /// Accepted by the server but maybe not visible in what we've synced yet. Kept on top of the
    /// server state until the next catch-up, so the UI doesn't flicker back.
    private var confirmed: [OutboxEntry] = []
    /// Once `queue:upNext` has answered, it owns the queue and catch-up leaves it alone.
    private var liveQueue = false
    private var liveGlobal = false

    private var listeners: [UUID: AsyncStream<LibrarySnapshot>.Continuation] = [:]
    private var statusListeners: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]
    private var connected = false
    private var lastError: String?
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var draining = false
    private var syncing = false
    private var emitPending = false
    private var savePending = false
    /// Bumped by `switchAccount` so work started for the previous person stops writing.
    private var generation = 0

    /// - Parameters:
    ///   - userId: who's signed in (nil: nobody yet). Their cache and outbox load straight away,
    ///     so an offline launch works; calls wait for `auth`.
    ///   - auth: hands the Convex client access tokens (`Account`).
    public init(
        deploymentURL: URL, deviceId: String, userId: String?, auth: (any AuthTokenSource)?,
        transport: (@Sendable (URL) -> any ConvexTransport)? = nil,
        disk: (@Sendable (URL, String) -> LiveDisk)? = nil,
        timing: Timing = .standard, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let makeTransport = transport ?? { ConvexMobileTransport(deploymentURL: $0) }
        let makeDisk = disk ?? { LiveDisk.forUser($1, deployment: $0) }
        self.deploymentURL = deploymentURL
        self.userId = userId
        self.auth = auth
        self.deviceId = deviceId
        self.makeTransport = makeTransport
        self.makeDisk = makeDisk
        self.transport = makeTransport(deploymentURL)
        let disk = userId.map { makeDisk(deploymentURL, $0) }
        self.disk = disk
        self.timing = timing
        self.now = now
        self.cache = disk?.loadCache() ?? LiveCache()
        self.outbox = disk?.loadOutbox() ?? OutboxFile()
    }

    /// Someone signed in, or out. Everything stops, the next person's cache and outbox load (or
    /// nothing, signed out), and syncing starts again as them. The previous person's files stay on
    /// disk for when they sign back in.
    public func switchAccount(userId: String?, auth: (any AuthTokenSource)?) {
        stop()
        self.userId = userId
        self.auth = auth
        disk = userId.map { makeDisk(deploymentURL, $0) }
        cache = disk?.loadCache() ?? LiveCache()
        outbox = disk?.loadOutbox() ?? OutboxFile()
        confirmed = []
        liveQueue = false
        liveGlobal = false
        transport = makeTransport(deploymentURL)
        authPending = true
        connected = false
        lastError = nil
        if !listeners.isEmpty { startIfNeeded() }
        changed(save: false)
    }

    /// What to paint on launch before the network answers: the cached server state with any
    /// queued actions applied on top. Empty when nobody's signed in.
    public static func cachedSnapshot(disk: LiveDisk?) -> LibrarySnapshot {
        guard let disk else { return LibrarySnapshot() }
        let cache = disk.loadCache() ?? LiveCache()
        return overlay(cache.snapshot, disk.loadOutbox().pending)
    }

    static func overlay(_ base: LibrarySnapshot, _ entries: [OutboxEntry]) -> LibrarySnapshot {
        var s = base
        for e in entries { s.apply(e.mutation, now: e.at, newId: { "local-" + e.id.uuidString }) }
        return s
    }

    private var nowMillis: Millis { now().timeIntervalSince1970 * 1000 }

    private func current() -> LibrarySnapshot { Self.overlay(cache.snapshot, confirmed + outbox.pending) }

    // MARK: - Lifecycle

    private func startIfNeeded() {
        guard !started, userId != nil else { return }
        started = true
        let gen = generation
        if authPending {
            authPending = false
            let transport = transport
            let auth = auth
            tasks.append(Task { await transport.setAuth(auth) })
        }
        let states = transport.connectionStates()
        tasks.append(Task { [weak self] in
            for await up in states {
                guard let self else { return }
                await self.connectionChanged(up, gen: gen)
            }
        })
        for feed in [Feed.library, .pastShows, .upNext, .inbox, .global] {
            let stream = resilient(feed.name, feed.args)
            tasks.append(Task { [weak self] in
                for await data in stream {
                    guard let self else { return }
                    await self.merge(feed, data, gen: gen)
                }
            })
        }
        let every = timing.resyncEvery
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let self, !Task.isCancelled else { return }
                await self.catchUp()
            }
        })
        kickDrain()
    }

    private func connectionChanged(_ up: Bool, gen: Int) {
        guard gen == generation else { return }
        let wasUp = connected
        connected = up
        publishStatus()
        if up && !wasUp {
            kickDrain()
            Task { await self.catchUp() }
        }
    }

    /// Cancels everything in flight. The outbox and cache stay on disk.
    public func stop() {
        for t in tasks { t.cancel() }
        tasks = []
        started = false
        generation += 1
        draining = false
        syncing = false
        saveNow()
    }

    /// Writes the cache now (on backgrounding, and in tests).
    public func flush() { saveNow() }

    // MARK: - Snapshots and status

    public func snapshots() async -> AsyncStream<LibrarySnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: LibrarySnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        continuation.yield(current())
        startIfNeeded()
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    public func connectionStatus() async -> AsyncStream<ConnectionStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        statusListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeStatusListener(id) } }
        continuation.yield(status)
        return stream
    }

    private func removeStatusListener(_ id: UUID) { statusListeners[id] = nil }

    public var status: ConnectionStatus {
        ConnectionStatus(
            deploymentURL: deploymentURL, connected: connected, pending: outbox.pending.count,
            failed: outbox.failed.count, lastSyncAt: cache.syncedAt, error: lastError
        )
    }

    public var pendingEntries: [OutboxEntry] { outbox.pending }
    public var failedEntries: [OutboxEntry] { outbox.failed }
    public var cachedState: LiveCache { cache }

    private func publishStatus() {
        let s = status
        for l in statusListeners.values { l.yield(s) }
    }

    private func changed(save: Bool = true) {
        if save { scheduleSave() }
        publishStatus()
        guard !emitPending else { return }
        emitPending = true
        let delay = timing.emitDelay
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            self.emitNow()
        }
    }

    private func emitNow() {
        emitPending = false
        let s = current()
        for l in listeners.values { l.yield(s) }
    }

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        let delay = timing.saveDelay
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            self.saveNow()
        }
    }

    private func saveNow() {
        savePending = false
        guard let disk else { return }
        do { try disk.save(cache) } catch { lastError = "Couldn't save the cache: \(error.localizedDescription)" }
    }

    private func saveOutbox() {
        guard let disk else { return }
        do { try disk.save(outbox) } catch { lastError = "Couldn't save the outbox: \(error.localizedDescription)" }
    }

    private func note(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        publishStatus()
    }

    // MARK: - Live queries

    enum Feed: Sendable {
        case library, pastShows, upNext, inbox, global
        case podcastEpisodes(String), podcastSettings(String)

        var name: String {
            switch self {
            case .library: "podcasts:list"
            case .pastShows: "podcasts:pastShows"
            case .upNext: "queue:upNext"
            case .inbox: "episodes:inbox"
            case .global: "settings:getGlobal"
            case .podcastEpisodes: "podcasts:episodes"
            case .podcastSettings: "settings:forPodcast"
            }
        }

        var args: [String: JSONValue] {
            switch self {
            case let .podcastEpisodes(id):
                ["podcastId": .string(id), "order": "newestFirst", "paginationOpts": ["numItems": 100, "cursor": nil]]
            case let .podcastSettings(id): ["podcastId": .string(id)]
            default: [:]
            }
        }
    }

    /// A subscription that survives errors and drops: it resubscribes with backoff until the
    /// consumer goes away.
    private func resilient(_ name: String, _ args: [String: JSONValue]) -> AsyncStream<Data> {
        let transport = transport
        let full = args
        let timing = timing
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task { [weak self] in
            var delay = timing.retry
            while !Task.isCancelled {
                do {
                    for try await data in transport.subscribe(name, full) {
                        continuation.yield(data)
                        delay = timing.retry
                    }
                } catch {
                    await self?.note(error)
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, timing.maxRetry)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func merge(_ feed: Feed, _ data: Data, gen: Int) {
        guard gen == generation else { return }
        let d = JSONDecoder()
        do {
            switch feed {
            case .library:
                let pods = try d.decode([PodcastDoc].self, from: data)
                let ids = Set(pods.map(\._id))
                for p in pods { cache.snapshot.podcasts[p._id] = p.model }
                for (id, p) in cache.snapshot.podcasts where p.subscribed && !ids.contains(id) {
                    cache.snapshot.podcasts[id]?.subscribed = false
                }
            case .pastShows:
                let pods = try d.decode([PodcastDoc].self, from: data)
                for p in pods { cache.snapshot.podcasts[p._id] = p.model }
                cache.snapshot.pastShowIds = Set(pods.map(\._id))
            case .upNext:
                let entries = try d.decode([UpNextEntryDoc].self, from: data)
                for e in entries { upsert(e.row) }
                cache.snapshot.queue = entries.map(\.item.model).sorted { $0.orderKey < $1.orderKey }
                liveQueue = true
            case .inbox:
                let rows = try d.decode([EpisodeRowDoc].self, from: data)
                for r in rows { upsert(r) }
                // The query caps at 500; below that, anything not in it has left the Inbox.
                if rows.count < 500 {
                    let ids = Set(rows.map(\.episode._id))
                    for (id, s) in cache.snapshot.states where s.inboxAt != nil && !ids.contains(id) {
                        cache.snapshot.states[id]?.inboxAt = nil
                    }
                }
            case .global:
                cache.snapshot.global = SettingsMapping.global(try d.decode([String: JSONValue].self, from: data))
                cache.snapshot.settingsSynced = true
                liveGlobal = true
            case let .podcastEpisodes(podcastId):
                let page = try d.decode(Paginated<EpisodeRowDoc>.self, from: data)
                for r in page.page where r.episode.podcastId == podcastId { upsert(r) }
            case let .podcastSettings(podcastId):
                let o = try d.decode(PodcastSettingsResponse.self, from: data).overrides
                let s = SettingsMapping.podcast(podcastId, o)
                cache.snapshot.podcastSettings[podcastId] = s.hasOverrides ? s : nil
            }
            if lastError != nil { lastError = nil }
            changed()
        } catch {
            note(error)
        }
    }

    private func upsert(_ row: EpisodeRowDoc) {
        let ep = row.episode
        cache.snapshot.episodes[ep._id] = ep.model
        if let s = row.state { upsert(s) } else { cache.snapshot.states[ep._id] = nil }
        if cache.snapshot.podcasts[row.podcast._id] == nil {
            let p = row.podcast
            cache.snapshot.podcasts[p._id] = Podcast(
                id: p._id, feedURL: "", isPrivate: p.isPrivate, title: p.title, author: p.author ?? "",
                artworkURL: p.artworkUrl, subscribed: false
            )
        }
    }

    private func upsert(_ s: EpisodeStateDoc) {
        if let old = cache.snapshot.states[s.episodeId], old.updatedAt > s.updatedAt { return }
        cache.snapshot.states[s.episodeId] = s.model
    }

    // MARK: - Catch-up (sync:changes)

    /// Pages through every synced table changed since the last catch-up and upserts it.
    public func catchUp() async {
        guard !syncing, userId != nil else { return }
        syncing = true
        defer { syncing = false }
        let gen = generation
        let transport = transport
        let fresh = cache.syncedAt.map { nowMillis - $0 > Self.tombstoneWindow } ?? true
        let entriesBefore = Set(confirmed.map(\.id))
        do {
            for table in Self.syncTables {
                let since = fresh ? 0 : cache.since[table] ?? 0
                var cursor: JSONValue = .null
                var maxSeen = since
                while true {
                    let args: [String: JSONValue] = [
                        "table": .string(table), "since": .number(since),
                        "paginationOpts": ["numItems": .number(Self.syncPageSize), "cursor": cursor],
                    ]
                    let data = try await transport.query("sync:changes", args)
                    guard gen == generation else { return }
                    let done = try applySyncPage(table, data, maxSeen: &maxSeen, cursor: &cursor)
                    changed()
                    if done { break }
                }
                cache.since[table] = maxSeen
            }
            cache.syncedAt = nowMillis
            // Whatever was confirmed before this pass started is in the synced state now.
            confirmed.removeAll { entriesBefore.contains($0.id) }
            lastError = nil
            changed()
        } catch {
            if gen == generation { note(error) }
        }
    }

    /// A background wake (a sync push or background app refresh): waits out a pass that's already
    /// running, which `catchUp` would skip, then runs a fresh one. Whatever was on the server
    /// before the call is in the cache when it returns.
    public func syncNow() async {
        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
        await catchUp()
    }

    private struct SyncPageOf<T: Decodable & Sendable>: Decodable, Sendable {
        var page: [T]
        var isDone: Bool
        var continueCursor: String
        var maxUpdatedAt: Double?
    }

    private func applySyncPage(_ table: String, _ data: Data, maxSeen: inout Millis, cursor: inout JSONValue) throws -> Bool {
        func page<T: Decodable & Sendable>(_ type: T.Type) throws -> SyncPageOf<T> {
            let p = try JSONDecoder().decode(SyncPageOf<T>.self, from: data)
            maxSeen = max(maxSeen, p.maxUpdatedAt ?? 0)
            cursor = .string(p.continueCursor)
            return p
        }
        switch table {
        case "podcasts":
            let p = try page(PodcastDoc.self)
            for d in p.page { cache.snapshot.podcasts[d._id] = d.model }
            return p.isDone
        case "episodes":
            let p = try page(EpisodeDoc.self)
            for d in p.page { cache.snapshot.episodes[d._id] = d.model }
            return p.isDone
        case "episodeStates":
            let p = try page(EpisodeStateDoc.self)
            for d in p.page { upsert(d) }
            return p.isDone
        case "queueItems":
            let p = try page(QueueItemDoc.self)
            if !liveQueue {
                for d in p.page {
                    cache.snapshot.queue.removeAll { $0.id == d._id || $0.episodeId == d.episodeId }
                    cache.snapshot.queue.append(d.model)
                }
                cache.snapshot.queue.sort { $0.orderKey < $1.orderKey }
            }
            return p.isDone
        case "podcastSettings":
            let p = try page([String: JSONValue].self)
            for d in p.page {
                guard let id = d["podcastId"]?.string else { continue }
                let s = SettingsMapping.podcast(id, d)
                cache.snapshot.podcastSettings[id] = s.hasOverrides ? s : nil
            }
            return p.isDone
        case "globalSettings":
            let p = try page([String: JSONValue].self)
            if !liveGlobal, let d = p.page.last { cache.snapshot.global = SettingsMapping.global(d) }
            if p.isDone { cache.snapshot.settingsSynced = true }
            return p.isDone
        case "deletions":
            let p = try page(DeletionDoc.self)
            if !liveQueue {
                for d in p.page where d.table == "queueItems" && !d.docId.isEmpty {
                    cache.snapshot.queue.removeAll { $0.id == d.docId }
                }
            }
            return p.isDone
        default:
            return try page(JSONValue.self).isDone
        }
    }

    // MARK: - Outbox

    public func send(_ mutation: Mutation) async throws {
        // Signed out: there's nobody to send it as.
        guard userId != nil else { return }
        let at = nowMillis
        let calls = Self.calls(for: mutation, at: at, base: current(), deviceId: deviceId)
        guard !calls.isEmpty else { return }
        let entry = OutboxEntry(mutation: mutation, at: at, calls: calls)
        // Position saves arrive every few seconds while playing; only the newest one matters.
        if case let .savePosition(episodeId, _, _) = mutation, outbox.pending.count >= 2,
           case let .savePosition(lastId, _, _)? = outbox.pending.last?.mutation, lastId == episodeId {
            outbox.pending[outbox.pending.count - 1] = entry
        } else {
            outbox.pending.append(entry)
        }
        saveOutbox()
        changed(save: false)
        kickDrain()
    }

    /// Queues listening sessions in the outbox and returns once they're on disk, so the caller
    /// (`SessionForwarder`) can forget them: from here the outbox owns retrying, and nothing is
    /// retried twice. The player re-reports an open session every 30 s; a newer copy replaces any
    /// older one still waiting, so a backlog sends each session once, with its latest end.
    public func recordSessions(_ sessions: [SessionInput]) async throws {
        guard !sessions.isEmpty else { return }
        let ids = Set(sessions.map(\.sessionId))
        dropWaiting { m in
            guard case let .recordSessions(old) = m else { return m }
            let left = old.filter { !ids.contains($0.sessionId) }
            return left.isEmpty ? nil : .recordSessions(left)
        }
        try await send(.recordSessions(sessions))
    }

    /// Queues `devices:register` with this device's ID, name and platform. Only the newest token
    /// waiting is sent.
    public func registerDevice(apnsToken: String, environment: APNsEnvironment) async throws {
        dropWaiting { m in
            if case .registerDevice = m { return nil }
            return m
        }
        try await send(.registerDevice(apnsToken: apnsToken, environment: environment))
    }

    /// Rewrites (or with nil, drops) pending entries that haven't been sent yet. The head is left
    /// alone while it may be in flight.
    private func dropWaiting(_ rewrite: (Mutation) -> Mutation?) {
        let first = draining || outbox.pending.first.map({ $0.done > 0 }) == true ? 1 : 0
        guard outbox.pending.count > first else { return }
        var kept = Array(outbox.pending[..<first])
        for var e in outbox.pending[first...] {
            guard let m = rewrite(e.mutation) else { continue }
            if m != e.mutation {
                e.mutation = m
                e.calls = Self.calls(for: m, at: e.at, base: LibrarySnapshot(), deviceId: deviceId)
                if e.calls.isEmpty { continue }
            }
            kept.append(e)
        }
        outbox.pending = kept
    }

    /// Puts rejected actions back in the queue (in their original order, with their original
    /// times).
    public func retryFailed() {
        let again = outbox.failed.map { e -> OutboxEntry in var e = e; e.error = nil; return e }
        outbox.failed = []
        outbox.pending.append(contentsOf: again)
        saveOutbox()
        changed(save: false)
        kickDrain()
    }

    public func discardFailed() {
        outbox.failed = []
        saveOutbox()
        changed(save: false)
    }

    private func kickDrain() {
        guard started, !draining, !outbox.pending.isEmpty else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        let gen = generation
        defer { if gen == generation { draining = false } }
        var delay = timing.retry
        while let head = outbox.pending.first, gen == generation, !Task.isCancelled {
            var entry = head
            do {
                while entry.done < entry.calls.count {
                    let call = entry.calls[entry.done]
                    var args = call.args
                    if let key = call.resultArg {
                        guard let result = entry.lastResult, result != .null else { entry.done += 1; continue }
                        args[key] = result
                    }
                    let data = try await transport.mutation(call.name, args)
                    guard gen == generation else { return }
                    entry.lastResult = try? JSONValue.decode(data)
                    entry.done += 1
                    updateHead(entry)
                }
                finishHead(entry, failed: false)
                delay = timing.retry
                if lastError != nil { lastError = nil; publishStatus() }
            } catch let error as TransportError where !error.isRetryable {
                guard gen == generation else { return }
                entry.error = error.errorDescription
                finishHead(entry, failed: true)
                note(error)
            } catch {
                guard gen == generation else { return }
                entry.attempts += 1
                updateHead(entry)
                note(error)
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, timing.maxRetry)
            }
        }
        if gen == generation, outbox.pending.isEmpty, !confirmed.isEmpty {
            // Pick up the server's view of what we just sent.
            Task { await self.catchUp() }
        }
    }

    private func updateHead(_ entry: OutboxEntry) {
        guard outbox.pending.first?.id == entry.id else { return }
        outbox.pending[0] = entry
        saveOutbox()
    }

    private func finishHead(_ entry: OutboxEntry, failed: Bool) {
        guard outbox.pending.first?.id == entry.id else { return }
        outbox.pending.removeFirst()
        if failed { outbox.failed.append(entry) } else { confirmed.append(entry) }
        saveOutbox()
        changed(save: false)
    }

    /// The backend calls for one user action. `base` is the state just before it, for the
    /// actions whose API shape needs context (settings patches, clearing the queue).
    static func calls(for m: Mutation, at: Millis, base: LibrarySnapshot, deviceId: String) -> [OutboxCall] {
        let at = JSONValue.number(at)
        func isLocal(_ id: String) -> Bool { id.hasPrefix("local-") }
        switch m {
        case let .enqueue(episodeId, position):
            let pos: JSONValue = switch position {
            case .top: "top"
            case .next: "next"
            case .last: "bottom"
            }
            return [OutboxCall("queue:add", ["episodeId": .string(episodeId), "position": pos, "at": at])]

        case let .moveQueueItem(episodeId, after, before):
            return [OutboxCall("queue:move", [
                "episodeId": .string(episodeId), "afterEpisodeId": JSONValue(after), "beforeEpisodeId": JSONValue(before), "at": at,
            ])]

        case let .removeFromQueue(episodeId):
            return [OutboxCall("queue:remove", ["episodeId": .string(episodeId), "at": at])]

        case let .clearQueue(keeping):
            // Remove exactly what the user saw, rather than `queue:clear`, which would also take
            // the playing item.
            return base.queue.filter { $0.episodeId != keeping }.map {
                OutboxCall("queue:remove", ["episodeId": .string($0.episodeId), "at": at])
            }

        case let .setArchived(episodeId, archived):
            var calls = [OutboxCall("episodes:setArchivedState", ["episodeId": .string(episodeId), "archived": .bool(archived), "at": at])]
            // Locally, archiving also takes it out of Up Next; the server leaves the queue alone.
            if archived && base.isQueued(episodeId) {
                calls.append(OutboxCall("queue:remove", ["episodeId": .string(episodeId), "at": at]))
            }
            return calls

        case let .setPlayed(episodeId, played):
            return [OutboxCall("episodes:setPlayedState", ["episodeId": .string(episodeId), "played": .bool(played), "at": at])]

        case let .setStarred(episodeId, starred):
            return [OutboxCall("episodes:setStarredState", ["episodeId": .string(episodeId), "starred": .bool(starred), "at": at])]

        case let .savePosition(episodeId, position, _):
            return [OutboxCall("episodes:updatePosition", [
                "episodeId": .string(episodeId), "position": .number(max(0, position)), "positionUpdatedAt": at,
                "deviceId": .string(deviceId),
            ])]

        case let .markOlderPlayed(episodeId):
            guard let ep = base.episodes[episodeId] else { return [] }
            return [OutboxCall("podcasts:markAllPlayed", ["podcastId": .string(ep.podcastId), "at": at, "beforePubDate": .number(ep.pubDate)])]

        case let .archiveOlder(episodeId):
            return [OutboxCall("episodes:archiveAllOlder", ["episodeId": .string(episodeId), "at": at])]

        case let .markAllPlayed(podcastId):
            guard !isLocal(podcastId) else { return [] }
            return [OutboxCall("podcasts:markAllPlayed", ["podcastId": .string(podcastId), "at": at])]

        case let .subscribe(r):
            var args: [String: JSONValue] = ["feedUrl": .string(r.feedURL), "at": at]
            if let v = r.title { args["title"] = .string(v) }
            if let v = r.author, !v.isEmpty { args["author"] = .string(v) }
            if let v = r.artworkURL { args["artworkUrl"] = .string(v) }
            if let v = r.appleId.flatMap(Double.init) { args["appleId"] = .number(v) }
            var calls = [OutboxCall("podcasts:subscribe", args)]
            if r.isPrivate {
                calls.append(OutboxCall("podcasts:setPrivate", ["isPrivate": true], resultArg: "podcastId"))
            }
            return calls

        case let .unsubscribe(podcastId):
            guard !isLocal(podcastId) else { return [] }
            return [OutboxCall("podcasts:unsubscribe", ["podcastId": .string(podcastId), "at": at])]

        case let .setSpeed(value, scope):
            let patch: JSONValue = ["playbackSpeed": .number(Speed.snap(value))]
            switch scope {
            case .allPodcasts: return [OutboxCall("settings:updateGlobal", ["patch": patch, "at": at])]
            case let .show(podcastId):
                guard !isLocal(podcastId) else { return [] }
                return [OutboxCall("settings:updatePodcast", ["podcastId": .string(podcastId), "patch": patch, "at": at])]
            }

        case let .updatePodcastSettings(s):
            guard !isLocal(s.podcastId) else { return [] }
            let old = SettingsMapping.fields(base.podcastSettings[s.podcastId] ?? PodcastSettings(podcastId: s.podcastId))
            let patch = SettingsMapping.patch(from: old, to: SettingsMapping.fields(s))
            guard !patch.isEmpty else { return [] }
            return [OutboxCall("settings:updatePodcast", ["podcastId": .string(s.podcastId), "patch": .object(patch), "at": at])]

        case let .updateGlobalSettings(g):
            let patch = SettingsMapping.patch(from: SettingsMapping.fields(base.global), to: SettingsMapping.fields(g))
            guard !patch.isEmpty else { return [] }
            return [OutboxCall("settings:updateGlobal", ["patch": .object(patch), "at": at])]

        case let .recordSessions(sessions):
            // Sessions on an episode the server hasn't assigned an ID to yet would fail the batch.
            let real = sessions.filter { !isLocal($0.episodeId) }
            guard !real.isEmpty else { return [] }
            return [OutboxCall("sessions:record", ["sessions": .array(real.map(sessionArgs))])]

        case let .registerDevice(apnsToken, environment):
            return [OutboxCall("devices:register", [
                "deviceId": .string(deviceId), "name": .string(deviceName), "platform": .string(platform),
                "apnsToken": .string(apnsToken), "apnsEnvironment": .string(environment.rawValue),
            ])]
        }
    }

    /// `SessionInput` as Convex wants it: optional fields left out rather than null.
    static func sessionArgs(_ s: SessionInput) -> JSONValue {
        var o: [String: JSONValue] = [
            "sessionId": .string(s.sessionId), "episodeId": .string(s.episodeId),
            "startedAt": .number(s.startedAt), "endedAt": .number(s.endedAt),
            "contentStart": .number(s.contentStart), "contentEnd": .number(s.contentEnd),
            "rate": .number(s.rate), "smartSpeed": .bool(s.smartSpeed),
            "smartRemovedContent": .number(s.smartRemovedContent), "voiceBoost": .bool(s.voiceBoost),
        ]
        if let v = s.deviceId { o["deviceId"] = .string(v) }
        if let v = s.route { o["route"] = .string(v) }
        if let v = s.utcOffsetMinutes { o["utcOffsetMinutes"] = .number(Double(v)) }
        return .object(o)
    }

    static var platform: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #endif
    }

    // MARK: - Stats

    private static func localDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func statsArgs(year: Int) -> (anchor: String, today: String) {
        let date = now()
        let today = Self.localDay(date)
        let currentYear = Calendar.current.component(.year, from: date)
        return (year == currentYear ? today : "\(year)-06-01", today)
    }

    public func watchStats(year: Int) async -> AsyncThrowingStream<StatsSummary, Error> {
        let (anchor, today) = statsArgs(year: year)
        let key = String(year)
        let cached = cache.stats[key]
        let currentYear = Calendar.current.component(.year, from: now())
        let streams = [
            resilient("stats:summary", ["period": "year", "anchorDay": .string(anchor)]),
            resilient("stats:summary", ["period": "all"]),
            resilient("overcastImport:latestImport", [:]),
        ]
        return AsyncThrowingStream { continuation in
            if let cached { continuation.yield(cached) }
            let task = Task { [weak self] in
                await combineLatest(streams) { [weak self] values in
                    guard let y = values[0], let doc = try? JSONDecoder().decode(SummaryDoc.self, from: y) else { return }
                    let all = values[1].flatMap { try? JSONDecoder().decode(SummaryDoc.self, from: $0) }
                    let batch = values[2].flatMap { try? JSONDecoder().decode(ImportBatchDoc?.self, from: $0) }
                    let summary = StatsMapping.summary(year: year, doc, allTime: all, today: today, estimatedBefore: batch?.finishedAt)
                    continuation.yield(summary)
                    await self?.remember(key, summary, years: all.map { StatsMapping.years(from: $0, current: currentYear) })
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func remember(_ key: String, _ summary: StatsSummary, years: [Int]?) {
        cache.stats[key] = summary
        if let years { cache.years = years }
        scheduleSave()
    }

    public func stats(year: Int) async throws -> StatsSummary {
        let (anchor, today) = statsArgs(year: year)
        let y = try await transport.query("stats:summary", ["period": "year", "anchorDay": .string(anchor)])
        let a = try await transport.query("stats:summary", ["period": "all"])
        let all = try JSONDecoder().decode(SummaryDoc.self, from: a)
        return StatsMapping.summary(year: year, try JSONDecoder().decode(SummaryDoc.self, from: y), allTime: all, today: today, estimatedBefore: nil)
    }

    public func availableYears() async throws -> [Int] {
        if !cache.years.isEmpty { return cache.years }
        let data = try await transport.query("stats:summary", ["period": "all"])
        let years = StatsMapping.years(from: try JSONDecoder().decode(SummaryDoc.self, from: data), current: Calendar.current.component(.year, from: now()))
        cache.years = years
        scheduleSave()
        return years
    }

    public func watchYearInReview(year: Int) async -> AsyncThrowingStream<YearInReview, Error> {
        let key = String(year)
        let cached = cache.yearInReview[key]
        let stream = resilient("stats:yearInReview", ["year": .number(Double(year)), "includePrivate": true])
        return AsyncThrowingStream { continuation in
            if let cached { continuation.yield(cached) }
            let task = Task { [weak self] in
                for await data in stream {
                    guard let doc = try? JSONDecoder().decode(YearInReviewDoc.self, from: data) else { continue }
                    let review = StatsMapping.yearInReview(doc)
                    continuation.yield(review)
                    await self?.remember(key, review)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func remember(_ key: String, _ review: YearInReview) {
        cache.yearInReview[key] = review
        scheduleSave()
    }

    public func yearInReview(year: Int) async throws -> YearInReview {
        let data = try await transport.query("stats:yearInReview", ["year": .number(Double(year)), "includePrivate": true])
        return StatsMapping.yearInReview(try JSONDecoder().decode(YearInReviewDoc.self, from: data))
    }

    // MARK: - Discover

    public func search(_ term: String) async throws -> SearchResponse {
        let data = try await transport.action("directory:search", ["term": .string(term), "limit": 50])
        let results = try JSONDecoder().decode([DirectoryResultDoc].self, from: data).compactMap(\.model)
        return SearchResponse(results: results, totalCount: results.count)
    }

    public func searchEpisodes(_ term: String) async throws -> [EpisodeSearchResult] {
        let data = try await transport.action("directory:searchEpisodes", ["term": .string(term), "limit": 25])
        return try JSONDecoder().decode([DirectoryEpisodeDoc].self, from: data).map(\.model)
    }

    public func open(_ target: DiscoverTarget) async throws -> OpenedFeed {
        var args: [String: JSONValue]
        func set(_ key: String, _ value: String?) { if let value, !value.isEmpty { args[key] = .string(value) } }
        switch target {
        case let .show(r):
            args = ["feedUrl": .string(r.feedURL)]
            set("title", r.title); set("author", r.author); set("artworkUrl", r.artworkURL)
            if let apple = r.appleId.flatMap(Double.init) { args["appleId"] = .number(apple) }
        case let .episode(e):
            args = ["feedUrl": .string(e.feedURL)]
            set("title", e.showTitle); set("author", e.author); set("artworkUrl", e.artworkURL)
            set("episodeGuid", e.guid); set("enclosureUrl", e.audioURL); set("episodeTitle", e.title)
            if let pubDate = e.pubDate { args["pubDate"] = .number(pubDate) }
        }
        let data = try await transport.action("feedActions:openFeed", args)
        let doc = try JSONDecoder().decode(OpenedFeedDoc.self, from: data)
        return OpenedFeed(podcastId: doc.podcastId, episodeId: doc.episodeId)
    }

    /// Apple and Overcast links go through the directory; anything else is fetched as a feed
    /// (or a website with a feed link) by `feedActions:previewFeed`.
    public func resolve(url: String) async throws -> SearchResult? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isDirectory = trimmed.allSatisfy(\.isNumber) || trimmed.contains("podcasts.apple.com") || trimmed.contains("overcast.fm")
        if isDirectory {
            let data = try await transport.action("directory:lookup", ["appleIdOrUrl": .string(trimmed)])
            if let hit = try JSONDecoder().decode(DirectoryResultDoc?.self, from: data)?.model { return hit }
        }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        let data = try await transport.action("feedActions:previewFeed", ["url": .string(full)])
        return try JSONDecoder().decode(FeedPreviewDoc.self, from: data).model
    }

    public func refresh(podcastId: String?) async throws {
        var args: [String: JSONValue] = [:]
        if let podcastId, !podcastId.hasPrefix("local-") { args["podcastId"] = .string(podcastId) }
        _ = try await transport.action("feedActions:refreshNow", (args))
        await catchUp()
    }

    public func observePodcast(_ podcastId: String) async {
        guard !podcastId.hasPrefix("local-") else { return }
        let gen = generation
        let feeds = [Feed.podcastEpisodes(podcastId), .podcastSettings(podcastId)]
        let streams = feeds.map { resilient($0.name, $0.args) }
        await withTaskGroup(of: Void.self) { group in
            for (feed, stream) in zip(feeds, streams) {
                group.addTask { [weak self] in
                    for await data in stream { await self?.merge(feed, data, gen: gen) }
                }
            }
        }
    }

    /// Fetches a shared episode or show. False only when the server says it doesn't exist (or is
    /// private). A link opened as the app starts can land mid sign-in, while the connection has no
    /// session yet or is switching people; that used to read as "not found", so those are retried.
    public func loadShared(_ target: ShareLinks.Target) async -> Bool {
        let d = JSONDecoder()
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: timing.retry * Double(attempt)) }
            let gen = generation
            let name: String
            let args: [String: JSONValue]
            switch target {
            case let .episode(id, _): (name, args) = ("episodes:get", ["episodeId": .string(id)])
            case let .show(id): (name, args) = ("podcasts:get", ["podcastId": .string(id)])
            }
            guard let data = try? await transport.query(name, args), gen == generation else { continue }
            switch target {
            case .episode:
                guard let got = (try? d.decode(EpisodeGetDoc?.self, from: data)) ?? nil else { return false }
                upsert(got.row)
            case .show:
                guard let got = (try? d.decode(PodcastGetDoc?.self, from: data)) ?? nil else { return false }
                cache.snapshot.podcasts[got.podcast._id] = got.podcast.model
            }
            changed()
            return true
        }
        return false
    }

    public func showNotes(episodeId: String) async -> String? {
        guard let data = try? await transport.query("episodes:get", ["episodeId": .string(episodeId)]) else { return nil }
        return (try? JSONValue.decode(data))?["showNotesHtml"]?.string
    }

    // MARK: - Overcast import

    public func importOvercast(fileName: String, data: Data, assumedSpeed: Double) async -> AsyncThrowingStream<ImportProgress, Error> {
        let transport = transport
        let started = nowMillis
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(ImportProgress(phase: .reading, fileName: fileName, importedAt: started))
                    let urlData = try await transport.mutation("overcastImport:generateUploadUrl", [:])
                    guard let urlString = try JSONValue.decode(urlData).string, let url = URL(string: urlString) else {
                        throw TransportError.server("No upload URL")
                    }
                    let uploaded = try await transport.upload(to: url, data: data, contentType: "text/xml")
                    guard let storageId = try JSONValue.decode(uploaded)["storageId"]?.string else {
                        throw TransportError.server("The upload didn't return a storage ID")
                    }
                    let batchData = try await transport.mutation("overcastImport:startOvercastImport", [
                        "storageId": .string(storageId), "assumedSpeed": .number(Speed.snap(assumedSpeed)),
                    ])
                    guard let batchId = try JSONValue.decode(batchData).string else { throw TransportError.server("No import ID") }
                    for try await update in transport.subscribe("overcastImport:getImport", ["batchId": .string(batchId)]) {
                        guard let batch = try JSONDecoder().decode(ImportBatchDoc?.self, from: update) else { continue }
                        let progress = batch.progress(fileName: fileName)
                        continuation.yield(progress)
                        if progress.phase == .done || progress.phase == .failed { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Raw calls

    /// A mutation on this store's connection, as whoever's signed in, answered as raw JSON. For
    /// clients that bring their own models: Chef, through the app's `ChefConnection`.
    public func rawMutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        await authIfNeeded()
        return try await transport.mutation(name, args)
    }

    /// A live query on this store's connection, as raw JSON. It finishes with an error when the
    /// function throws or the account changes (a new connection), so ask again after that.
    public func rawSubscribe(_ name: String, _ args: [String: JSONValue]) async -> AsyncThrowingStream<Data, Error> {
        await authIfNeeded()
        return transport.subscribe(name, args)
    }

    private func authIfNeeded() async {
        guard authPending, userId != nil else { return }
        authPending = false
        await transport.setAuth(auth)
    }

    // MARK: - Chapters

    private struct ChapterFile: Decodable {
        struct Item: Decodable {
            var startTime: Double
            var endTime: Double?
            var title: String?
            var img: String?
            var url: String?
            var toc: Bool?
        }
        var chapters: [Item]
    }

    /// Podcasting 2.0 JSON chapters. Embedded ID3/MP4 chapters come from the downloaded file.
    public func chapters(for episode: Episode) async -> [Chapter] {
        guard let s = episode.chaptersURL, let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let file = try? JSONDecoder().decode(ChapterFile.self, from: data) else { return [] }
        let items = file.chapters.sorted { $0.startTime < $1.startTime }
        return items.enumerated().map { i, c in
            Chapter(
                start: c.startTime, end: c.endTime ?? (i + 1 < items.count ? items[i + 1].startTime : episode.duration),
                title: c.title ?? "Chapter \(i + 1)", img: c.img, url: c.url, toc: c.toc ?? true
            )
        }
    }
}

/// Calls `body` with the latest value of every stream each time any of them yields.
private func combineLatest(_ streams: [AsyncStream<Data>], _ body: @escaping @Sendable ([Data?]) async -> Void) async {
    let box = LatestValues(count: streams.count, body: body)
    await withTaskGroup(of: Void.self) { group in
        for (i, stream) in streams.enumerated() {
            group.addTask {
                for await value in stream { await box.set(i, value) }
            }
        }
    }
}

private actor LatestValues {
    private var values: [Data?]
    private let body: @Sendable ([Data?]) async -> Void
    init(count: Int, body: @escaping @Sendable ([Data?]) async -> Void) {
        values = Array(repeating: nil, count: count)
        self.body = body
    }
    func set(_ i: Int, _ value: Data) async {
        values[i] = value
        await body(values)
    }
}

public enum LiveStoreError: LocalizedError {
    case notWired
    public var errorDescription: String? { "The Convex backend isn't wired up yet." }
}
