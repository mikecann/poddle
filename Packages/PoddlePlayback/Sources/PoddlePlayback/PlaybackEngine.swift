import Foundation
import Observation

/// Poddle's player. Main-actor API; decoding and DSP run on a producer queue, audio on the render thread.
///
/// Positions are always content seconds (time in the original file), whatever Smart Speed and the
/// rate are doing. Wire `segments` to the stats log and `events` to played/queue handling.
@MainActor
@Observable
public final class PlaybackEngine {
    public enum Backend: Sendable, Equatable {
        case none
        /// AVAudioEngine with Smart Speed and Voice Boost (local file).
        case engine
        /// AVPlayer, speed only (streaming until the download finishes).
        case streaming
    }

    // MARK: Published state

    public private(set) var item: PlaybackItem?
    public private(set) var backend: Backend = .none
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var settings: AudioSettings
    /// Content seconds Smart Speed removed from the current episode since it was loaded.
    public private(set) var smartSpeedRemovedEpisode: Double = 0
    /// Content seconds Smart Speed removed since this engine was created.
    public private(set) var smartSpeedRemovedSession: Double = 0
    public private(set) var currentChapterIndex: Int?
    public private(set) var sleepTimerState: SleepTimerState?
    /// Integrated loudness of the current local file, once known (store it so it isn't measured again).
    public private(set) var measuredLoudness: Double?

    public var currentChapter: Chapter? { currentChapterIndex.flatMap { item?.chapters[$0] } }
    public var rate: Double { settings.rate }

    public var remoteCommands: RemoteCommandConfiguration {
        didSet { installRemoteCommands() }
    }
    public var autoRewindEnabled = true

    public let segments: AsyncStream<ListeningSegment>
    public let events: AsyncStream<PlaybackEvent>

    // MARK: Internals

    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private let segmentContinuation: AsyncStream<ListeningSegment>.Continuation
    @ObservationIgnored private let eventContinuation: AsyncStream<PlaybackEvent>.Continuation
    @ObservationIgnored private var active: (any PlaybackBackend)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loudnessTask: Task<Void, Never>?
    @ObservationIgnored private var recorder = ListeningSegmentRecorder()
    @ObservationIgnored private var sleepTimer = SleepTimer()
    @ObservationIgnored private var pausedAt: Double?
    @ObservationIgnored private var reportedPlayed = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var route: AudioRoute = .unknown
    @ObservationIgnored private var lastNowPlayingUpdate = 0.0
    @ObservationIgnored private let session = AudioSessionController()
    @ObservationIgnored private let nowPlaying = NowPlayingController()
    @ObservationIgnored private let remote = RemoteCommandController()

