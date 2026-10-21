# PoddlePlayback

Poddle's audio engine. Depends on nothing else in the repo: give it a `PlaybackItem`, observe `PlaybackEngine`, and read `segments` and `events`.

## Signal path (local files)

```
decode → Smart Speed → Voice Boost → time-pitch → AVAudioPlayerNode → safety limiter → mixer
         └──────────── producer queue, ~0.5 s ahead of the playhead ────────────┘
```

- Every frame carries its content position through each stage, so position, seeks, chapters and saved positions are always content time.
- **Time-pitch:** `spectral` is Apple's `AVAudioUnitTimePitch`, run offline on the producer thread. In the realtime graph it reads ~2,000 frames ahead, which made the player's clock drift. `timeDomain` is a pitch-synchronous speech stretcher (the Sonic approach): it only drops or repeats whole pitch periods, so voices keep their pitch and formants at 2–3×.
- **Smart Speed:** 10 ms windows against a threshold that tracks the speech level (90th percentile) and the noise floor (5th percentile). Gaps over 250 ms are cut to 120 ms, at most 2 s each, with a 12 ms equal-power crossfade.
- **Voice Boost:** 80 Hz high-pass and a +3 dB presence lift. Then static gain towards −16 LUFS from the file's measured loudness, a speech-gated lookahead leveler (±12 dB, so a quiet guest meets a loud host), a gentle 2.5:1 compressor and a −1.5 dBFS lookahead limiter.
- Settings changes take effect after the scheduled lookahead (about 0.5 s). Switching algorithm restarts the producer at the current position.

Remote URLs play through `AVPlayer` (speed only). `localFileReady(_:forEpisode:)` hands over to the engine at the same position.

## Listening checks

```
swift build -c release
.build/release/poddle-render episode.mp3 out.m4a --rate 1.8 --algorithm timeDomain --smart-speed --voice-boost --start 900 --duration 180
```

It prints the output duration, the Smart Speed saving, the peak and the output loudness. `--cuts file` lists where Smart Speed cut.

`Package.swift` targets iOS 18 (Mike's iPhone XS Max) and macOS 26, so `swift test` runs on Macs still on 26. Newer AVFAudio calls sit behind `#available` checks (`Compat.swift`, `AudioSessionController.swift`).
