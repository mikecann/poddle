import AVFoundation
import Foundation

/// Decodes a local file and runs it through Smart Speed → Voice Boost → time-pitch (spectral or speech),
/// producing tagged PCM ahead of the playhead. Not thread-safe: one owner, one queue.
final class ContentPipeline {
    let file: AVAudioFile
    let format: AVAudioFormat
    let sampleRate: Double
    let channelCount: Int
    let totalFrames: Int64

    var voiceBoostEnabled = false {
        didSet {
            guard voiceBoostEnabled != oldValue else { return }
            if voiceBoostEnabled { voiceBoost.reset() } else { voiceBoostDrain = true }
        }
    }
    var smartSpeedEnabled: Bool {
        get { smartSpeed.isEnabled }
        set { smartSpeed.isEnabled = newValue }
    }
    var rate: Double = 1 {
        didSet {
            speechStretcher.rate = rate
            spectralStretcher.rate = rate
        }
    }
    /// Takes effect from the next seek.
    var algorithm: TimePitchAlgorithm = .spectral

    private var voiceBoost: VoiceBoostProcessor
    private var voiceBoostDrain = false
    private var smartSpeed: SilenceShortener
    private var speechStretcher: SpeechStretcher
    private let spectralStretcher: SpectralStretcher
    private var activeAlgorithm: TimePitchAlgorithm = .spectral
    private let readBuffer: AVAudioPCMBuffer
    private let readFrames: AVAudioFrameCount = 4_096
    private var readFrame: Int64 = 0
    private var startFrame: Int64 = 0
    private var finished = false
    private var drained = false
    private let prerollFrames: Int64

    init(url: URL, voiceBoost: VoiceBoostParameters = .init(), smartSpeed: SmartSpeedParameters = .init()) throws {
        file = try AVAudioFile(forReading: url)
        format = file.processingFormat
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        totalFrames = file.length
        self.voiceBoost = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channelCount, parameters: voiceBoost)
        self.smartSpeed = SilenceShortener(sampleRate: sampleRate, channelCount: channelCount, parameters: smartSpeed)
        speechStretcher = SpeechStretcher(sampleRate: sampleRate, channelCount: channelCount)
        spectralStretcher = try SpectralStretcher(sampleRate: sampleRate, channelCount: channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
            throw PlaybackError.unsupportedFormat
        }
        readBuffer = buffer
        // Warm up the leveler and silence statistics on audio before a seek point, so a seek
        // doesn't start with a gain ramp or naive thresholds.
        prerollFrames = Int64(sampleRate * 1.5)
    }

    var durationSeconds: Double { Double(totalFrames) / sampleRate }

    func setMeasuredLoudness(_ lufs: Double?) {
        voiceBoost.setMeasuredLoudness(lufs)
    }

    func seek(toFrame frame: Int64) {
        startFrame = min(max(0, frame), totalFrames)
        readFrame = max(0, startFrame - prerollFrames)
        file.framePosition = readFrame
        voiceBoost.reset()
        voiceBoostDrain = false
        smartSpeed.reset()
        speechStretcher.reset()
        spectralStretcher.reset()
        activeAlgorithm = algorithm
        finished = false
        drained = false
    }

    /// The next block of processed audio (possibly empty while lookahead fills), or nil once drained.
    func next() throws -> AudioChunk? {
        if drained { return nil }
        var chunk = AudioChunk(channelCount: channelCount)
        if !finished {
            readBuffer.frameLength = 0
            let remaining = totalFrames - file.framePosition
            if remaining > 0 {
                try file.read(into: readBuffer, frameCount: AVAudioFrameCount(min(Int64(readFrames), remaining)))
            }
            let n = Int(readBuffer.frameLength)
            if n == 0 {
                finished = true
            } else if let data = readBuffer.floatChannelData {
                chunk = AudioChunk(channelCount: channelCount, capacity: n)
                for c in 0..<channelCount {
                    chunk.channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n))
                }
                for i in 0..<n { chunk.tags.append(FrameTag(content: readFrame + Int64(i), edited: 0)) }
                readFrame += Int64(n)
            }
        }

        // Smart Speed first, so silence is judged on the raw signal (Voice Boost narrows the gap
        // between speech and room tone), then Voice Boost on what will actually play.
        chunk = smartSpeed.process(chunk)
        if finished { chunk.append(smartSpeed.flush()) }

        if voiceBoostEnabled {
            chunk = voiceBoost.process(chunk)
            if finished { chunk.append(voiceBoost.flush()) }
        } else if voiceBoostDrain {
            var drainedChunk = voiceBoost.flush()
            drainedChunk.append(chunk)
            chunk = drainedChunk
            voiceBoostDrain = false
        }

        if let first = chunk.tags.first, first.content < startFrame {
            let keep = chunk.tags.firstIndex { $0.content >= startFrame } ?? chunk.frameCount
            chunk.removeFirst(keep)
        }

        switch activeAlgorithm {
        case .timeDomain:
            chunk = speechStretcher.process(chunk)
            if finished { chunk.append(speechStretcher.flush()) }
        case .spectral:
            chunk = spectralStretcher.process(chunk)
            if finished { chunk.append(spectralStretcher.flush()) }
        }
        if finished { drained = true }
        return chunk
    }
}

/// Maps player frames (what the player node has played) back to content and edited frames.
/// Keeps one tag per `stride` frames, which bounds the error to well under a millisecond.
struct TimeMap {
    static let stride = 32
    private(set) var baseFrame: Int64 = 0
    private var tags: [FrameTag] = []
    private(set) var endFrame: Int64 = 0

    mutating func reset() {
        baseFrame = 0
        tags.removeAll(keepingCapacity: true)
        endFrame = 0
    }

    mutating func append(_ chunkTags: [FrameTag]) {
        // Keep the tags that sit on the stride grid (player frames that are multiples of `stride`).
        let s = Int64(Self.stride)
        var i = Int((s - endFrame % s) % s)
        while i < chunkTags.count {
            tags.append(chunkTags[i])
            i += Self.stride
        }
        endFrame += Int64(chunkTags.count)
    }

    func tag(atPlayerFrame frame: Int64) -> FrameTag? {
        guard !tags.isEmpty else { return nil }
        let index = Int((max(frame, baseFrame) - baseFrame) / Int64(Self.stride))
        let clamped = min(index, tags.count - 1)
        var tag = tags[clamped]
        // Add the offset within the stride, assuming 1:1 frames there.
        let within = max(0, min(frame, endFrame - 1) - baseFrame - Int64(clamped * Self.stride))
        tag.content += within
        tag.edited += within
        return tag
    }

    /// Drops tags before `frame` (they've been played).
    mutating func trim(before frame: Int64) {
        let s = Int64(Self.stride)
        let drop = Int((frame - baseFrame) / s) - 1
        guard drop > 4_096 else { return }
        tags.removeFirst(drop)
        baseFrame += Int64(drop) * s
    }
}
