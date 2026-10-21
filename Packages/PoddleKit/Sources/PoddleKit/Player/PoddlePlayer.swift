import Foundation
import Observation

/// What the screens use from a player. `MockPlayer` fakes playback for previews and screenshots;
/// the app's `EnginePlayer` drives PoddlePlayback's `PlaybackEngine`.
@MainActor
public protocol PoddlePlayer: AnyObject, Observable, Sendable {
    var store: PoddleStore { get }
    var currentEpisodeId: String? { get }
    var isPlaying: Bool { get }
    /// Streaming and waiting for data.
    var isBuffering: Bool { get }
    /// Content seconds.
    var position: Double { get }
    var duration: Double { get }
    var rate: Double { get }
    var chapters: [Chapter] { get }
    /// Content seconds Smart Speed has trimmed from this episode.
    var smartSaved: Double { get }
    var sleepTimer: SleepTimer { get }
    /// Wall-clock seconds until the sleep timer stops playback.
    var sleepRemaining: Double? { get }
    var routeName: String { get }
    /// "Choose the interval for this session" from a long-press on the skip buttons.
    var skipBackOverride: Double? { get set }
    var skipForwardOverride: Double? { get set }

    /// Loads an episode without playing it (used at launch to restore state).
    func load(_ episodeId: String, position: Double?, smartSaved: Double)
    /// Play now, from any screen. Whatever was playing moves down to second in the queue.
    func play(_ episodeId: String)
    func resume()
    func pause()
    func seek(to seconds: Double)
    func nextChapter()
    func previousChapter()
    func playNextInQueue()
    func setSleepTimer(_ timer: SleepTimer)
    /// Shake: a running minute timer starts again from full; one that just stopped playback restarts.
    func extendSleepTimer()
}

extension PoddlePlayer {
    public var item: EpisodeItem? { currentEpisodeId.flatMap { store.item($0) } }
    public var remaining: Double { max(0, duration - position) }
    public var wallRemaining: Double { remaining / rate }
    public var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    public var skipBack: Double { skipBackOverride ?? store.global.skipBack }
    public var skipForward: Double { skipForwardOverride ?? store.global.skipForward }

    public var currentChapterIndex: Int? {
        chapters.lastIndex { $0.start <= position + 0.5 }
    }
    public var currentChapter: Chapter? { currentChapterIndex.map { chapters[$0] } }

    public func load(_ episodeId: String) { load(episodeId, position: nil, smartSaved: 0) }
    public func togglePlayPause() { isPlaying ? pause() : resume() }
    public func skipForwardTapped() { seek(to: position + skipForward) }
    public func skipBackTapped() { seek(to: position - skipBack) }
    public func seek(toChapter chapter: Chapter) { seek(to: chapter.start) }

    public func setSleepMinutes(_ minutes: Int) {
        setSleepTimer(.minutes(minutes, endsAt: Date().addingTimeInterval(Double(minutes) * 60)))
    }
}
