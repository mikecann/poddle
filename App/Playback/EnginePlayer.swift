import Foundation
import Observation
import PoddleKit
import PoddlePlayback
#if os(iOS)
import AVFoundation
#endif

/// The real player: `PlaybackEngine` behind the same surface the screens use from `MockPlayer`.
///
/// - Loads an episode with its show's resolved settings (speed, Smart Speed, Voice Boost,
///   time-pitch, skip intro) and keeps them in step when they change, whatever the scope.
/// - Plays the downloaded file through the engine, or streams the enclosure until a download
///   lands (`fileReady`).
/// - Saves the position every few seconds while playing and on pause, marks the episode played at
///   the end (which also takes it out of Up Next) and plays the next one. Skip outro ends it early.
/// - Forwards the engine's listening segments to the store as sessions.
@MainActor
@Observable
final class EnginePlayer: PoddlePlayer {
    let store: PoddleStore
    let engine: PlaybackEngine

    private(set) var currentEpisodeId: String?
    private(set) var chapters: [PoddleKit.Chapter] = []
    private(set) var sleepTimer: PoddleKit.SleepTimer = .off
    private(set) var routeName = "iPhone"
    var skipBackOverride: Double?
    var skipForwardOverride: Double?
    /// The last playback error, for a banner.
    private(set) var lastError: String?

    @ObservationIgnored private let downloads: DownloadManager?
    @ObservationIgnored private let sessions: SessionForwarder?
    /// Where a load in progress will start, so the UI doesn't jump to 0 while chapters load.
    @ObservationIgnored private var pendingPosition: Double = 0
    @ObservationIgnored private var playWhenLoaded = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var smartSavedBefore: Double = 0
    @ObservationIgnored private var lastSaveAt = Date.distantPast
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private var lastSleepTimer: PoddleKit.SleepTimer = .off
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// Saved to the store this often while playing (it's also saved on pause, seek and episode change).
    /// Each save is a server round trip, so every 5 s kept the phone's radio awake for whole listens;
    /// a crash mid-episode loses at most a minute.
    static let saveInterval: TimeInterval = 60

    init(store: PoddleStore, engine: PlaybackEngine = PlaybackEngine(), downloads: DownloadManager?, sessions: SessionForwarder?) {
        self.store = store
        self.engine = engine
        self.downloads = downloads
        self.sessions = sessions
        #if os(macOS)
        routeName = "This Mac"
        #endif
        let events = engine.events
        let segments = engine.segments
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        tasks.append(Task { [weak self] in
            for await segment in segments { self?.forward(segment) }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        })
        syncSettings()
    }

    // MARK: - State

    var isPlaying: Bool { engine.isPlaying || (playWhenLoaded && engine.item == nil && currentEpisodeId != nil) }
    var isBuffering: Bool { engine.isBuffering || (playWhenLoaded && engine.item == nil) }
    var position: Double { engine.item == nil ? pendingPosition : engine.position }
    var duration: Double { engine.duration > 0 ? engine.duration : item?.duration ?? 0 }
    var rate: Double { engine.rate }
    var smartSaved: Double { smartSavedBefore + engine.smartSpeedRemovedEpisode }
    var sleepRemaining: Double? { sleepTimer == .off ? nil : engine.sleepTimerState?.remaining }
    /// Streaming (`.streaming`) or playing a downloaded file through the engine (`.engine`).
    var backend: PlaybackEngine.Backend { engine.backend }

    // MARK: - Loading

    func load(_ episodeId: String, position: Double?, smartSaved: Double) {
        guard let item = store.item(episodeId) else { return }
        if let current = currentEpisodeId, current != episodeId { savePosition() }
        engine.unload()
        currentEpisodeId = episodeId
        smartSavedBefore = smartSaved
        let resolved = store.resolved(item.podcast.id)
        let saved = item.state.played ? 0 : item.state.position
        let start = position ?? (saved > 1 ? saved : resolved.skipIntro.value)
        pendingPosition = start
        chapters = store.cachedChapters(episodeId)
        apply(resolved)

        loadGeneration += 1
        let generation = loadGeneration
        Task {
            // Chapters and artwork go in the item, so give them a moment before loading.
            async let fetchedChapters = withTimeout(seconds: 2) { await self.store.chapters(for: episodeId) }
            async let artwork = withTimeout(seconds: 2) { await Self.artworkData(for: item) }
            let loadedChapters = await fetchedChapters ?? self.chapters
            let art = await artwork ?? nil
            guard generation == self.loadGeneration else { return }
            self.chapters = loadedChapters
            self.startEngine(item: item, start: start, chapters: loadedChapters, artwork: art)
        }
    }

