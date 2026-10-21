import Foundation

public struct SmartSpeedParameters: Sendable, Equatable {
    /// Analysis window.
    public var window = 0.01
    /// Gaps shorter than this are left alone (natural rhythm between words).
    public var minimumGap = 0.25
    /// Silence kept in a shortened gap, split between both edges so word tails and breaths-in survive.
    public var keptGap = 0.12
    /// Equal-power crossfade at the cut, so room tone joins without a click.
    public var crossfade = 0.012
    /// A single gap is never shortened by more than this, so deliberate pauses don't vanish.
    public var maximumRemovalPerGap = 2.0
    /// Silence threshold relative to the speech level (rolling 90th percentile of window levels).
    public var belowSpeechDB = 25.0
    /// Silence threshold relative to the noise floor (rolling 5th percentile).
    public var aboveNoiseDB = 6.0
    /// Never call anything within this distance of the speech level silent (protects quiet speech).
    public var minimumBelowSpeechDB = 12.0
    /// Time constant of the rolling level statistics.
    public var statisticsTimeConstant = 20.0

    public init() {}
}

/// Smart Speed: shortens silent gaps. It classifies 10 ms windows against a threshold that adapts to
/// the speech level and the noise floor, buffers a silent run until it ends (or until the run is long
/// enough that the cut is decided anyway), then removes the middle of the run with a crossfade.
/// Content tags pass through, so every output frame still knows its content time.
struct SilenceShortener {
    let sampleRate: Double
    let channelCount: Int
    let parameters: SmartSpeedParameters
    var isEnabled = true {
        didSet { if !isEnabled && oldValue { disabling = true } }
    }

    private(set) var removedFrames: Int64 = 0
    private var editedCounter: Int64 = 0
    private var disabling = false

    private let windowFrames: Int
    private let minimumGapFrames: Int
    private let keptFrames: Int
    private let crossfadeFrames: Int
    private let maximumRemovalFrames: Int

    private var windowBuffer: AudioChunk
    private var run: AudioChunk
    private var runAlreadyCut = false

    private var detector: Biquad
    private var histogram: [Double]
    private let histogramDecay: Double
    private var crossfadeCurve: [(Float, Float)]

