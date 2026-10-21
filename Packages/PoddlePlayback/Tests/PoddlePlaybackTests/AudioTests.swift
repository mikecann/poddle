import AVFoundation
import Foundation
import Testing
@testable import PoddlePlayback

private let off = AudioSettings(rate: 1, algorithm: .spectral, smartSpeed: false, voiceBoost: false)

@Suite("Smart Speed")
struct SmartSpeedTests {
    /// Voice bursts separated by gaps of known length, with a −75 dBFS noise floor in the gaps.
    static let gaps: [Double] = [0.15, 0.2, 0.6, 1.0, 3.0, 0.5, 0.3, 4.0]

    static func signal() throws -> (URL, Synthetic) {
        var s = Synthetic(sampleRate: 22_050)
        s.add(.voice(seconds: 1.0, rmsDB: -20))
        for g in gaps {
            s.add(.gap(seconds: g))
            s.add(.voice(seconds: 1.0, rmsDB: -20))
        }
        return (try s.write(), s)
    }

    static func expectedRemoval(_ gap: Double, _ p: SmartSpeedParameters = .init()) -> Double {
        gap < p.minimumGap ? 0 : min(gap - p.keptGap, p.maximumRemovalPerGap)
    }

    @Test func removesExpectedTimeAndKeepsShortGaps() throws {
        let (url, s) = try Self.signal()
        var settings = off
        settings.smartSpeed = true
        let (report, out) = try renderCollecting(url, RenderOptions(settings: settings, quantum: 128))

        let expected = Self.gaps.map { Self.expectedRemoval($0) }.reduce(0, +)
        #expect(abs(report.smartSpeedRemovedSeconds - expected) < 0.08, "removed \(report.smartSpeedRemovedSeconds), expected \(expected)")
        #expect(abs(report.outputSeconds - (s.seconds - report.smartSpeedRemovedSeconds)) < 0.05)

        // Each gap in the output: short ones untouched, long ones cut to ~120 ms (or by 2 s at most).
        let starts = onsets(in: out, sampleRate: 22_050)
        #expect(starts.count == Self.gaps.count)
        // starts[k] is the burst after gaps[k], so starts[k+1] - starts[k] is one burst plus gaps[k+1].
        for k in 0..<(starts.count - 1) {
            let gap = Self.gaps[k + 1]
            let outputGap = Double(starts[k + 1] - starts[k]) / 22_050 - 1.0
            let expectedGap = gap - Self.expectedRemoval(gap)
            #expect(abs(outputGap - expectedGap) < 0.025, "gap \(gap): output \(outputGap), expected \(expectedGap)")
        }
    }

    @Test func timeMapStaysInContentTime() throws {
        let (url, s) = try Self.signal()
        var settings = off
        settings.smartSpeed = true
        let (report, out) = try renderCollecting(url, RenderOptions(settings: settings, quantum: 128))
        let starts = onsets(in: out, sampleRate: 22_050)
        for (frame, onset) in zip(starts, s.onsets.dropFirst()) {
            let reported = try #require(report.contentSeconds(atOutputFrame: frame))
            #expect(abs(reported - onset) < 0.02, "burst at \(onset) s reported at \(reported) s")
        }
    }

    @Test(arguments: [TimePitchAlgorithm.spectral, .timeDomain])
    func timeMapStaysInContentTimeAtSpeed(_ algorithm: TimePitchAlgorithm) throws {
        let (url, s) = try Self.signal()
        let settings = AudioSettings(rate: 1.8, algorithm: algorithm, smartSpeed: true, voiceBoost: false)
        let (report, out) = try renderCollecting(url, RenderOptions(settings: settings, quantum: 128))
        let starts = onsets(in: out, sampleRate: 22_050, quiet: 0.03)
        #expect(starts.count == Self.gaps.count)
        // The speech stretcher keeps every frame's tag exact. Apple's phase vocoder re-times attacks
        // after silences by up to ~90 ms (transient preservation), so it gets a looser bound.
        let tolerance = algorithm == .timeDomain ? 0.02 : 0.1
        for (frame, onset) in zip(starts, s.onsets.dropFirst()) {
            let reported = try #require(report.contentSeconds(atOutputFrame: frame))
            #expect(abs(reported - onset) < tolerance, "\(algorithm): burst at \(onset) s reported at \(reported) s")
        }
    }

