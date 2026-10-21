import Foundation
import Testing
@testable import PoddlePlayback

@Suite("Sleep timer")
struct SleepTimerTests {
    func context(_ position: Double = 0, playing: Bool = true, chapterEnd: Double? = nil) -> SleepTimer.Context {
        .init(position: position, duration: 3_600, rate: 1.5, chapterEnd: chapterEnd, isPlaying: playing)
    }

    @Test func minutesCountDownOnlyWhilePlayingAndFadeOut() {
        let clock = ManualPlaybackClock()
        var timer = SleepTimer()
        timer.set(.minutes(1), now: clock.now)

        clock.advance(by: 20)
        #expect(timer.evaluate(now: clock.now, context: context()) == .running(remaining: 40, volume: 1))

        clock.advance(by: 600)  // paused for 10 minutes: doesn't count
        _ = timer.evaluate(now: clock.now, context: context(playing: false))
        clock.advance(by: 35)
        guard case .running(let remaining, let volume) = timer.evaluate(now: clock.now, context: context()) else {
            Issue.record("expected running"); return
        }
        #expect(abs(remaining - 5) < 1e-9)
        #expect(abs(volume - 0.25) < 1e-6)  // halfway through the 10 s fade, squared curve

        clock.advance(by: 5)
        #expect(timer.evaluate(now: clock.now, context: context()) == .fire)
        #expect(timer.mode == nil)
        #expect(timer.evaluate(now: clock.now, context: context()) == .inactive)
    }

    @Test func shakeExtendsRunningTimerAndRestartsAFiredOne() {
        let clock = ManualPlaybackClock()
        var timer = SleepTimer()
        timer.set(.minutes(5), now: clock.now)
        clock.advance(by: 290)
        _ = timer.evaluate(now: clock.now, context: context())
        #expect(timer.extend(now: clock.now) == false)  // still running: back to the full 5 minutes
        clock.advance(by: 10)
        #expect(timer.evaluate(now: clock.now, context: context()) == .running(remaining: 290, volume: 1))

        clock.advance(by: 290)
        #expect(timer.evaluate(now: clock.now, context: context()) == .fire)
        clock.advance(by: 20)
        #expect(timer.extend(now: clock.now) == true)  // within 30 s of stopping: restart, resume playback
        #expect(timer.mode == .minutes(5))

        clock.advance(by: 300)
        #expect(timer.evaluate(now: clock.now, context: context()) == .fire)
        clock.advance(by: 31)
        #expect(timer.extend(now: clock.now) == false)  // too late
        #expect(timer.mode == nil)
    }

    @Test func endOfChapterAndEpisodeUseWallTimeAtTheCurrentRate() {
        var timer = SleepTimer()
        timer.set(.endOfChapter, now: 0)
        // 15 content seconds left at 1.5× = 10 s wall: the fade starts.
        #expect(timer.evaluate(now: 1, context: context(985, chapterEnd: 1_000)) == .running(remaining: 10, volume: 1))
        #expect(timer.evaluate(now: 2, context: context(1_000, chapterEnd: 1_000)) == .fire)

        timer.set(.endOfEpisode, now: 0)
        guard case .running(let remaining, _) = timer.evaluate(now: 1, context: context(3_000)) else {
            Issue.record("expected running"); return
        }
        #expect(remaining == 400)
    }
}

@Suite("Listening segments")
struct SegmentTests {
    let context = SegmentContext(episodeID: "ep1", rate: 1.5, smartSpeed: true, voiceBoost: true, route: .airPods)
    let t0 = 1_760_000_000_000.0

    @Test func checkpointsEvery30sWithTheSameIDThenFinal() throws {
        var r = ListeningSegmentRecorder()
        r.begin(wall: t0, content: 100, removedTotal: 2, context: context)
        #expect(r.tick(wall: t0 + 10_000, content: 115, removedTotal: 2.5) == nil)
        let checkpoint = try unwrap(r.tick(wall: t0 + 30_000, content: 145, removedTotal: 3))
        #expect(!checkpoint.isFinal)
        #expect(checkpoint.contentStart == 100 && checkpoint.contentEnd == 145)
        #expect(checkpoint.smartRemovedContent == 1)
        #expect(r.tick(wall: t0 + 45_000, content: 167, removedTotal: 3) == nil)
        let second = try unwrap(r.tick(wall: t0 + 60_000, content: 190, removedTotal: 4))
        #expect(second.id == checkpoint.id)

        let final = try unwrap(r.end(wall: t0 + 70_000, content: 205, removedTotal: 4.5))
        #expect(final.isFinal && final.id == checkpoint.id)
        #expect(final.wallStart == t0 && final.wallEnd == t0 + 70_000)
        #expect(final.contentEnd == 205 && final.smartRemovedContent == 2.5)
        #expect(final.rate == 1.5 && final.route == .airPods && final.voiceBoost && final.smartSpeed)
        #expect(r.end(wall: t0 + 80_000, content: 210, removedTotal: 5) == nil)
    }

    @Test func longSeeksSplitShortOnesDont() throws {
        var r = ListeningSegmentRecorder()
        r.begin(wall: t0, content: 0, removedTotal: 0, context: context)
        #expect(r.seek(from: 20, to: 50, wall: t0 + 20_000, removedTotal: 0) == nil)  // exactly 30 s: no split
        let closed = try unwrap(r.seek(from: 60, to: 600, wall: t0 + 30_000, removedTotal: 0))
        #expect(closed.contentEnd == 60 && closed.isFinal)
        #expect(r.open?.contentStart == 600)
        #expect(r.open?.id != closed.id)
        let back = try unwrap(r.seek(from: 610, to: 500, wall: t0 + 40_000, removedTotal: 0))
        #expect(back.contentStart == 600 && back.contentEnd == 610)
    }

    @Test func contextChangeSplits() throws {
        var r = ListeningSegmentRecorder()
        r.begin(wall: t0, content: 0, removedTotal: 0, context: context)
        var faster = context
        faster.rate = 2
        let closed = try unwrap(r.split(wall: t0 + 5_000, content: 7.5, removedTotal: 0.4, context: faster))
        #expect(closed.rate == 1.5 && closed.smartRemovedContent == 0.4)
        let next = try unwrap(r.end(wall: t0 + 15_000, content: 27.5, removedTotal: 1))
        #expect(next.rate == 2 && next.contentStart == 7.5 && abs(next.smartRemovedContent - 0.6) < 1e-9)
    }

    @Test func dropsBlips() {
        var r = ListeningSegmentRecorder()
        r.begin(wall: t0, content: 0, removedTotal: 0, context: context)
        #expect(r.end(wall: t0 + 400, content: 0.4, removedTotal: 0) == nil)
    }
}

@Suite("Rules")
struct RuleTests {
    @Test func playedThreshold() {
        #expect(!PlayedThreshold.isPlayed(position: 3_000, duration: 3_600))
        #expect(PlayedThreshold.isPlayed(position: 3_571, duration: 3_600))  // 29 s left
        #expect(PlayedThreshold.isPlayed(position: 9_800, duration: 10_000))  // 98%
        #expect(!PlayedThreshold.isPlayed(position: 9_700, duration: 10_000))
        #expect(PlayedThreshold.isPlayed(position: 0, duration: 20))  // short clip
    }

    @Test func autoRewind() {
        #expect(AutoRewind.amount(pausedFor: 60) == 0)
        #expect(AutoRewind.amount(pausedFor: 301) == 3)
        #expect(AutoRewind.amount(pausedFor: 3_601) == 10)
    }
}

/// `#require` can't wrap a mutating call, so unwrap through a function.
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}
