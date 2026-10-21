import Foundation

/// One stretch of listening as the player reports it: PoddlePlayback's `ListeningSegment`, mapped
/// by the app so PoddleKit doesn't depend on the audio engine. The player re-reports an open
/// session every 30 s with the same `id` and a later end, then once more with `isFinal`.
public struct ListeningCheckpoint: Sendable, Hashable {
    public var id: UUID
    public var episodeId: String
    /// Milliseconds since the epoch.
    public var wallStart: Millis
    public var wallEnd: Millis
    /// Content seconds.
    public var contentStart: Double
    public var contentEnd: Double
    public var rate: Double
    public var smartSpeed: Bool
    public var smartRemovedContent: Double
    public var voiceBoost: Bool
    public var route: String?
    public var isFinal: Bool

    public init(
        id: UUID, episodeId: String, wallStart: Millis, wallEnd: Millis, contentStart: Double, contentEnd: Double,
        rate: Double, smartSpeed: Bool, smartRemovedContent: Double, voiceBoost: Bool, route: String?, isFinal: Bool
    ) {
        self.id = id; self.episodeId = episodeId; self.wallStart = wallStart; self.wallEnd = wallEnd
        self.contentStart = contentStart; self.contentEnd = contentEnd; self.rate = rate; self.smartSpeed = smartSpeed
        self.smartRemovedContent = smartRemovedContent; self.voiceBoost = voiceBoost; self.route = route
        self.isFinal = isFinal
    }
}

/// Sends listening sessions to the backend (`sessions:record`). Each checkpoint replaces the
/// pending copy of its session, so a backlog never sends stale ends, and anything that fails to
/// send stays pending (on disk, if `persistURL` is set) until a later flush gets through.
@MainActor
public final class SessionForwarder {
    public private(set) var pending: [String: SessionInput] = [:]
    public private(set) var lastError: String?

    private let dataSource: any PoddleDataSource
    private let deviceId: String
    private let timeZone: TimeZone
    private let persistURL: URL?
    private let retryAfter: Duration
    private var sending: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    public init(
        dataSource: any PoddleDataSource, deviceId: String, timeZone: TimeZone = .current,
        persistURL: URL? = nil, retryAfter: Duration = .seconds(30)
    ) {
        self.dataSource = dataSource
        self.deviceId = deviceId
        self.timeZone = timeZone
        self.persistURL = persistURL
        self.retryAfter = retryAfter
        if let persistURL, let data = try? Data(contentsOf: persistURL),
           let saved = try? JSONDecoder().decode([String: SessionInput].self, from: data) {
            pending = saved
        }
    }

    /// The `SessionInput` for a checkpoint. `utcOffsetMinutes` is taken at the session's start.
    public func input(for c: ListeningCheckpoint) -> SessionInput {
        let start = Date(timeIntervalSince1970: c.wallStart / 1000)
        return SessionInput(
            sessionId: c.id.uuidString.lowercased(), episodeId: c.episodeId, deviceId: deviceId,
            startedAt: c.wallStart, endedAt: max(c.wallStart, c.wallEnd),
            contentStart: c.contentStart, contentEnd: max(c.contentStart, c.contentEnd),
            rate: c.rate, smartSpeed: c.smartSpeed, smartRemovedContent: max(0, c.smartRemovedContent),
            voiceBoost: c.voiceBoost, route: c.route, utcOffsetMinutes: timeZone.secondsFromGMT(for: start) / 60
        )
    }

    /// Queues a checkpoint and sends it straight away.
    public func record(_ checkpoint: ListeningCheckpoint) {
        let s = input(for: checkpoint)
        // Nothing heard: a tap on play then pause.
        guard s.endedAt - s.startedAt >= 1000 || s.contentEnd - s.contentStart >= 1 else { return }
        if let old = pending[s.sessionId], old.endedAt > s.endedAt { return }
        pending[s.sessionId] = s
        save()
        Task { await flush() }
    }

    /// Sends everything pending. Returns once it's sent (or failed), waiting for any send in flight.
    public func flush() async {
        while let inFlight = sending { await inFlight.value }
        guard !pending.isEmpty else { return }
        let batch = pending
        let source = dataSource
        let task = Task { [weak self] in
            // Cleared before the task finishes, so waiters never see a finished send as in flight.
            defer { self?.sending = nil }
            do {
                try await source.recordSessions(batch.values.sorted { $0.startedAt < $1.startedAt })
                guard let self else { return }
                // Keep anything that got a newer copy while this was in flight.
                for (id, sent) in batch where self.pending[id] == sent { self.pending[id] = nil }
                self.lastError = nil
                self.save()
            } catch {
                self?.lastError = error.localizedDescription
                self?.scheduleRetry()
            }
        }
        sending = task
        await task.value
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let delay = retryAfter
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.retry = nil
            await self?.flush()
        }
    }

    private func save() {
        guard let persistURL else { return }
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: persistURL)
        } else if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: persistURL, options: .atomic)
        }
    }
}