    @Test func cutsDoNotClick() throws {
        // Gaps carry a 60 Hz hum, the worst case for a hard cut: any discontinuity shows as a jump far
        // bigger than the hum's own sample-to-sample change.
        var s = Synthetic(sampleRate: 22_050)
        s.add(.voice(seconds: 1, rmsDB: -18))
        for g in [0.8, 1.5, 3.0] {
            s.add(.gap(seconds: g, noiseDB: -90, humDB: -50))
            s.add(.voice(seconds: 1, rmsDB: -18))
        }
        var settings = off
        settings.smartSpeed = true
        let (report, out) = try renderCollecting(try s.write(), RenderOptions(settings: settings, quantum: 128))
        #expect(report.smartSpeedRemovedSeconds > 3)

        // Largest sample-to-sample step inside gaps (well below voice level on both sides).
        let humPeak = Float(dbToGain(-50) * sqrt(2.0))
        func largestStepInGaps(_ x: [Float]) -> Float {
            var worst: Float = 0
            for i in 1..<x.count {
                let window = max(0, i - 200)..<min(x.count, i + 200)
                if window.allSatisfy({ abs(x[$0]) < humPeak * 1.6 }) { worst = max(worst, abs(x[i] - x[i - 1])) }
            }
            return worst
        }
        let natural = largestStepInGaps(s.samples)
        let worst = largestStepInGaps(out)
        // A hard cut in the hum could step by up to twice its peak; the crossfades must stay natural.
        #expect(worst < natural * 1.5, "largest step in output gaps \(worst), in the input \(natural), a hard cut could reach \(2 * humPeak)")
    }
}

@Suite("Speed")
struct SpeedTests {
    static func signal() throws -> (URL, Double) {
        var s = Synthetic(sampleRate: 22_050)
        for _ in 0..<5 {
            s.add(.voice(seconds: 3, rmsDB: -20))
            s.add(.gap(seconds: 1))
        }
        return (try s.write(), s.seconds)
    }

    @Test(arguments: [
        (1.0, TimePitchAlgorithm.spectral), (2.0, .spectral), (1.5, .spectral), (3.0, .spectral),
        (2.0, .timeDomain), (1.5, .timeDomain), (3.0, .timeDomain), (0.5, .timeDomain), (0.75, .spectral),
    ])
    func rateChangesOutputDuration(_ rate: Double, _ algorithm: TimePitchAlgorithm) throws {
        let (url, seconds) = try Self.signal()
        let settings = AudioSettings(rate: rate, algorithm: algorithm, smartSpeed: false, voiceBoost: false)
        let report = try OfflineRenderer.render(input: url, options: RenderOptions(settings: settings))
        let expected = seconds / rate
        #expect(abs(report.outputSeconds - expected) < max(0.06, expected * 0.005),
                "\(algorithm) at \(rate)×: \(report.outputSeconds) s, expected \(expected) s")
        #expect(abs(report.contentSeconds - seconds) < 0.06)
    }

    @Test func startsAtTheRequestedPosition() throws {
        let (url, seconds) = try Self.signal()
        let report = try OfflineRenderer.render(input: url, options: RenderOptions(settings: off, start: 6, contentDuration: 5))
        #expect(abs(report.positions.first!.contentSeconds - 6) < 0.01)
        #expect(abs(report.outputSeconds - 5) < 0.06)
        #expect(seconds > 11)
    }
}

@Suite("Loudness")
struct LoudnessTests {
    /// EBU Tech 3341 case 1: a stereo 1 kHz sine at −23 dBFS reads −23 LUFS.
    @Test(arguments: [44_100.0, 48_000.0])
    func calibratedSine(_ sampleRate: Double) throws {
        var s = Synthetic(sampleRate: sampleRate, channels: 2)
        s.add(.sine(seconds: 10, frequency: 997, peakDB: -23))
        let lufs = try #require(try LoudnessMeter.integratedLoudness(of: try s.write()))
        #expect(abs(lufs - -23) < 0.5, "\(lufs) LUFS")
    }

    @Test func gatingIgnoresSilence() throws {
        var s = Synthetic(sampleRate: 48_000, channels: 2)
        s.add(.sine(seconds: 5, frequency: 997, peakDB: -23))
        s.add(.gap(seconds: 10, noiseDB: -90))
        s.add(.sine(seconds: 5, frequency: 997, peakDB: -23))
        let lufs = try #require(try LoudnessMeter.integratedLoudness(of: try s.write()))
        #expect(abs(lufs - -23) < 0.5, "\(lufs) LUFS")
    }