    private func startEngine(item: EpisodeItem, start: Double, chapters: [PoddleKit.Chapter], artwork: Data?) {
        let local = downloads?.localFile(for: item.id)
        guard let source = local.map(PlaybackSource.local) ?? URL(string: item.episode.enclosureURL).map(PlaybackSource.remote) else {
            lastError = "This episode has no audio file."
            playWhenLoaded = false
            return
        }
        let playbackItem = PlaybackItem(
            id: item.id, source: source, title: item.episode.title, showTitle: item.podcast.title, artwork: artwork,
            duration: item.episode.duration, chapters: chapters.map { .init(title: $0.title, start: $0.start, end: $0.end) },
            loudness: downloads?.loudness(for: item.id))
        do {
            try engine.load(playbackItem, startAt: start, autoplay: playWhenLoaded)
            lastError = nil
        } catch {
            // A local file the engine can't open: fall back to streaming it.
            if local != nil, let url = URL(string: item.episode.enclosureURL) {
                var streamed = playbackItem
                streamed.source = .remote(url)
                try? engine.load(streamed, startAt: start, autoplay: playWhenLoaded)
            } else {
                lastError = error.localizedDescription
            }
        }
        playWhenLoaded = false
        wasPlaying = engine.isPlaying
    }

    /// A download finished. If it's what's playing, switch from streaming to the engine in place.
    func fileReady(_ url: URL, for episodeId: String) {
        guard episodeId == engine.item?.id else { return }
        try? engine.localFileReady(url, forEpisode: episodeId, loudness: downloads?.loudness(for: episodeId))
    }

    // MARK: - Transport

    func play(_ episodeId: String) {
        store.moveToTop(episodeId)
        if episodeId != currentEpisodeId {
            playWhenLoaded = true
            load(episodeId, position: nil, smartSaved: 0)
        } else {
            resume()
        }
    }

    func resume() {
        guard currentEpisodeId != nil else {
            if let next = store.queue.first { play(next.id) }
            return
        }
        if engine.item == nil {
            playWhenLoaded = true
        } else {
            engine.play()
        }
        wasPlaying = true
    }

    func pause() {
        playWhenLoaded = false
        engine.pause()
        savePosition()
        wasPlaying = false
    }

    func unload() {
        pause()
        engine.unload()
        currentEpisodeId = nil
        pendingPosition = 0
        chapters = []
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        if engine.item == nil { pendingPosition = target } else { engine.seek(to: target) }
        savePosition()
    }

    func nextChapter() {
        guard let i = currentChapterIndex, i + 1 < chapters.count else { return playNextInQueue() }
        seek(to: chapters[i + 1].start)
    }

    func previousChapter() {
        guard let i = currentChapterIndex else { return seek(to: 0) }
        // Like a CD player: back to the start of this chapter unless you're right at it.
        if position - chapters[i].start > 3 || i == 0 { seek(to: chapters[i].start) } else { seek(to: chapters[i - 1].start) }
    }

    func playNextInQueue() {
        guard let next = store.queue.first(where: { $0.id != currentEpisodeId }) else { return }
        play(next.id)
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: PoddleKit.SleepTimer) {
        sleepTimer = timer
        if timer != .off { lastSleepTimer = timer }
        switch timer {
        case .off: engine.setSleepTimer(nil)
        case let .minutes(m, _): engine.setSleepTimer(.minutes(Double(m)))
        case .endOfEpisode: engine.setSleepTimer(.endOfEpisode)
        case .endOfChapter: engine.setSleepTimer(.endOfChapter)
        }
    }

    func extendSleepTimer() {
        guard store.global.shakeToRestartSleep else { return }
        let wasOff = sleepTimer == .off
        engine.extendSleepTimer()
        guard engine.sleepTimerState != nil || !wasOff else { return }
        // Running: back to full length. Just fired: the same timer again (the engine resumed playback).
        if case let .minutes(m, _) = lastSleepTimer {
            sleepTimer = .minutes(m, endsAt: Date().addingTimeInterval(Double(m) * 60))
        } else if wasOff, engine.sleepTimerState != nil {
            sleepTimer = lastSleepTimer
        }
    }