    init(sampleRate: Double, channelCount: Int, parameters: SmartSpeedParameters = .init()) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.parameters = parameters
        windowFrames = max(1, Int(sampleRate * parameters.window))
        minimumGapFrames = Int(sampleRate * parameters.minimumGap)
        keptFrames = Int(sampleRate * parameters.keptGap)
        crossfadeFrames = max(1, min(Int(sampleRate * parameters.crossfade), Int(sampleRate * parameters.keptGap)))
        maximumRemovalFrames = Int(sampleRate * parameters.maximumRemovalPerGap)
        windowBuffer = AudioChunk(channelCount: channelCount)
        run = AudioChunk(channelCount: channelCount)
        detector = .highPass(frequency: 100, sampleRate: sampleRate)
        histogram = []
        histogramDecay = exp(-parameters.window / parameters.statisticsTimeConstant)
        let fadeFrames = crossfadeFrames
        crossfadeCurve = (0..<fadeFrames).map { i in
            let theta = Double.pi / 2 * (Double(i) + 0.5) / Double(fadeFrames)
            return (Float(cos(theta)), Float(sin(theta)))
        }
        resetStatistics()
    }

    /// Frames that will be emitted with `edited` tags starting here.
    var nextEditedFrame: Int64 { editedCounter }

    mutating func reset() {
        windowBuffer.removeAll()
        run.removeAll()
        runAlreadyCut = false
        detector.reset()
        editedCounter = 0
        removedFrames = 0
        disabling = false
        resetStatistics()
    }

    private mutating func resetStatistics() {
        // Priors worth a couple of seconds: speech around −20 dBFS, noise around −70 dBFS.
        histogram = Array(repeating: 0, count: 121)
        histogram[bin(-20)] = 150
        histogram[bin(-70)] = 30
    }

    private func bin(_ db: Double) -> Int { min(120, max(0, Int((db + 120).rounded()))) }

    private func percentile(_ p: Double) -> Double {
        let total = histogram.reduce(0, +)
        var cumulative = 0.0
        for (i, w) in histogram.enumerated() {
            cumulative += w
            if cumulative >= total * p { return Double(i) - 120 }
        }
        return 0
    }

    /// The level below which a window counts as silence.
    var silenceThresholdDB: Double {
        let speech = percentile(0.9), noise = percentile(0.05)
        let p = parameters
        return min(speech - p.minimumBelowSpeechDB, max(speech - p.belowSpeechDB, noise + p.aboveNoiseDB, -80))
    }

    mutating func process(_ input: AudioChunk) -> AudioChunk {
        var output = AudioChunk(channelCount: channelCount, capacity: input.frameCount)
        if disabling {
            emit(run, range: 0..<run.frameCount, into: &output)
            run.removeAll()
            runAlreadyCut = false
            disabling = false
        }
        windowBuffer.append(input)
        var start = 0
        while windowBuffer.frameCount - start >= windowFrames {
            handleWindow(start..<(start + windowFrames), into: &output)
            start += windowFrames
        }
        windowBuffer.removeFirst(start)
        return output
    }

    mutating func flush() -> AudioChunk {
        var output = AudioChunk(channelCount: channelCount)
        resolveRun(into: &output)
        emit(windowBuffer, range: 0..<windowBuffer.frameCount, into: &output)
        windowBuffer.removeAll()
        return output
    }

    private mutating func handleWindow(_ range: Range<Int>, into output: inout AudioChunk) {
        var power = 0.0
        for i in range {
            var x = 0.0
            for c in 0..<channelCount { x += Double(windowBuffer.channels[c][i]) }
            let y = detector.process(x / Double(channelCount))
            power += y * y
        }
        let level = powerToDB(power / Double(range.count))
        let silent = level < silenceThresholdDB
        for i in histogram.indices { histogram[i] *= histogramDecay }
        histogram[bin(level)] += 1

        guard isEnabled else {
            emit(windowBuffer, range: range, into: &output)
            return
        }
        if silent {
            if runAlreadyCut {
                emit(windowBuffer, range: range, into: &output)
                return
            }
            run.append(windowBuffer, range: range)
            if run.frameCount >= keptFrames + maximumRemovalFrames {
                // The gap is already long enough to hit the cap, so cut now instead of buffering
                // an arbitrarily long silence, and pass the rest of this gap straight through.
                cut(removing: maximumRemovalFrames, into: &output)
                runAlreadyCut = true
            }
        } else {
            resolveRun(into: &output)
            emit(windowBuffer, range: range, into: &output)
        }
    }

    private mutating func resolveRun(into output: inout AudioChunk) {
        defer { run.removeAll(); runAlreadyCut = false }
        let length = run.frameCount
        guard isEnabled, length >= minimumGapFrames else {
            emit(run, range: 0..<length, into: &output)
            return
        }
        cut(removing: min(length - keptFrames, maximumRemovalFrames), into: &output)
    }

    /// Keeps the run's edges and removes `removal` frames from its middle, crossfading across the join.
    private mutating func cut(removing removal: Int, into output: inout AudioChunk) {
        let length = run.frameCount
        let x = crossfadeFrames
        guard removal > 0, length - removal >= x else {
            emit(run, range: 0..<length, into: &output)
            run.removeAll()
            return
        }
        let head = (length - removal - x) / 2
        emit(run, range: 0..<head, into: &output)
        for i in 0..<x {
            let (fadeOut, fadeIn) = crossfadeCurve[i]
            let a = head + i, b = head + removal + i
            for c in 0..<channelCount {
                output.channels[c].append(run.channels[c][a] * fadeOut + run.channels[c][b] * fadeIn)
            }
            var tag = i < x / 2 ? run.tags[a] : run.tags[b]
            tag.edited = editedCounter
            editedCounter += 1
            output.tags.append(tag)
        }
        emit(run, range: (head + removal + x)..<length, into: &output)
        removedFrames += Int64(removal)
        run.removeAll()
    }

    private mutating func emit(_ chunk: AudioChunk, range: Range<Int>, into output: inout AudioChunk) {
        guard !range.isEmpty else { return }
        for c in 0..<channelCount { output.channels[c].append(contentsOf: chunk.channels[c][range]) }
        for i in range {
            var tag = chunk.tags[i]
            tag.edited = editedCounter
            editedCounter += 1
            output.tags.append(tag)
        }
    }
}
