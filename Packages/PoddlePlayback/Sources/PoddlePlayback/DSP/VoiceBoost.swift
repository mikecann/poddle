import Foundation

public struct VoiceBoostParameters: Sendable, Equatable {
    public var highPassHz = 80.0
    /// A broad, gentle lift where consonants live, for intelligibility on earbuds and in the car.
    public var presenceHz = 3_000.0
    public var presenceQ = 0.8
    public var presenceGainDB = 3.0
    /// Target perceived loudness (stereo-equivalent integrated LUFS).
    public var targetLUFS = -16.0
    /// How far the leveler may move away from the static normalisation gain, each way.
    public var levelerRangeDB = 12.0
    /// Used instead when the file's loudness hasn't been measured yet.
    public var levelerRangeUnmeasuredDB = 15.0
    /// The leveler looks this far ahead so it turns a loud speaker down before they start, not after.
    public var levelerLookahead = 0.3
    /// Speech loudness is measured over this window. Long enough to keep the natural rise and fall
    /// of phrases (loudness range stays ~2–3 LU), short enough to catch a change of speaker.
    public var levelerWindow = 1.0
    public var levelerFallTime = 0.6
    public var levelerRiseTime = 2.0
    /// 10 ms slices quieter than this (after static gain) are ignored by the leveler, and it holds its
    /// gain when there's too little speech in the window, so pauses and breaths aren't pumped up.
    public var levelerGateBelowTargetDB = 20.0
    public var compressorThresholdDB = -14.0
    public var compressorRatio = 2.5
    public var compressorKneeDB = 6.0
    public var compressorAttack = 0.003
    public var compressorRelease = 0.15
    public var makeupGainDB = 2.1
    public var limiterCeilingDB = -1.5
    public var limiterLookahead = 0.005
    public var limiterRelease = 0.08

    public init() {}
}

/// Voice Boost: high-pass, presence EQ, loudness normalisation towards −16 LUFS, a lookahead
/// leveler (so a quiet guest and a loud host end up at the same level), a gentle compressor and a
/// lookahead peak limiter. It runs on decoded content ahead of the playhead, so it can afford
/// lookahead without adding playback latency.
struct VoiceBoostProcessor {
    let sampleRate: Double
    let channelCount: Int
    let parameters: VoiceBoostParameters

    private var highPass: [Biquad]
    private var presence: [Biquad]
    private var kShelf: [Biquad]
    private var kHighPass: [Biquad]

    private var staticGainDB = 0.0
    private var loudnessKnown = false

    // Leveler
    private let windowFrames: Int
    private let lookaheadFrames: Int
    private var windowPowers: [Double]
    private var windowPowerIndex = 0
    private var windowPowerCount = 0
    private var windowAccumulator = 0.0
    private var windowFill = 0
    private var gainDB = 0.0
    private let fallCoef: Double
    private let riseCoef: Double
    private var pending: AudioChunk
    private var pendingRead = 0

    // Compressor
    private var envelope = 0.0
    private let attackCoef: Double
    private let releaseCoef: Double
    private let makeup: Double

    private var limiter: LookaheadLimiter
    private var frameScratch: [Float]