    /// EBU Tech 3341 case 2-ish: −33 dBFS sine reads −33 LUFS (the meter is linear).
    @Test func quietSine() throws {
        var s = Synthetic(sampleRate: 48_000, channels: 2)
        s.add(.sine(seconds: 10, frequency: 997, peakDB: -33))
        let lufs = try #require(try LoudnessMeter.integratedLoudness(of: try s.write()))
        #expect(abs(lufs - -33) < 0.5)
    }

    @Test func monoCountsOneChannel() throws {
        var s = Synthetic(sampleRate: 48_000, channels: 1)
        s.add(.sine(seconds: 10, frequency: 997, peakDB: -23))
        let lufs = try #require(try LoudnessMeter.integratedLoudness(of: try s.write()))
        #expect(abs(lufs - -26) < 0.5)
        #expect(abs(LoudnessMeter.perceivedLoudness(integrated: lufs, channelCount: 1) - -23) < 0.5)
    }
}

@Suite("Voice Boost")
struct VoiceBoostTests {
    @Test func levelsQuietAndLoudSpeakersTowardsTarget() throws {
        // A loud host and a quiet guest, 14 dB apart, taking turns.
        var s = Synthetic(sampleRate: 22_050)
        for _ in 0..<3 {
            s.add(.voice(seconds: 6, rmsDB: -12))
            s.add(.gap(seconds: 0.2))
            s.add(.voice(seconds: 6, rmsDB: -26))
            s.add(.gap(seconds: 0.2))
        }
        let url = try s.write()
        let measured = try LoudnessMeter.integratedLoudness(of: url)
        let settings = AudioSettings(rate: 1, algorithm: .spectral, smartSpeed: false, voiceBoost: true)
        let (report, out) = try renderCollecting(url, RenderOptions(settings: settings, loudness: measured))
        #expect(report.peakDBFS <= -1.0)

        // Loudness of the second half of each turn (after the leveler has settled).
        func turnLoudness(_ start: Double) -> Double {
            var meter = LoudnessMeter(sampleRate: 22_050, channelCount: 1)
            let a = Int((start + 3) * 22_050), b = Int((start + 6) * 22_050)
            out[a..<b].withUnsafeBufferPointer { meter.feed([$0], frameCount: b - a) }
            return LoudnessMeter.perceivedLoudness(integrated: meter.integratedLoudness ?? -99, channelCount: 1)
        }
        let loud = turnLoudness(12.4), quiet = turnLoudness(18.6)
        #expect(abs(loud - quiet) < 3, "host \(loud) LUFS, guest \(quiet) LUFS")
        #expect(abs(loud - -16) < 2.5 && abs(quiet - -16) < 2.5, "host \(loud) LUFS, guest \(quiet) LUFS")
    }

    @Test func limiterHoldsTheCeiling() {
        var limiter = LookaheadLimiter(channelCount: 1, lookaheadFrames: 64, ceiling: 0.5, releaseCoef: 0.001)
        var out = AudioChunk(channelCount: 1)
        for i in 0..<5_000 {
            let x: Float = (i / 500) % 2 == 0 ? 0.9 * sin(Float(i) * 0.05) : 0.1 * sin(Float(i) * 0.05)
            limiter.push([x], tag: FrameTag(content: Int64(i), edited: Int64(i)), into: &out)
        }
        limiter.flush(into: &out)
        #expect(out.frameCount == 5_000)
        #expect(out.channels[0].map(abs).max()! <= 0.5 + 1e-6)
        #expect(out.tags.map(\.content) == (0..<5_000).map(Int64.init))
    }
}

@Suite("Time map")
struct TimeMapTests {
    @Test func looksUpThroughCuts() {
        var map = TimeMap()
        // 1000 frames 1:1, then a jump of 5000 content frames.
        map.append((0..<1_000).map { FrameTag(content: Int64($0), edited: Int64($0)) })
        map.append((0..<1_000).map { FrameTag(content: Int64(6_000 + $0), edited: Int64(1_000 + $0)) })
        #expect(map.tag(atPlayerFrame: 500)?.content == 500)
        #expect(map.tag(atPlayerFrame: 1_500)?.content == 6_500)
        #expect(map.endFrame == 2_000)
    }
}
