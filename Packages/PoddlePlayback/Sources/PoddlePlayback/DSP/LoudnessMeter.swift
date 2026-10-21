import AVFoundation
import Foundation

/// Integrated loudness per ITU-R BS.1770-4 / EBU R128: K-weighting, 400 ms blocks with 75% overlap,
/// an absolute gate at −70 LUFS and a relative gate 10 LU below the ungated mean.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    private var shelves: [Biquad]
    private var highPasses: [Biquad]
    private let subBlockFrames: Int
    private var subBlockFill = 0
    private var subBlockSum: Double = 0
    /// Mean K-weighted power (summed over channels) of each completed 100 ms sub-block.
    private var subBlocks: [Double] = []

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        shelves = Array(repeating: .kWeightingShelf(sampleRate: sampleRate), count: channelCount)
        highPasses = Array(repeating: .kWeightingHighPass(sampleRate: sampleRate), count: channelCount)
        subBlockFrames = max(1, Int((sampleRate * 0.1).rounded()))
    }

    /// Feeds deinterleaved samples. Channels are all weighted 1.0 (mono, stereo or L/R/C).
    public mutating func feed(_ channels: [UnsafeBufferPointer<Float>], frameCount: Int) {
        precondition(channels.count == channelCount)
        for i in 0..<frameCount {
            var sum = 0.0
            for c in 0..<channelCount {
                let y = highPasses[c].process(shelves[c].process(Double(channels[c][i])))
                sum += y * y
            }
            subBlockSum += sum
            subBlockFill += 1
            if subBlockFill == subBlockFrames {
                subBlocks.append(subBlockSum / Double(subBlockFrames))
                subBlockSum = 0
                subBlockFill = 0
            }
        }
    }

    public mutating func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        feed((0..<channelCount).map { UnsafeBufferPointer(start: data[$0], count: n) }, frameCount: n)
    }

    /// Integrated loudness in LUFS, or nil if nothing passed the absolute gate.
    public var integratedLoudness: Double? {
        guard subBlocks.count >= 4 else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count)
        for j in 3..<subBlocks.count {
            blocks.append((subBlocks[j] + subBlocks[j - 1] + subBlocks[j - 2] + subBlocks[j - 3]) / 4)
        }
        func lufs(_ power: Double) -> Double { -0.691 + powerToDB(power) }
        let absGated = blocks.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let relativeGate = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Measures a whole file offline. Run it off the main thread; an hour of stereo audio takes a second or two.
    public static func integratedLoudness(of url: URL) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var meter = LoudnessMeter(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }
        // Never read at the end: some decoders (AAC) throw there instead of returning zero frames.
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(65_536, file.length - file.framePosition)))
            if buffer.frameLength == 0 { break }
            meter.feed(buffer)
            try Task.checkCancellation()
        }
        return meter.integratedLoudness
    }

    /// The level a listener hears. A mono file plays on both speakers, so it's 3 dB louder than its
    /// single-channel BS.1770 reading; podcast loudness targets assume that (−16 stereo ≈ −19 mono).
    public static func perceivedLoudness(integrated: Double, channelCount: Int) -> Double {
        channelCount == 1 ? integrated + 3.01 : integrated
    }
}