    init(sampleRate: Double, channelCount: Int, parameters: VoiceBoostParameters = .init()) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.parameters = parameters
        let p = parameters
        highPass = Array(repeating: .highPass(frequency: p.highPassHz, sampleRate: sampleRate), count: channelCount)
        presence = Array(
            repeating: .peaking(frequency: p.presenceHz, q: p.presenceQ, gainDB: p.presenceGainDB, sampleRate: sampleRate),
            count: channelCount)
        kShelf = Array(repeating: .kWeightingShelf(sampleRate: sampleRate), count: channelCount)
        kHighPass = Array(repeating: .kWeightingHighPass(sampleRate: sampleRate), count: channelCount)
        windowFrames = max(1, Int(sampleRate * 0.01))
        lookaheadFrames = Int(sampleRate * p.levelerLookahead)
        windowPowers = Array(repeating: 0, count: max(1, Int((p.levelerWindow / 0.01).rounded())))
        fallCoef = 1 - exp(-0.01 / p.levelerFallTime)
        riseCoef = 1 - exp(-0.01 / p.levelerRiseTime)
        pending = AudioChunk(channelCount: channelCount)
        attackCoef = 1 - exp(-1 / (p.compressorAttack * sampleRate))
        releaseCoef = 1 - exp(-1 / (p.compressorRelease * sampleRate))
        makeup = dbToGain(p.makeupGainDB)
        limiter = LookaheadLimiter(
            channelCount: channelCount, lookaheadFrames: max(1, Int(sampleRate * p.limiterLookahead)),
            ceiling: Float(dbToGain(p.limiterCeilingDB)), releaseCoef: Float(1 - exp(-1 / (p.limiterRelease * sampleRate))))
        frameScratch = Array(repeating: 0, count: channelCount)
    }

    /// Frames held back by lookahead.
    var latencyFrames: Int { lookaheadFrames + limiter.lookaheadFrames }

    /// Sets the static normalisation gain from a measured integrated loudness (BS.1770, as measured).
    mutating func setMeasuredLoudness(_ lufs: Double?) {
        if let lufs {
            let perceived = LoudnessMeter.perceivedLoudness(integrated: lufs, channelCount: channelCount)
            staticGainDB = min(15, max(-15, parameters.targetLUFS - perceived))
            loudnessKnown = true
        } else {
            staticGainDB = 0
            loudnessKnown = false
        }
    }

    mutating func reset() {
        for c in 0..<channelCount {
            highPass[c].reset(); presence[c].reset(); kShelf[c].reset(); kHighPass[c].reset()
        }
        for i in windowPowers.indices { windowPowers[i] = 0 }
        windowPowerIndex = 0; windowPowerCount = 0; windowAccumulator = 0; windowFill = 0
        gainDB = staticGainDB
        pending.removeAll(); pendingRead = 0
        envelope = 0
        limiter.reset()
    }

    mutating func process(_ input: AudioChunk) -> AudioChunk {
        var output = AudioChunk(channelCount: channelCount, capacity: input.frameCount)
        let channelWeight = channelCount == 1 ? 2.0 : 1.0
        for i in 0..<input.frameCount {
            var power = 0.0
            for c in 0..<channelCount {
                let x = presence[c].process(highPass[c].process(Double(input.channels[c][i])))
                pending.channels[c].append(Float(x))
                let k = kHighPass[c].process(kShelf[c].process(x))
                power += k * k
            }
            pending.tags.append(input.tags[i])
            windowAccumulator += power * channelWeight
            windowFill += 1
            if windowFill == windowFrames {
                completeWindow(into: &output)
            }
        }
        return output
    }

    /// Drains everything held back by lookahead.
    mutating func flush() -> AudioChunk {
        var output = AudioChunk(channelCount: channelCount)
        let remaining = pending.frameCount - pendingRead
        emit(remaining, fromGain: gainDB, toGain: gainDB, into: &output)
        limiter.flush(into: &output)
        pending.removeAll(); pendingRead = 0
        return output
    }

    private mutating func completeWindow(into output: inout AudioChunk) {
        let p = parameters
        windowPowers[windowPowerIndex] = windowAccumulator / Double(windowFrames)
        windowPowerIndex = (windowPowerIndex + 1) % windowPowers.count
        windowPowerCount = min(windowPowerCount + 1, windowPowers.count)
        windowAccumulator = 0
        windowFill = 0

        // Loudness of the speech in the window: 10 ms slices that are pauses or breaths don't count,
        // so a speaker's level is measured, not how much they pause.
        let gatePower = pow(10, (p.targetLUFS - p.levelerGateBelowTargetDB - staticGainDB + 0.691) / 10)
        var activePower = 0.0, activeCount = 0
        for power in windowPowers where power > gatePower {
            activePower += power
            activeCount += 1
        }
        let momentary = -0.691 + powerToDB(activePower / Double(max(activeCount, 1)))
        let previousGain = gainDB
        if activeCount >= windowPowers.count / 4 {
            let range = loudnessKnown ? p.levelerRangeDB : p.levelerRangeUnmeasuredDB
            let desired = min(staticGainDB + range, max(staticGainDB - range, p.targetLUFS - momentary))
            gainDB += (desired - gainDB) * (desired < gainDB ? fallCoef : riseCoef)
        }
        let ready = pending.frameCount - pendingRead - lookaheadFrames
        if ready > 0 { emit(ready, fromGain: previousGain, toGain: gainDB, into: &output) }
        if pendingRead > 16_384 {
            pending.removeFirst(pendingRead)
            pendingRead = 0
        }
    }

    private mutating func emit(_ count: Int, fromGain: Double, toGain: Double, into output: inout AudioChunk) {
        guard count > 0 else { return }
        let p = parameters
        let g0 = dbToGain(fromGain), g1 = dbToGain(toGain)
        for j in 0..<count {
            let index = pendingRead + j
            let levelerGain = g0 + (g1 - g0) * Double(j + 1) / Double(count)
            var peak = 0.0
            for c in 0..<channelCount {
                let x = Double(pending.channels[c][index]) * levelerGain
                frameScratch[c] = Float(x)
                peak = max(peak, abs(x))
            }
            // Peak-envelope compressor with a soft knee, stereo-linked.
            envelope += (peak - envelope) * (peak > envelope ? attackCoef : releaseCoef)
            let over = 20 * log10(max(envelope, 1e-9)) - p.compressorThresholdDB
            let slope = 1 / p.compressorRatio - 1
            var reductionDB = 0.0
            if over >= p.compressorKneeDB / 2 {
                reductionDB = slope * over
            } else if over > -p.compressorKneeDB / 2 {
                let t = over + p.compressorKneeDB / 2
                reductionDB = slope * t * t / (2 * p.compressorKneeDB)
            }
            let g = Float(dbToGain(reductionDB) * makeup)
            for c in 0..<channelCount { frameScratch[c] *= g }
            limiter.push(frameScratch, tag: pending.tags[index], into: &output)
        }
        pendingRead += count
    }
}

