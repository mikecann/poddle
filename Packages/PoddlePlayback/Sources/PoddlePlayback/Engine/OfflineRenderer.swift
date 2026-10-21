import AVFoundation
import Foundation

/// Accumulates content Smart Speed removed between successive playhead tags.
struct SmartSpeedAccumulator: Sendable {
    private var previous: FrameTag?
    private(set) var removedFrames: Int64 = 0

    mutating func reset() { previous = nil }

    mutating func update(_ tag: FrameTag) {
        defer { previous = tag }
        guard let previous, tag.content >= previous.content, tag.edited >= previous.edited else { return }
        removedFrames += max(0, (tag.content - previous.content) - (tag.edited - previous.edited))
    }
}

public struct RenderOptions: Sendable {
    public var settings: AudioSettings
    /// Integrated loudness of the input, as `LoudnessMeter` reports it.
    public var loudness: Double?
    /// Content seconds to start from.
    public var start: Double
    /// Content seconds to render. Nil renders to the end.
    public var contentDuration: Double?
    /// Frames per offline render call; also the resolution of `RenderReport.positions`.
    public var quantum: Int

    public init(settings: AudioSettings, loudness: Double? = nil, start: Double = 0, contentDuration: Double? = nil, quantum: Int = 1_024) {
        self.settings = settings
        self.loudness = loudness
        self.start = start
        self.contentDuration = contentDuration
        self.quantum = quantum
    }
}

public struct RenderReport: Sendable {
    public struct PositionSample: Sendable {
        public var outputFrame: Int
        public var contentSeconds: Double
    }
    public var sampleRate: Double
    public var outputSeconds: Double
    public var contentSeconds: Double
    public var smartSpeedRemovedSeconds: Double
    public var peakDBFS: Double
    /// The engine's reported content position at the start of each render quantum.
    public var positions: [PositionSample]

    /// Content position at an output frame, interpolated between render quanta.
    public func contentSeconds(atOutputFrame frame: Int) -> Double? {
        guard let i = positions.lastIndex(where: { $0.outputFrame <= frame }) else { return nil }
        let a = positions[i]
        guard i + 1 < positions.count else { return a.contentSeconds }
        let b = positions[i + 1]
        let t = Double(frame - a.outputFrame) / Double(b.outputFrame - a.outputFrame)
        return a.contentSeconds + (b.contentSeconds - a.contentSeconds) * t
    }
}

/// Renders a file through the exact playback graph using AVAudioEngine's offline manual rendering.
/// Used by the tests and by `poddle-render` for listening checks.
public enum OfflineRenderer {
    public static func render(input: URL, output: URL? = nil, options: RenderOptions,
                              voiceBoost: VoiceBoostParameters = .init(), smartSpeed: SmartSpeedParameters = .init(),
                              onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) throws -> RenderReport {
        let probe = try AVAudioFile(forReading: input)
        let sampleRate = probe.processingFormat.sampleRate
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw PlaybackError.unsupportedFormat
        }
        let player = try LocalAudioPlayer(
            url: input, settings: options.settings, loudness: options.loudness, offlineFormat: renderFormat,
            voiceBoost: voiceBoost, smartSpeed: smartSpeed)
        let outputFile = try output.map { url in
            try? FileManager.default.removeItem(at: url)
            return try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000,
                ],
                commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(options.quantum)) else {
            throw PlaybackError.unsupportedFormat
        }

        player.start(atContentSeconds: options.start, playing: true)
        var accumulator = SmartSpeedAccumulator()
        var positions: [RenderReport.PositionSample] = []
        var outputFrames = 0
        var peak: Float = 0
        var lastContent = options.start
        let end = options.contentDuration.map { options.start + $0 } ?? .infinity
        let limit = Int(sampleRate * (player.durationSeconds - options.start) * 2.5) + Int(sampleRate * 10)

        while outputFrames < limit {
            player.fillSynchronously()
            if let tag = player.currentTag() {
                accumulator.update(tag)
                lastContent = Double(tag.content) / sampleRate
            }
            positions.append(.init(outputFrame: outputFrames, contentSeconds: lastContent))
            if player.reachedEnd || lastContent >= end { break }

            let status = try player.engine.renderOffline(AVAudioFrameCount(options.quantum), to: buffer)
            guard status == .success else {
                if status == .error { throw PlaybackError.unsupportedFormat }
                continue
            }
            let n = Int(buffer.frameLength)
            if let data = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<n { peak = max(peak, abs(data[c][i])) }
                }
            }
            try outputFile?.write(from: buffer)
            onBuffer?(buffer)
            outputFrames += n
        }
        player.stop()

        return RenderReport(
            sampleRate: sampleRate,
            outputSeconds: Double(outputFrames) / sampleRate,
            contentSeconds: lastContent - options.start,
            smartSpeedRemovedSeconds: Double(accumulator.removedFrames) / sampleRate,
            peakDBFS: 20 * log10(max(Double(peak), 1e-9)),
            positions: positions)
    }
}
