import Foundation

/// Pitch-synchronous time-domain speed change, tuned for speech (the approach of Bill Cox's Sonic,
/// which Android's ExoPlayer uses for podcast speed-up). It finds the local pitch period with AMDF,
/// then drops (or repeats) whole pitch periods, overlap-adding across each join. Because it only
/// ever removes whole glottal cycles, voices keep their pitch and formants and don't go phasey or
/// warbly the way a phase vocoder can at 2× and above. Music beds fare worse than with the
/// spectral unit, which is why both are offered.
struct SpeechStretcher {
    let sampleRate: Double
    let channelCount: Int
    var rate: Double = 1

    private let minPeriod: Int
    private let maxPeriod: Int
    private let maxRequired: Int
    private let skip: Int
    private var input: AudioChunk
    private var position = 0
    private var remainingInputToCopy = 0
    private var previousPeriod = 0
    private var previousMinDiff = 0.0
    private var mono: [Float] = []
    private var downsampled: [Float] = []

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        minPeriod = Int(sampleRate / 400)
        maxPeriod = Int(sampleRate / 65)
        maxRequired = 2 * maxPeriod
        skip = max(1, Int(sampleRate / 4000))
        input = AudioChunk(channelCount: channelCount)
    }

    mutating func reset() {
        input.removeAll()
        position = 0
        remainingInputToCopy = 0
        previousPeriod = 0
        previousMinDiff = 0
    }

    private var isUnity: Bool { abs(rate - 1) < 0.0001 }

    mutating func process(_ chunk: AudioChunk) -> AudioChunk {
        input.append(chunk)
        var output = AudioChunk(channelCount: channelCount, capacity: Int(Double(chunk.frameCount) / max(rate, 0.25)) + 64)
        if isUnity && remainingInputToCopy == 0 {
            output.append(input, range: position..<input.frameCount)
            input.removeAll()
            position = 0
            return output
        }
        while input.frameCount - position >= maxRequired {
            if remainingInputToCopy > 0 {
                let n = min(remainingInputToCopy, maxRequired)
                output.append(input, range: position..<(position + n))
                position += n
                remainingInputToCopy -= n
            } else if isUnity {
                output.append(input, range: position..<input.frameCount)
                position = input.frameCount
            } else {
                let period = findPitchPeriod(at: position)
                if rate > 1 {
                    position += period + skipPitchPeriod(at: position, period: period, into: &output)
                } else {
                    position += insertPitchPeriod(at: position, period: period, into: &output)
                }
            }
        }
        if position > 0 {
            input.removeFirst(position)
            position = 0
        }
        return output
    }

    /// Passes the last few milliseconds through unchanged.
    mutating func flush() -> AudioChunk {
        var output = AudioChunk(channelCount: channelCount)
        output.append(input, range: position..<input.frameCount)
        reset()
        return output
    }

    // MARK: Speed up / slow down

    private mutating func skipPitchPeriod(at pos: Int, period: Int, into output: inout AudioChunk) -> Int {
        let newSamples: Int
        if rate >= 2 {
            newSamples = Int(Double(period) / (rate - 1))
        } else {
            newSamples = period
            remainingInputToCopy = Int(Double(period) * (2 - rate) / (rate - 1))
        }
        overlapAdd(count: newSamples, rampDown: pos, rampUp: pos + period, into: &output)
        return newSamples
    }

    private mutating func insertPitchPeriod(at pos: Int, period: Int, into output: inout AudioChunk) -> Int {
        let newSamples: Int
        if rate < 0.5 {
            newSamples = Int(Double(period) * rate / (1 - rate))
        } else {
            newSamples = period
            remainingInputToCopy = Int(Double(period) * (2 * rate - 1) / (1 - rate))
        }
        output.append(input, range: pos..<(pos + period))
        overlapAdd(count: newSamples, rampDown: pos + period, rampUp: pos, into: &output)
        return newSamples
    }

    /// Linear crossfade from `rampDown` to `rampUp`. A convex blend, so it can't exceed the input peaks.
    private func overlapAdd(count: Int, rampDown: Int, rampUp: Int, into output: inout AudioChunk) {
        guard count > 0 else { return }
        let n = Float(count)
        for c in 0..<channelCount {
            input.channels[c].withUnsafeBufferPointer { src in
                for t in 0..<count {
                    let w = Float(t) / n
                    output.channels[c].append(src[rampDown + t] * (1 - w) + src[rampUp + t] * w)
                }
            }
        }
        for t in 0..<count {
            output.tags.append(t < count / 2 ? input.tags[rampDown + t] : input.tags[rampUp + t])
        }
    }

    // MARK: Pitch detection

    private mutating func findPitchPeriod(at pos: Int) -> Int {
        if mono.count != maxRequired { mono = Array(repeating: 0, count: maxRequired) }
        let scale = 1 / Float(channelCount)
        for i in 0..<maxRequired {
            var s: Float = 0
            for c in 0..<channelCount { s += input.channels[c][pos + i] }
            mono[i] = s * scale
        }
        var period: Int
        var minDiff: Double
        var maxDiff: Double
        if skip == 1 {
            (period, minDiff, maxDiff) = Self.amdf(mono, minPeriod, maxPeriod)
        } else {
            let count = maxRequired / skip
            if downsampled.count != count { downsampled = Array(repeating: 0, count: count) }
            for i in 0..<count {
                var s: Float = 0
                for j in 0..<skip { s += mono[i * skip + j] }
                downsampled[i] = s
            }
            let coarse = Self.amdf(downsampled, max(1, minPeriod / skip), maxPeriod / skip).period * skip
            (period, minDiff, maxDiff) = Self.amdf(
                mono, max(minPeriod, coarse - 4 * skip), min(maxPeriod, coarse + 4 * skip))
        }
        // Sonic's continuity rule: keep the previous period when this one is a poor, unvoiced match.
        var chosen = period
        if minDiff > 0, previousPeriod > 0, maxDiff <= minDiff * 3, minDiff * 2 > previousMinDiff * 3 {
            chosen = previousPeriod
        }
        previousMinDiff = minDiff
        previousPeriod = period
        return chosen
    }

    /// Average magnitude difference. Returns the best period plus the normalised min and max diffs.
    private static func amdf(_ s: [Float], _ minP: Int, _ maxP: Int) -> (period: Int, minDiff: Double, maxDiff: Double) {
        var best = minP, minDiff = Double.greatestFiniteMagnitude, maxDiff = 0.0
        s.withUnsafeBufferPointer { p in
            for period in minP...max(minP, maxP) where period * 2 <= p.count {
                var diff: Float = 0
                for i in 0..<period { diff += abs(p[i] - p[i + period]) }
                let normalised = Double(diff) / Double(period)
                if normalised < minDiff { minDiff = normalised; best = period }
                if normalised > maxDiff { maxDiff = normalised }
            }
        }
        return (best, minDiff, maxDiff)
    }
}