/// A brickwall peak limiter with lookahead. The gain is the minimum required gain over the lookahead
/// window, smoothed by a box filter of the same length, so it reaches the required gain exactly as
/// the peak arrives and never steps (no clicks), then recovers with a one-pole release.
struct LookaheadLimiter {
    let channelCount: Int
    let lookaheadFrames: Int
    let ceiling: Float
    let releaseCoef: Float

    private var delay: [[Float]]
    private var delayTags: [FrameTag?]
    private var box: [Float]
    private var boxSum: Double
    private var boxIndex = 0
    private var dequeIndex: [Int64] = []
    private var dequeValue: [Float] = []
    private var dequeHead = 0
    private var frameIndex: Int64 = 0
    private var gain: Float = 1
    private var zeros: [Float]

    init(channelCount: Int, lookaheadFrames: Int, ceiling: Float, releaseCoef: Float) {
        self.channelCount = channelCount
        self.lookaheadFrames = lookaheadFrames
        self.ceiling = ceiling
        self.releaseCoef = releaseCoef
        delay = Array(repeating: Array(repeating: 0, count: lookaheadFrames + 1), count: channelCount)
        delayTags = Array(repeating: nil, count: lookaheadFrames + 1)
        box = Array(repeating: 1, count: lookaheadFrames + 1)
        boxSum = Double(lookaheadFrames + 1)
        zeros = Array(repeating: 0, count: channelCount)
    }

    mutating func reset() {
        self = LookaheadLimiter(channelCount: channelCount, lookaheadFrames: lookaheadFrames, ceiling: ceiling, releaseCoef: releaseCoef)
    }

    mutating func push(_ frame: [Float], tag: FrameTag?, into output: inout AudioChunk) {
        let size = lookaheadFrames + 1
        var peak: Float = 0
        for c in 0..<channelCount { peak = max(peak, abs(frame[c])) }
        let required: Float = peak > ceiling ? ceiling / peak : 1

        // Sliding minimum of `required` over the last lookahead+1 frames.
        while dequeValue.count > dequeHead, dequeValue[dequeValue.count - 1] >= required {
            dequeValue.removeLast(); dequeIndex.removeLast()
        }
        dequeValue.append(required); dequeIndex.append(frameIndex)
        while dequeIndex[dequeHead] <= frameIndex - Int64(size) { dequeHead += 1 }
        if dequeHead > 1024 {
            dequeValue.removeFirst(dequeHead); dequeIndex.removeFirst(dequeHead); dequeHead = 0
        }
        let windowMin = dequeValue[dequeHead]

        boxSum += Double(windowMin - box[boxIndex])
        box[boxIndex] = windowMin
        boxIndex = (boxIndex + 1) % size
        let smoothed = Float(boxSum / Double(size))
        gain = smoothed < gain ? smoothed : gain + (smoothed - gain) * releaseCoef
        if boxIndex == 0 { boxSum = Double(box.reduce(0, +)) }  // stop float drift

        let slot = Int(frameIndex % Int64(size))
        for c in 0..<channelCount { delay[c][slot] = frame[c] }
        delayTags[slot] = tag
        let oldest = Int((frameIndex + 1) % Int64(size))
        if let oldTag = delayTags[oldest] {
            for c in 0..<channelCount { output.channels[c].append(min(ceiling, max(-ceiling, delay[c][oldest] * gain))) }
            output.tags.append(oldTag)
            delayTags[oldest] = nil
        }
        frameIndex += 1
    }

    mutating func flush(into output: inout AudioChunk) {
        for _ in 0..<lookaheadFrames { push(zeros, tag: nil, into: &output) }
    }
}
