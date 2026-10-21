import AVFoundation
import Foundation

/// Apple's phase-vocoder time-pitch unit (`AVAudioUnitTimePitch`), driven offline on the producer
/// thread through a private manual-rendering engine.
///
/// Why not in the realtime graph: the unit pulls ~2,000+ frames ahead of what it outputs, so the
/// player node's sample time runs ahead of what's audible by a rate-dependent amount, and positions
/// drift. Driven here, output frame k lines up with input frame k × rate. Apple's transient
/// preservation (left on: crisper consonants) re-times attacks after a silence by up to ~70 ms
/// locally, so positions on this path are good to about ±70 ms; the speech stretcher is exact.
final class SpectralStretcher {
    let sampleRate: Double
    let channelCount: Int
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(rate) }
    }

    private let engine = AVAudioEngine()
    private let timePitch = AVAudioUnitTimePitch()
    private let feed: Feed
    private let output: AVAudioPCMBuffer
    private let renderFrames: AVAudioFrameCount = 1_024
    /// Input frame (absolute) that the next output frame corresponds to.
    private var outputPosition: Double = 0
    private var unitIsFresh = true

    private var isUnity: Bool { abs(rate - 1) < 0.0001 }

    init(sampleRate: Double, channelCount: Int) throws {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
        else { throw PlaybackError.unsupportedFormat }
        self.output = output
        let feed = Feed(channelCount: channelCount)
        self.feed = feed
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            feed.render(Int(frameCount), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        engine.attach(source)
        engine.attach(timePitch)
        try engine.link(source, to: timePitch, format: format)
        try engine.link(timePitch, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    func reset() {
        feed.clear()
        outputPosition = 0
        resetUnit()
    }

    private func resetUnit() {
        guard !unitIsFresh else { return }
        engine.stop()
        engine.reset()
        try? engine.start()
        unitIsFresh = true
    }

    func process(_ chunk: AudioChunk) -> AudioChunk {
        feed.append(chunk)
        var out = AudioChunk(channelCount: channelCount)
        if isUnity {
            passThrough(into: &out)
        } else {
            enterUnitMode()
            // Keep a margin: the unit reads well ahead of what it outputs and must never starve.
            while Double(feed.end - feed.pulled) >= Double(renderFrames) * rate + 8_192 {
                renderOnce(into: &out)
            }
        }
        feed.trim(before: Int64(outputPosition) - 64)
        return out
    }

    func flush() -> AudioChunk {
        var out = AudioChunk(channelCount: channelCount)
        if isUnity {
            passThrough(into: &out)
        } else {
            enterUnitMode()
            feed.draining = true
            while outputPosition < Double(feed.end) {
                renderOnce(into: &out)
            }
        }
        reset()
        return out
    }

    private func passThrough(into out: inout AudioChunk) {
        let start = Int64(outputPosition)
        feed.copy(from: start, to: feed.end, into: &out)
        outputPosition = Double(feed.end)
        feed.pulled = feed.end
        resetUnit()
    }

    private func enterUnitMode() {
        if unitIsFresh {
            outputPosition = outputPosition.rounded(.down)
            feed.pulled = Int64(outputPosition)
            unitIsFresh = false
        }
    }

    private func renderOnce(into out: inout AudioChunk) {
        guard (try? engine.renderOffline(renderFrames, to: output)) == .success, let data = output.floatChannelData else {
            outputPosition = Double(feed.end)
            return
        }
        for k in 0..<Int(output.frameLength) {
            if let tag = feed.tag(at: Int64(outputPosition)) {
                for c in 0..<channelCount { out.channels[c].append(data[c][k]) }
                out.tags.append(tag)
            }
            outputPosition += rate
        }
    }

    /// Input frames for the unit, indexed absolutely. Only touched on the producer thread
    /// (manual rendering calls the source node synchronously).
    private final class Feed: @unchecked Sendable {
        var channels: [[Float]]
        var tags: [FrameTag] = []
        /// Absolute index of `channels[c][0]`.
        var base: Int64 = 0
        /// Absolute index of the next frame the unit will pull.
        var pulled: Int64 = 0
        var draining = false

        init(channelCount: Int) {
            channels = Array(repeating: [], count: channelCount)
        }

        var isEmpty: Bool { tags.isEmpty }
        var end: Int64 { base + Int64(tags.count) }

        func clear() {
            for c in channels.indices { channels[c].removeAll(keepingCapacity: true) }
            tags.removeAll(keepingCapacity: true)
            base = 0
            pulled = 0
            draining = false
        }

        func append(_ chunk: AudioChunk) {
            for c in channels.indices { channels[c].append(contentsOf: chunk.channels[c]) }
            tags.append(contentsOf: chunk.tags)
        }

        func tag(at index: Int64) -> FrameTag? {
            let i = Int(index - base)
            return i >= 0 && i < tags.count ? tags[i] : nil
        }

        func copy(from start: Int64, to stop: Int64, into out: inout AudioChunk) {
            let a = max(0, Int(start - base)), b = max(a, Int(stop - base))
            guard a < b else { return }
            for c in channels.indices { out.channels[c].append(contentsOf: channels[c][a..<b]) }
            out.tags.append(contentsOf: tags[a..<b])
        }

        func trim(before index: Int64) {
            let n = min(Int(min(index, pulled) - base), tags.count)
            guard n > 8_192 else { return }
            for c in channels.indices { channels[c].removeFirst(n) }
            tags.removeFirst(n)
            base += Int64(n)
        }

        func render(_ count: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
            for (c, buffer) in buffers.enumerated() {
                guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let source = channels[min(c, channels.count - 1)]
                for k in 0..<count {
                    let i = Int(pulled - base) + k
                    p[k] = i >= 0 && i < source.count ? source[i] : 0
                }
            }
            pulled += Int64(count)
        }
    }
}
