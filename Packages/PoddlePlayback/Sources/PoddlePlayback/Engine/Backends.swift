import AVFoundation
import Foundation

@MainActor
protocol PlaybackBackend: AnyObject {
    /// Content seconds at the playhead, plus content Smart Speed removed since the last poll.
    func poll() -> (position: Double?, smartRemoved: Double)
    var duration: Double? { get }
    var isBuffering: Bool { get }
    var reachedEnd: Bool { get }
    var volume: Float { get set }
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double, playing: Bool)
    func apply(_ settings: AudioSettings)
    func setMeasuredLoudness(_ lufs: Double?)
}

/// Local files: the AVAudioEngine graph with Smart Speed and Voice Boost.
@MainActor
final class EngineBackend: PlaybackBackend {
    let player: LocalAudioPlayer
    private var accumulator = SmartSpeedAccumulator()
    private var reportedRemovedFrames: Int64 = 0

    init(url: URL, settings: AudioSettings, loudness: Double?, onConfigurationChange: @escaping @MainActor () -> Void) throws {
        player = try LocalAudioPlayer(url: url, settings: settings, loudness: loudness)
        player.observeConfigurationChanges {
            Task { @MainActor in onConfigurationChange() }
        }
    }

    func poll() -> (position: Double?, smartRemoved: Double) {
        guard let tag = player.currentTag() else { return (nil, 0) }
        accumulator.update(tag)
        let delta = accumulator.removedFrames - reportedRemovedFrames
        reportedRemovedFrames = accumulator.removedFrames
        return (Double(tag.content) / player.sampleRate, Double(delta) / player.sampleRate)
    }

    var duration: Double? { player.durationSeconds }
    var isBuffering: Bool { player.hasUnderrun }
    var reachedEnd: Bool { player.reachedEnd }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }

    func seek(to seconds: Double, playing: Bool) {
        accumulator.reset()
        player.start(atContentSeconds: seconds, playing: playing)
    }

    func apply(_ settings: AudioSettings) { player.apply(settings) }
    func setMeasuredLoudness(_ lufs: Double?) { player.setMeasuredLoudness(lufs) }
}

/// Not downloaded yet: AVPlayer with pitch-corrected rate. Speed only.
@MainActor
final class StreamingBackend: PlaybackBackend {
    let player: AVPlayer
    let item: AVPlayerItem
    private var settings: AudioSettings
    private var loadedDuration: Double?
    private var didFinish = false
    private var endObserver: (any NSObjectProtocol)?

    init(url: URL, settings: AudioSettings) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.settings = settings
        apply(settings)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish = true }
        }
        Task { [weak self, item] in
            let duration = try? await item.asset.load(.duration)
            if let duration, duration.isNumeric { self?.loadedDuration = duration.seconds }
        }
    }

    isolated deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func poll() -> (position: Double?, smartRemoved: Double) {
        let t = player.currentTime()
        return (t.isNumeric ? t.seconds : nil, 0)
    }

    var duration: Double? { loadedDuration }
    var isBuffering: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var reachedEnd: Bool { didFinish }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play() {
        didFinish = false
        player.playImmediately(atRate: Float(settings.rate))
    }

    func pause() { player.pause() }
    func stop() { player.pause() }

    func seek(to seconds: Double, playing: Bool) {
        didFinish = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if playing { play() }
    }

    func apply(_ settings: AudioSettings) {
        self.settings = settings
        item.audioTimePitchAlgorithm = settings.algorithm == .spectral ? .spectral : .timeDomain
        player.defaultRate = Float(settings.rate)
        if player.rate != 0 { player.rate = Float(settings.rate) }
    }

    func setMeasuredLoudness(_ lufs: Double?) {}
}