    public init(settings: AudioSettings = .init(), remoteCommands: RemoteCommandConfiguration = .init(),
                clock: any PlaybackClock = SystemPlaybackClock()) {
        self.settings = Self.clamped(settings)
        self.remoteCommands = remoteCommands
        self.clock = clock
        (segments, segmentContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        session.configure()
        route = session.currentRoute
        session.onEvent = { [weak self] in self?.handleSessionEvent($0) }
        installRemoteCommands()
    }

    // MARK: Loading

    /// Loads an episode, paused at `startAt` content seconds unless `autoplay`.
    public func load(_ item: PlaybackItem, startAt: Double = 0, autoplay: Bool = false) throws {
        unload()
        self.item = item
        smartSpeedRemovedEpisode = 0
        reportedPlayed = false
        pausedAt = nil
        measuredLoudness = item.loudness
        duration = item.duration ?? 0
        position = max(0, startAt)

        switch item.source {
        case .local(let url):
            try startEngineBackend(url: url, at: position, playing: false)
        case .remote(let url):
            let streaming = StreamingBackend(url: url, settings: settings)
            streaming.seek(to: position, playing: false)
            active = streaming
            backend = .streaming
        }
        updateChapter()
        updateNowPlaying()
        if autoplay { play() }
    }

    /// The download finished: switch from streaming to the engine at the same position, without a gap.
    public func localFileReady(_ url: URL, forEpisode episodeID: String, loudness: Double? = nil) throws {
        guard var item, item.id == episodeID else { return }
        item.source = .local(url)
        if let loudness { item.loudness = loudness }
        self.item = item
        guard backend == .streaming, let old = active else { return }
        let current = old.poll().position ?? position
        if let loudness { measuredLoudness = loudness }
        try startEngineBackend(url: url, at: current, playing: isPlaying)
        old.stop()
    }

    private func startEngineBackend(url: URL, at seconds: Double, playing: Bool) throws {
        let engine = try EngineBackend(url: url, settings: settings, loudness: measuredLoudness) { [weak self] in
            self?.recoverFromConfigurationChange()
        }
        engine.seek(to: seconds, playing: playing)
        active = engine
        backend = .engine
        if let fileDuration = engine.duration, fileDuration > 0 { duration = fileDuration }
        if measuredLoudness == nil { measureLoudness(url: url) }
    }

    private func measureLoudness(url: URL) {
        loudnessTask?.cancel()
        let episodeID = item?.id
        loudnessTask = Task { [weak self] in
            let lufs = await Task.detached(priority: .utility) { try? LoudnessMeter.integratedLoudness(of: url) }.value
            guard let self, !Task.isCancelled, let lufs, self.item?.id == episodeID else { return }
            self.measuredLoudness = lufs
            self.active?.setMeasuredLoudness(lufs)
        }
    }

    /// Stops and forgets the current episode.
    public func unload() {
        if isPlaying { closeSegment() }
        stopTicker()
        loudnessTask?.cancel()
        active?.stop()
        active = nil
        backend = .none
        item = nil
        isPlaying = false
        isBuffering = false
        currentChapterIndex = nil
        nowPlaying.clear()
    }

    // MARK: Transport

    public func play() {
        guard let active, !isPlaying else { return }
        if autoRewindEnabled, let pausedAt {
            let rewind = AutoRewind.amount(pausedFor: clock.now - pausedAt)
            if rewind > 0 {
                position = max(0, position - rewind)
                active.seek(to: position, playing: false)
            }
        }
        pausedAt = nil
        session.activate()
        active.volume = 1
        active.play()
        isPlaying = true
        recorder.begin(wall: clock.wallNow, content: position, removedTotal: smartSpeedRemovedEpisode, context: segmentContext)
        startTicker()
        updateNowPlaying()
    }

    public func pause() {
        guard let active, isPlaying else { return }
        tick()
        active.pause()
        isPlaying = false
        pausedAt = clock.now
        closeSegment()
        stopTicker()
        updateNowPlaying()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Seeks to content seconds.
    public func seek(to seconds: Double) {
        guard let active else { return }
        let from = active.poll().position ?? position
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if let closed = recorder.seek(from: from, to: target, wall: clock.wallNow, removedTotal: smartSpeedRemovedEpisode) {
            segmentContinuation.yield(closed)
        }
        active.seek(to: target, playing: isPlaying)
        position = target
        updateChapter()
        updateNowPlaying()
    }

    public func skip(by seconds: Double) {
        seek(to: (active?.poll().position ?? position) + seconds)
    }

    public func skipForward() { skip(by: remoteCommands.skipForwardInterval) }
    public func skipBackward() { skip(by: -remoteCommands.skipBackwardInterval) }

    public func nextChapter() {
        guard let chapters = item?.chapters, !chapters.isEmpty else { return }
        let next = chapters.firstIndex { $0.start > position + 0.5 }
        if let next { seek(to: chapters[next].start) }
    }

    /// Goes to the start of the current chapter, or the previous one if within 3 s of the start.
    public func previousChapter() {
        guard let chapters = item?.chapters, !chapters.isEmpty else { return }
        guard let index = chapters.lastIndex(where: { $0.start <= position }) else { return seek(to: 0) }
        if position - chapters[index].start < 3, index > 0 {
            seek(to: chapters[index - 1].start)
        } else {
            seek(to: chapters[index].start)
        }
    }

    // MARK: Settings

    public func setRate(_ rate: Double) {
        update { $0.rate = rate }
    }

    public func setSmartSpeed(_ enabled: Bool) {
        update { $0.smartSpeed = enabled }
    }

    public func setVoiceBoost(_ enabled: Bool) {
        update { $0.voiceBoost = enabled }
    }

    public func setTimePitchAlgorithm(_ algorithm: TimePitchAlgorithm) {
        update { $0.algorithm = algorithm }
    }

    private func update(_ change: (inout AudioSettings) -> Void) {
        var next = settings
        change(&next)
        next = Self.clamped(next)
        guard next != settings else { return }
        tick()
        settings = next
        active?.apply(next)
        if let closed = recorder.split(wall: clock.wallNow, content: position, removedTotal: smartSpeedRemovedEpisode, context: segmentContext) {
            segmentContinuation.yield(closed)
        }
        updateNowPlaying()
    }

    private static func clamped(_ s: AudioSettings) -> AudioSettings {
        var s = s
        s.rate = (min(3, max(0.5, s.rate)) * 20).rounded() / 20
        return s
    }

    // MARK: Sleep timer

    public func setSleepTimer(_ mode: SleepTimerMode?) {
        sleepTimer.set(mode, now: clock.now)
        active?.volume = 1
        refreshSleepTimerState()
    }

    /// Call when the device is shaken.
    public func extendSleepTimer() {
        if sleepTimer.extend(now: clock.now) { play() }
        active?.volume = 1
        refreshSleepTimerState()
    }

    private var sleepContext: SleepTimer.Context {
        let chapterEnd: Double? = currentChapterIndex.flatMap { i in
            guard let chapters = item?.chapters else { return nil }
            return chapters[i].end ?? (i + 1 < chapters.count ? chapters[i + 1].start : nil)
        }
        return .init(position: position, duration: duration, rate: settings.rate, chapterEnd: chapterEnd, isPlaying: isPlaying)
    }

    private func refreshSleepTimerState() {
        sleepTimerState = sleepTimer.state(now: clock.now, context: sleepContext)
    }

    // MARK: Ticking

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let active, let item else { return }
        let polled = active.poll()
        if let p = polled.position { position = p }
        if polled.smartRemoved > 0 {
            smartSpeedRemovedEpisode += polled.smartRemoved
            smartSpeedRemovedSession += polled.smartRemoved
        }
        if let d = active.duration, d > 0, abs(d - duration) > 0.5 { duration = d }
        isBuffering = isPlaying && active.isBuffering
        guard isPlaying else { return }

        let previousChapter = currentChapterIndex
        updateChapter()

        if !reportedPlayed, PlayedThreshold.isPlayed(position: position, duration: duration) {
            reportedPlayed = true
            eventContinuation.yield(.reachedPlayedThreshold(episodeID: item.id))
        }
        if let checkpoint = recorder.tick(wall: clock.wallNow, content: position, removedTotal: smartSpeedRemovedEpisode) {
            segmentContinuation.yield(checkpoint)
        }

        let endOfEpisodeTimer = sleepTimer.mode == .endOfEpisode
        switch sleepTimer.evaluate(now: clock.now, context: sleepContext) {
        case .inactive:
            break
        case .running(_, let volume):
            active.volume = volume
        case .fire:
            if !endOfEpisodeTimer || !active.reachedEnd {
                pause()
                active.volume = 1
                eventContinuation.yield(.sleepTimerFired)
            }
        }
        refreshSleepTimerState()

        if active.reachedEnd {
            finish(stoppedBySleepTimer: endOfEpisodeTimer)
            return
        }
        if previousChapter != currentChapterIndex || clock.now - lastNowPlayingUpdate > 5 {
            updateNowPlaying()
        }
    }

    private func finish(stoppedBySleepTimer: Bool) {
        guard let item, let active else { return }
        position = duration
        closeSegment()
        active.pause()
        active.volume = 1
        isPlaying = false
        stopTicker()
        if stoppedBySleepTimer {
            sleepTimer.set(nil, now: clock.now)
            sleepTimerState = nil
        }
        if !reportedPlayed {
            reportedPlayed = true
            eventContinuation.yield(.reachedPlayedThreshold(episodeID: item.id))
        }
        eventContinuation.yield(.finished(episodeID: item.id, shouldAdvance: !stoppedBySleepTimer))
        updateNowPlaying()
    }

    private func closeSegment() {
        if let segment = recorder.end(wall: clock.wallNow, content: position, removedTotal: smartSpeedRemovedEpisode) {
            segmentContinuation.yield(segment)
        }
    }

    private var segmentContext: SegmentContext {
        SegmentContext(
            episodeID: item?.id ?? "", rate: settings.rate,
            smartSpeed: settings.smartSpeed && backend == .engine,
            voiceBoost: settings.voiceBoost && backend == .engine, route: route)
    }

    private func updateChapter() {
        guard let chapters = item?.chapters, !chapters.isEmpty else {
            currentChapterIndex = nil
            return
        }
        let index = chapters.lastIndex { $0.start <= position + 0.05 }
        if index != currentChapterIndex { currentChapterIndex = index }
    }

    // MARK: System

    private func updateNowPlaying() {
        guard let item else { return }
        lastNowPlayingUpdate = clock.now
        nowPlaying.update(.init(
            item: item, chapter: currentChapter, chapterIndex: currentChapterIndex, position: position,
            duration: duration, rate: settings.rate, isPlaying: isPlaying))
    }

    private func installRemoteCommands() {
        remote.install(
            .init(
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.togglePlayPause() },
                skip: { [weak self] in self?.skip(by: $0) },
                seek: { [weak self] in self?.seek(to: $0) },
                setRate: { [weak self] in self?.setRate($0) },
                nextChapter: { [weak self] in self?.nextChapter() },
                previousChapter: { [weak self] in self?.previousChapter() }),
            configuration: remoteCommands)
    }

    private func handleSessionEvent(_ event: AudioSessionController.Event) {
        switch event {
        case .interruptionBegan:
            if isPlaying {
                resumeAfterInterruption = true
                pause()
            }
        case .interruptionEnded(let shouldResume):
            if shouldResume && resumeAfterInterruption { play() }
            resumeAfterInterruption = false
        case .outputLost:
            pause()
        case .routeChanged(let newRoute):
            guard newRoute != route else { return }
            tick()
            route = newRoute
            if let closed = recorder.split(wall: clock.wallNow, content: position, removedTotal: smartSpeedRemovedEpisode, context: segmentContext) {
                segmentContinuation.yield(closed)
            }
        }
    }

    private func recoverFromConfigurationChange() {
        // The hardware format changed (e.g. a new output); the engine stopped. Restart where we were.
        guard backend == .engine, let active else { return }
        active.seek(to: active.poll().position ?? position, playing: isPlaying)
    }
}
