import AVFoundation
import Foundation
@testable import PoddlePlayback

/// Builds test signals with known structure and writes them to a temporary CAF file.
struct Synthetic {
    enum Part {
        /// Voice-like harmonic tone (140 Hz fundamental) at an RMS level, gently modulated at syllable rate.
        case voice(seconds: Double, rmsDB: Double)
        /// White noise at an RMS level.
        case noise(seconds: Double, rmsDB: Double)
        /// A "silent" gap: noise floor plus an optional mains hum, both at RMS levels.
        case gap(seconds: Double, noiseDB: Double = -75, humDB: Double? = nil)
        case sine(seconds: Double, frequency: Double, peakDB: Double)
    }

    let sampleRate: Double
    let channels: Int
    private(set) var samples: [Float] = []
    /// Content seconds where each non-gap part starts.
    private(set) var onsets: [Double] = []
    private var rng = SplitMix(seed: 42)
    private var humPhase = 0.0

    init(sampleRate: Double = 22_050, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    var seconds: Double { Double(samples.count) / sampleRate }

    mutating func add(_ part: Part) {
        switch part {
        case .voice(let s, let db):
            onsets.append(seconds)
            let n = Int(s * sampleRate)
            var block = [Float](repeating: 0, count: n)
            var power = 0.0
            for i in 0..<n {
                let t = Double(i) / sampleRate
                var x = 0.0
                for k in 1...12 { x += sin(2 * .pi * 140 * Double(k) * t + Double(k)) / Double(k) }
                x *= 0.75 + 0.25 * sin(2 * .pi * 4 * t)
                block[i] = Float(x)
                power += x * x
            }
            let scale = Float(dbToGain(db) / sqrt(power / Double(n)))
            samples += block.map { $0 * scale }
        case .noise(let s, let db):
            onsets.append(seconds)
            let amplitude = Float(dbToGain(db) * sqrt(3.0))
            for _ in 0..<Int(s * sampleRate) { samples.append(rng.uniform() * amplitude) }
        case .gap(let s, let noiseDB, let humDB):
            let noise = Float(dbToGain(noiseDB) * sqrt(3.0))
            let hum = humDB.map { dbToGain($0) * sqrt(2.0) } ?? 0
            for _ in 0..<Int(s * sampleRate) {
                humPhase += 2 * .pi * 60 / sampleRate
                samples.append(rng.uniform() * noise + Float(hum * sin(humPhase)))
            }
        case .sine(let s, let f, let db):
            onsets.append(seconds)
            let a = dbToGain(db)
            for i in 0..<Int(s * sampleRate) { samples.append(Float(a * sin(2 * .pi * f * Double(i) / sampleRate))) }
        }
    }

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poddle-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for c in 0..<channels {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
        return url
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [-1, 1).
    mutating func uniform() -> Float { Float(Double(next() >> 11) / Double(1 << 53) * 2 - 1) }
}

/// Renders and keeps the left channel of the output.
func renderCollecting(_ url: URL, _ options: RenderOptions) throws -> (RenderReport, [Float]) {
    var out: [Float] = []
    let report = try OfflineRenderer.render(input: url, options: options) { buffer in
        out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    return (report, out)
}

/// Output frames where a burst starts: |x| rises above `on` after at least `quiet` seconds below `off`.
/// A burst at the very start isn't counted.
func onsets(in x: [Float], sampleRate: Double, on: Float = 0.02, off: Float = 0.004, quiet: Double = 0.06) -> [Int] {
    var result: [Int] = []
    var quietRun = 0
    let needed = Int(quiet * sampleRate)
    for (i, v) in x.enumerated() {
        let a = abs(v)
        if a > on, quietRun >= needed { result.append(i) }
        quietRun = a < off ? quietRun + 1 : (a > on ? 0 : quietRun)
    }
    return result
}
