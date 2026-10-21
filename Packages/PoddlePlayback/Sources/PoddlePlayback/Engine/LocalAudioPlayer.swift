import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// The settings that change what the audio graph does.
public struct AudioSettings: Sendable, Equatable {
    public var rate: Double
    public var algorithm: TimePitchAlgorithm
    public var smartSpeed: Bool
    public var voiceBoost: Bool

    public init(rate: Double = 1, algorithm: TimePitchAlgorithm = .spectral, smartSpeed: Bool = true, voiceBoost: Bool = true) {
        self.rate = rate
        self.algorithm = algorithm
        self.smartSpeed = smartSpeed
        self.voiceBoost = voiceBoost
    }
}

/// Plays a local file through AVAudioEngine:
///
///     decode → Smart Speed → Voice Boost → time-pitch → player node → safety limiter → mixer
///
/// Everything before the player node runs on a producer queue about half a second ahead of the
/// playhead, and every scheduled frame carries its content position, so position, seeks and chapters
/// stay in content time. The realtime graph has no time-varying nodes, so the player node's sample
/// time is exactly what's audible.
final class LocalAudioPlayer: @unchecked Sendable {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let safetyLimiter: AVAudioUnitEffect
    /// Apple's peak limiter clamps at 0 dBFS; this trims its output so peaks stay under −1 dBFS.
    let outputTrim = AVAudioUnitEQ(numberOfBands: 0)
    let format: AVAudioFormat
    let sampleRate: Double
    let durationSeconds: Double
    let isOffline: Bool

    private let pipeline: ContentPipeline
    private let queue = DispatchQueue(label: "com.mikecann.poddle.playback.producer", qos: .userInitiated)

    private struct Shared {
        var map = TimeMap()
        var eof = false
        var lookaheadFrames: Int64 = 0
        var lastTag: FrameTag?
        var startFrame: Int64 = 0
    }
    private let shared = Mutex(Shared())

    // Queue-confined.
    private var generation = 0

    private(set) var settings: AudioSettings
    private var configurationObserver: (any NSObjectProtocol)?

