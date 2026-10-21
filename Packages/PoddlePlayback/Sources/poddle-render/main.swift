import Foundation
import PoddlePlayback

// poddle-render: renders a file offline through Poddle's playback graph, for listening checks.
//
//   poddle-render <input> <output.m4a> [--rate 1.8] [--algorithm spectral|timeDomain]
//                 [--smart-speed] [--voice-boost] [--start seconds] [--duration seconds] [--loudness LUFS]

func usage() -> Never {
    print("usage: poddle-render <input> <output.m4a> [--rate R] [--algorithm spectral|timeDomain] [--smart-speed] [--voice-boost] [--start S] [--duration S] [--loudness LUFS] [--cuts cuts.txt]")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let input = URL(fileURLWithPath: args.removeFirst())
let output = URL(fileURLWithPath: args.removeFirst())
var settings = AudioSettings(rate: 1, algorithm: .spectral, smartSpeed: false, voiceBoost: false)
var start = 0.0
var duration: Double?
var loudness: Double?
var cutsPath: String?

while !args.isEmpty {
    let flag = args.removeFirst()
    func value() -> String { if args.isEmpty { usage() }; return args.removeFirst() }
    switch flag {
    case "--rate": settings.rate = Double(value()) ?? 1
    case "--algorithm":
        guard let algorithm = TimePitchAlgorithm(rawValue: value()) else { usage() }
        settings.algorithm = algorithm
    case "--smart-speed": settings.smartSpeed = true
    case "--voice-boost": settings.voiceBoost = true
    case "--start": start = Double(value()) ?? 0
    case "--duration": duration = Double(value())
    case "--loudness": loudness = Double(value())
    case "--cuts": cutsPath = value()
    default: usage()
    }
}

do {
    if settings.voiceBoost && loudness == nil {
        loudness = try LoudnessMeter.integratedLoudness(of: input)
    }
    let began = Date()
    let report = try OfflineRenderer.render(
        input: input, output: output,
        options: RenderOptions(settings: settings, loudness: loudness, start: start, contentDuration: duration))
    let outputLoudness = try LoudnessMeter.integratedLoudness(of: output)
    if let cutsPath {
        // A cut shows up as content jumping further than the rate explains between two render quanta.
        var cuts: [String] = []
        for (a, b) in zip(report.positions, report.positions.dropFirst()) {
            let expected = Double(b.outputFrame - a.outputFrame) / report.sampleRate * settings.rate
            if b.contentSeconds - a.contentSeconds - expected > 0.03 {
                cuts.append(String(format: "%.4f %.4f %.4f", Double(a.outputFrame) / report.sampleRate, a.contentSeconds, b.contentSeconds))
            }
        }
        try cuts.joined(separator: "\n").write(toFile: cutsPath, atomically: true, encoding: .utf8)
    }
    func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "n/a" }
    print("""
    output: \(output.path)
    settings: rate \(settings.rate) \(settings.algorithm.rawValue) smartSpeed \(settings.smartSpeed) voiceBoost \(settings.voiceBoost)
    input loudness: \(f(loudness)) LUFS
    content rendered: \(f(report.contentSeconds)) s
    output duration: \(f(report.outputSeconds)) s
    smart speed removed: \(f(report.smartSpeedRemovedSeconds)) s content (\(f(report.smartSpeedRemovedSeconds / settings.rate)) s wall)
    peak (pre-encode): \(f(report.peakDBFS)) dBFS
    output loudness: \(f(outputLoudness)) LUFS
    render time: \(f(Date().timeIntervalSince(began))) s
    """)
} catch {
    print("error: \(error)")
    exit(1)
}