    // MARK: - Engine events

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .reachedPlayedThreshold:
            break
        case let .finished(id, shouldAdvance):
            finish(id, advance: shouldAdvance)
        case .sleepTimerFired:
            sleepTimer = .off
            savePosition()
        case let .failed(_, message):
            lastError = message
        }
    }

    /// End of the episode: mark it played (the backend also takes it out of Up Next), then play
    /// the next one unless an end-of-episode sleep timer stopped it or "Play the next episode" is off.
    private func finish(_ id: String, advance: Bool) {
        guard id == currentEpisodeId else { return }
        if !advance { sleepTimer = .off }
        store.markPlayed(id)
        let next = store.queue.first { $0.id != id }
        if let next {
            playWhenLoaded = advance && store.global.autoAdvance
            load(next.id, position: nil, smartSaved: 0)
        } else {
            engine.unload()
            currentEpisodeId = nil
            pendingPosition = 0
            chapters = []
        }
    }

    private func forward(_ s: ListeningSegment) {
        sessions?.record(ListeningCheckpoint(
            id: s.id, episodeId: s.episodeID, wallStart: s.wallStart, wallEnd: s.wallEnd,
            contentStart: s.contentStart, contentEnd: s.contentEnd, rate: s.rate, smartSpeed: s.smartSpeed,
            smartRemovedContent: s.smartRemovedContent, voiceBoost: s.voiceBoost, route: s.route.rawValue, isFinal: s.isFinal))
    }

    // MARK: - Ticking

    private func tick() {
        syncSettings()
        updateRouteName()
        guard let id = currentEpisodeId, engine.item?.id == id else { return }

        // Paused from the lock screen, AirPods or an interruption: save where it stopped.
        if wasPlaying && !engine.isPlaying { savePosition() }
        wasPlaying = engine.isPlaying
        guard engine.isPlaying else { return }

        if let item {
            let outro = store.resolved(item.podcast.id).skipOutro.value
            if outro > 0, duration > outro, position >= duration - outro {
                engine.pause()
                finish(id, advance: sleepTimer != .endOfEpisode)
                return
            }
        }
        if Date().timeIntervalSince(lastSaveAt) >= Self.saveInterval { savePosition() }
        if let measured = engine.measuredLoudness, downloads?.loudness(for: id) == nil, engine.backend == .engine {
            downloads?.setLoudness(measured, for: id)
        }
    }

    private func savePosition() {
        guard let id = currentEpisodeId, engine.item?.id == id else { return }
        lastSaveAt = Date()
        store.savePosition(id, engine.position)
    }

    /// Keeps the engine on the current show's resolved settings and the global skip settings.
    private func syncSettings() {
        let g = store.global
        let commands = RemoteCommandConfiguration(
            skipBackwardInterval: g.skipBack, skipForwardInterval: g.skipForward,
            nextPrevious: g.headphoneMapping == .chapters ? .chapter : .skip)
        if engine.remoteCommands != commands { engine.remoteCommands = commands }
        if engine.autoRewindEnabled != g.autoRewind { engine.autoRewindEnabled = g.autoRewind }
        if let item { apply(store.resolved(item.podcast.id)) }
    }

    private func apply(_ r: ResolvedSettings) {
        let s = engine.settings
        if s.rate != Speed.snap(r.speed.value) { engine.setRate(r.speed.value) }
        if s.smartSpeed != r.smartSpeed.value { engine.setSmartSpeed(r.smartSpeed.value) }
        if s.voiceBoost != r.voiceBoost.value { engine.setVoiceBoost(r.voiceBoost.value) }
        let algorithm: PoddlePlayback.TimePitchAlgorithm = r.timePitch.value == .timeDomain ? .timeDomain : .spectral
        if s.algorithm != algorithm { engine.setTimePitchAlgorithm(algorithm) }
    }

    private func updateRouteName() {
        #if os(iOS)
        let name = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone"
        if name != routeName { routeName = name }
        #endif
    }

    // MARK: - Helpers

    private static func artworkData(for item: EpisodeItem) async -> Data? {
        guard let s = item.episode.artworkURL ?? item.podcast.artworkURL, let url = URL(string: s) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }
}

/// The value, or nil if it takes longer than `seconds`.
@MainActor
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @MainActor () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