    /// - Parameter offlineFormat: when set, the engine runs in offline manual-rendering mode with this output format.
    init(url: URL, settings: AudioSettings, loudness: Double?, offlineFormat: AVAudioFormat? = nil,
         voiceBoost: VoiceBoostParameters = .init(), smartSpeed: SmartSpeedParameters = .init()) throws {
        pipeline = try ContentPipeline(url: url, voiceBoost: voiceBoost, smartSpeed: smartSpeed)
        pipeline.setMeasuredLoudness(loudness)
        format = pipeline.format
        sampleRate = pipeline.sampleRate
        durationSeconds = pipeline.durationSeconds
        self.settings = settings
        isOffline = offlineFormat != nil

        let limiterDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        safetyLimiter = AVAudioUnitEffect(audioComponentDescription: limiterDescription)

        if let offlineFormat {
            try engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4_096)
        }
        engine.attach(player)
        engine.attach(safetyLimiter)
        engine.attach(outputTrim)
        try engine.link(player, to: safetyLimiter, format: format)
        try engine.link(safetyLimiter, to: outputTrim, format: format)
        try engine.link(outputTrim, to: engine.mainMixerNode, format: format)
        configureSafetyLimiter()
        applyRealtimeSettings()
        engine.prepare()
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        player.stop()
        engine.stop()
    }

    /// Called (on an arbitrary thread) when the hardware configuration changes and the engine stopped.
    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in handler() }
    }

    private func configureSafetyLimiter() {
        // Phase-vocoder resynthesis can overshoot the pre-limited peaks a little; this catches it.
        // Parameters: 0 attack (s), 1 decay (s), 2 pre-gain (dB).
        safetyLimiter.setParameter(0, to: 0.002)
        safetyLimiter.setParameter(1, to: 0.03)
    }

    private func applyRealtimeSettings() {
        let stretching = settings.algorithm == .spectral && abs(settings.rate - 1) > 0.001
        // The phase vocoder loses level as it speeds up (measured on speech: −0.5 dB at 1.25×,
        // −1.7 dB at 2×, −2.6 dB at 3×), which would also bias a spectral vs time-domain A/B.
        // Make it up with the limiter's pre-gain; the limiter then catches any resynthesis overshoot,
        // and the trim after it keeps peaks under −1 dBFS.
        let headroom = 1.5
        let makeup = stretching && settings.rate > 1 ? 2.4 * log(settings.rate) : 0
        safetyLimiter.bypass = !stretching
        outputTrim.bypass = !stretching
        safetyLimiter.setParameter(2, to: AUValue(makeup + headroom))
        outputTrim.globalGain = Float(-headroom)
        shared.withLock { $0.lookaheadFrames = Int64(0.5 * sampleRate) }
    }

    private func applyPipelineSettings() {
        pipeline.voiceBoostEnabled = settings.voiceBoost
        pipeline.smartSpeedEnabled = settings.smartSpeed
        pipeline.rate = settings.rate
        pipeline.algorithm = settings.algorithm
    }

    func setMeasuredLoudness(_ lufs: Double?) {
        queue.async { self.pipeline.setMeasuredLoudness(lufs) }
    }

    /// Applies new settings. They take effect once the already-scheduled lookahead has played
    /// (about half a second), which keeps changes glitch-free. Switching algorithm restarts the
    /// producer at the current position.
    func apply(_ newSettings: AudioSettings) {
        let algorithmChanged = newSettings.algorithm != settings.algorithm
        settings = newSettings
        applyRealtimeSettings()
        if algorithmChanged {
            start(atContentSeconds: currentContentSeconds() ?? 0, playing: player.isPlaying)
        } else {
            queue.async { self.applyPipelineSettings() }
        }
    }

    // MARK: Transport

    func start(atContentSeconds seconds: Double, playing: Bool) {
        let frame = Int64(max(0, min(seconds, durationSeconds)) * sampleRate)
        let current = queue.sync {
            generation += 1
            player.stop()
            shared.withLock {
                $0.map.reset()
                $0.eof = false
                $0.lastTag = FrameTag(content: frame, edited: 0)
                $0.startFrame = frame
            }
            applyPipelineSettings()
            pipeline.seek(toFrame: frame)
            fill(generation: generation, target: Int64(0.25 * sampleRate))
            return generation
        }
        if playing { play() }
        queue.async { self.fill(generation: current, target: nil) }
    }

    func play() {
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        try? player.start()
    }

    func pause() {
        player.pause()
        if !isOffline { engine.pause() }
    }

    func stop() {
        queue.sync {
            generation += 1
            player.stop()
        }
        engine.stop()
    }

    var isPlaying: Bool { player.isPlaying }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    // MARK: Position

    func playerSampleTime() -> Int64? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid
        else { return nil }
        return time.sampleTime
    }

    /// The tag of the frame at the playhead: its content frame and edited (post-Smart-Speed) frame.
    func currentTag() -> FrameTag? {
        let sampleTime = playerSampleTime()
        return shared.withLock { state in
            if let sampleTime, sampleTime >= 0, state.map.endFrame > 0,
               let tag = state.map.tag(atPlayerFrame: min(sampleTime, state.map.endFrame - 1)) {
                state.lastTag = tag
                state.map.trim(before: sampleTime - Int64(sampleRate * 5))
            }
            return state.lastTag
        }
    }

    func currentContentSeconds() -> Double? {
        currentTag().map { Double($0.content) / sampleRate }
    }

    /// True once every scheduled frame of the final block has played.
    var reachedEnd: Bool {
        let sampleTime = playerSampleTime() ?? 0
        return shared.withLock { $0.eof && sampleTime >= $0.map.endFrame }
    }

    var hasUnderrun: Bool {
        guard let sampleTime = playerSampleTime() else { return false }
        return shared.withLock { !$0.eof && sampleTime >= $0.map.endFrame }
    }

    // MARK: Producer

    /// Offline rendering: makes sure enough audio is scheduled before rendering the next block.
    func fillSynchronously() {
        queue.sync { fill(generation: generation, target: nil) }
    }

    private func fill(generation fillGeneration: Int, target: Int64?) {
        guard fillGeneration == generation else { return }
        let played = max(0, playerSampleTime() ?? 0)
        let wanted = target ?? shared.withLock { $0.lookaheadFrames }
        while true {
            let (end, eof) = shared.withLock { ($0.map.endFrame, $0.eof) }
            if eof || end - played >= wanted { return }
            let chunk: AudioChunk?
            do { chunk = try pipeline.next() } catch { chunk = nil }
            guard let chunk else {
                shared.withLock { $0.eof = true }
                return
            }
            if !chunk.isEmpty { schedule(chunk, generation: fillGeneration) }
        }
    }

    private func schedule(_ chunk: AudioChunk, generation scheduleGeneration: Int) {
        let n = chunk.frameCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let data = buffer.floatChannelData else { return }
        for c in 0..<chunk.channelCount {
            chunk.channels[c].withUnsafeBufferPointer { src in
                data[c].update(from: src.baseAddress!, count: n)
            }
        }
        buffer.frameLength = AVAudioFrameCount(n)
        shared.withLock { $0.map.append(chunk.tags) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.fill(generation: scheduleGeneration, target: nil) }
        }
    }
}
