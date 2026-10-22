import Foundation
import Observation

public enum SleepTimer: Sendable, Hashable {
    case off
    case minutes(Int, endsAt: Date)
    case endOfEpisode
    case endOfChapter

    public static let presets = [5, 10, 15, 30, 45, 60]
}

/// Fake playback for previews and screenshots (the app uses PoddlePlayback otherwise): it ticks the
/// position along at the current speed so Now Playing, the mini player and every progress bar move,
/// saves positions, advances the queue and runs the sleep timer.
@MainActor
@Observable
public final class MockPlayer: PoddlePlayer {
    public private(set) var currentEpisodeId: String?
    public private(set) var isPlaying = false
    public let isBuffering = false
    public private(set) var position: Double = 0
    public private(set) var chapters: [Chapter] = []
    /// Content seconds Smart Speed has trimmed from this episode.
    public private(set) var smartSaved: Double = 0
    public private(set) var sleepTimer: SleepTimer = .off
    public var routeName = "iPhone"
    /// "Choose the interval for this session" from a long-press on the skip buttons.
    public var skipBackOverride: Double?
    public var skipForwardOverride: Double?

    @ObservationIgnored public let store: PoddleStore
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastSave: Double = 0
    @ObservationIgnored private var lastTick = Date()

    public init(store: PoddleStore) {
        self.store = store
    }

    /// Loads an episode without playing it (used at launch to restore state).
    public func load(_ episodeId: String, position: Double?, smartSaved: Double) {
        currentEpisodeId = episodeId
        let item = store.item(episodeId)
        let start = position ?? item.map { $0.state.position > 0 ? $0.state.position : store.resolved($0.podcast.id).skipIntro.value } ?? 0
        self.position = start
        self.smartSaved = smartSaved
        lastSave = start
        Task { chapters = await store.chapters(for: episodeId) }
    }

    // MARK: - Derived

    public var duration: Double { item?.duration ?? 0 }
    public var rate: Double { item?.speed.value ?? store.global.speed }

    public var sleepRemaining: Double? {
        switch sleepTimer {
        case let .minutes(_, endsAt): max(0, endsAt.timeIntervalSinceNow)
        case .endOfEpisode: wallRemaining
        case .endOfChapter: currentChapter.map { (($0.end ?? duration) - position) / rate }
        case .off: nil
        }
    }

    // MARK: - Transport

    /// Play now. Whatever was playing moves down to second in the queue.
    public func play(_ episodeId: String) {
        if episodeId != currentEpisodeId {
            saveNow()
            load(episodeId, position: nil, smartSaved: 0)
        }
        store.moveToTop(episodeId)
        resume()
    }

    public func resume() {
        guard currentEpisodeId != nil else {
            if let next = store.queue.first { play(next.id) }
            return
        }
        isPlaying = true
        lastTick = Date()
        startTicker()
    }

    public func pause() {
        isPlaying = false
        saveNow()
    }

    public func seek(to seconds: Double) {
        position = min(max(0, seconds), duration)
        saveNow()
    }

    public func nextChapter() {
        guard let i = currentChapterIndex, i + 1 < chapters.count else { return playNextInQueue() }
        seek(to: chapters[i + 1].start)
    }

    public func previousChapter() {
        guard let i = currentChapterIndex else { return seek(to: 0) }
        // Like a CD player: back to the start of this chapter unless you're right at it.
        if position - chapters[i].start > 3 || i == 0 { seek(to: chapters[i].start) } else { seek(to: chapters[i - 1].start) }
    }

    public func playNextInQueue() {
        guard let next = store.queue.first(where: { $0.id != currentEpisodeId }) else { return }
        play(next.id)
    }

    public func setSleepTimer(_ timer: SleepTimer) { sleepTimer = timer }

    public func extendSleepTimer() {
        if case let .minutes(m, _) = sleepTimer { setSleepMinutes(m) }
    }

    // MARK: - Ticking

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.tick()
                if !self.isPlaying { self.ticker = nil; return }
            }
        }
    }

    func tick(now: Date = Date()) {
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard isPlaying, let item else { return }
        let content = dt * rate
        position += content
        if store.resolved(item.podcast.id).smartSpeed.value { smartSaved += content * 0.035 }

        let outro = store.resolved(item.podcast.id).skipOutro.value
        if position >= duration - outro {
            finishEpisode()
            return
        }
        if position - lastSave > 5 * rate { saveNow() }

        switch sleepTimer {
        case let .minutes(_, endsAt) where endsAt <= now:
            sleepTimer = .off
            pause()
        case .endOfChapter:
            if let c = currentChapter, let end = c.end, position >= end - 0.5 {
                sleepTimer = .off
                pause()
            }
        default: break
        }
    }

    public func unload() {
        pause()
        currentEpisodeId = nil
        position = 0
    }

    private func finishEpisode() {
        guard let id = currentEpisodeId else { return }
        store.markPlayed(id)
        let stopHere = sleepTimer == .endOfEpisode
        if stopHere { sleepTimer = .off }
        if store.global.autoAdvance, !stopHere, let next = store.queue.first(where: { $0.id != id }) {
            load(next.id, position: nil, smartSaved: 0)
            isPlaying = true
        } else {
            isPlaying = false
            currentEpisodeId = nil
            position = 0
        }
    }

    private func saveNow() {
        guard let id = currentEpisodeId else { return }
        lastSave = position
        store.savePosition(id, position)
    }
}
