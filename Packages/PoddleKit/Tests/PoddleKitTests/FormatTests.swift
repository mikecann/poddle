import Foundation
import Testing
@testable import PoddleKit

@Suite struct FormatTests {
    @Test func durations() {
        #expect(Format.duration(64 * 60) == "1h 4m")
        #expect(Format.duration(52 * 60) == "52m")
        #expect(Format.duration(2 * 3600) == "2h")
        #expect(Format.duration(9 * 60 + 20) == "9m")
        #expect(Format.duration(20) == "<1m")
        #expect(Format.duration(0) == "0m")
        #expect(Format.duration(282 * 60) == "4h 42m")
    }

    @Test func speeds() {
        #expect(Format.speed(1.8) == "1.8×")
        #expect(Format.speed(1.25) == "1.25×")
        #expect(Format.speed(2) == "2.0×")
        #expect(Format.speed(1.4000000000000001) == "1.4×")
        #expect(Format.speedNumber(0.95) == "0.95")
        #expect(Format.speedPrecise(1.4) == "1.40")
    }

    @Test func timeLeftUsesWallClock() {
        // 68.4 minutes of content at 1.8× is 38 minutes on the clock.
        #expect(Format.timeLeft(68.4 * 60, rate: 1.8) == "38m left at 1.8×")
        #expect(Format.atSpeed(62.4 * 60, rate: 1.2) == "52m at 1.2×")
        // Dwarkesh in Now Playing: 1:12:40 left at 1.4×.
        #expect(Format.timeLeft(72 * 60 + 40, rate: 1.4) == "52m left at 1.4×")
    }

    @Test func clocks() {
        #expect(Format.clock(41 * 60 + 8) == "41:08")
        #expect(Format.clock(3600 + 12 * 60 + 40) == "1:12:40")
        #expect(Format.remainingClock(3600 + 12 * 60 + 40) == "−1:12:40")
        #expect(Format.clock(-5) == "0:00")
    }

    @Test func saved() {
        #expect(Format.saved(252) == "4m 12s")
        #expect(Format.saved(27 * 3600) == "27h")
        #expect(Format.saved(45) == "45s")
        #expect(Format.hours(612 * 3600) == "612h")
        #expect(Format.count(3412) == "3,412")
    }

    @Test func queueSummary() {
        #expect(Format.queueSummary(count: 6, wallSeconds: 282 * 60) == "6 episodes · 4h 42m at your speeds")
        #expect(Format.queueSummary(count: 1, wallSeconds: 600) == "1 episode · 10m at your speeds")
        #expect(Format.queueSummary(count: 0, wallSeconds: 0) == "Nothing queued")
    }

    @Test func relativeDates() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9)))
        func ms(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 }
        let earlier = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 6)))
        let yesterday = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 22)))
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10)))
        let lastYear = try #require(cal.date(from: DateComponents(year: 2025, month: 10, day: 14, hour: 10)))
        #expect(Format.relativeDate(ms(earlier), now: now, calendar: cal) == "Today")
        #expect(Format.relativeDate(ms(yesterday), now: now, calendar: cal) == "Yesterday")
        #expect(Format.relativeDate(ms(monday), now: now, calendar: cal) == "Mon 19 Oct")
        #expect(Format.relativeDate(ms(lastYear), now: now, calendar: cal) == "14 Oct 2025")
        #expect(Format.receiptDate(ms(now), calendar: cal) == "21 OCT 2026")
    }
}

@Suite struct SettingsTests {
    @Test func overrideWinsOverGlobal() {
        let global = GlobalSettings(speed: 1.8, voiceBoost: true)
        let show = PodcastSettings(podcastId: "p", speed: 1.2, voiceBoost: false)
        let r = ResolvedSettings(global: global, override: show)
        #expect(r.speed == Resolved(1.2, isOverride: true))
        #expect(r.voiceBoost == Resolved(false, isOverride: true))
        #expect(r.smartSpeed == Resolved(true, isOverride: false))
    }

    @Test func inheritsGlobalLive() {
        var global = GlobalSettings(speed: 1.8)
        let show = PodcastSettings(podcastId: "p")
        #expect(ResolvedSettings(global: global, override: show).speed.value == 1.8)
        global.speed = 2.0
        #expect(ResolvedSettings(global: global, override: show).speed.value == 2.0)
        #expect(ResolvedSettings(global: global, override: nil).autoAdd.value == .inbox)
    }

    @Test func priorityFollowsAutoAdd() {
        let r = ResolvedSettings(global: .defaults, override: PodcastSettings(podcastId: "p", autoAdd: .upNextTop))
        #expect(r.isPriority)
        #expect(!ResolvedSettings(global: .defaults, override: nil).isPriority)
    }

    @Test func speedScopeDefault() {
        #expect(SpeedScope.defaultScope(podcastId: "p", override: PodcastSettings(podcastId: "p", speed: 1.4)) == .show("p"))
        #expect(SpeedScope.defaultScope(podcastId: "p", override: PodcastSettings(podcastId: "p", voiceBoost: false)) == .allPodcasts)
        #expect(SpeedScope.defaultScope(podcastId: "p", override: nil) == .allPodcasts)
    }

    @Test func speedSnapping() {
        #expect(Speed.snap(1.43) == 1.45)
        #expect(Speed.snap(0.1) == 0.5)
        #expect(Speed.snap(9) == 3.0)
        #expect(Speed.detent(0.5) == 0)
        #expect(Speed.detent(3.0) == 50)
        #expect(Speed.detent(1.4) == 18)
    }
}

@Suite struct OrderKeyTests {
    @Test func betweenSortsCorrectly() {
        let a = OrderKey.between(nil, nil)
        let b = OrderKey.between(a, nil)
        let mid = OrderKey.between(a, b)
        let first = OrderKey.between(nil, a)
        #expect(first < a && a < mid && mid < b)
    }

    @Test func manyInsertsStayOrdered() {
        var lo = OrderKey.between(nil, nil)
        let hi = OrderKey.between(lo, nil)
        for _ in 0..<60 {
            let next = OrderKey.between(lo, hi)
            #expect(lo < next && next < hi)
            lo = next
        }
        let seq = OrderKey.sequence(20)
        #expect(seq == seq.sorted())
        #expect(Set(seq).count == 20)
    }
}
