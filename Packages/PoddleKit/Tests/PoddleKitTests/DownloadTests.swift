import Foundation
import Testing
@testable import PoddleKit

private let t0 = Date(timeIntervalSince1970: 1_792_000_000) // a Tuesday afternoon in Oct 2026
private let sydney: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Australia/Sydney")!
    return c
}()

@Suite struct DownloadPolicyTests {
    let wifiOnly = DownloadPolicy(settings: DownloadSettings())

    @Test func wifiOnlyByDefault() {
        #expect(DownloadSettings().mode == .wifiOnly)
        #expect(wifiOnly.decisionForTap(on: .wifi, now: t0) == .start(allowsMobile: false))
        #expect(wifiOnly.decisionForTap(on: .offline, now: t0) == .start(allowsMobile: false))
        #expect(!wifiOnly.allowsMobileForAutoDownload(now: t0))
    }

    @Test func tapOnMobileAsks() {
        #expect(wifiOnly.decisionForTap(on: .mobile, now: t0) == .ask)
        let both = DownloadPolicy(settings: DownloadSettings(mode: .wifiAndMobile))
        #expect(both.decisionForTap(on: .mobile, now: t0) == .start(allowsMobile: true))
        #expect(both.allowsMobileForAutoDownload(now: t0))
    }

    @Test func allowanceLastsAndExpires() {
        let until = MobileAllowance.oneHour.expiry(from: t0)
        #expect(until == t0.addingTimeInterval(3_600))
        #expect(MobileAllowance.threeHours.expiry(from: t0) == t0.addingTimeInterval(3 * 3_600))
        let p = DownloadPolicy(settings: DownloadSettings(mobileAllowedUntil: until))
        #expect(p.isAllowanceActive(now: t0))
        #expect(p.allowanceRemaining(now: t0.addingTimeInterval(600)) == 3_000)
        #expect(p.decisionForTap(on: .mobile, now: t0) == .start(allowsMobile: true))
        #expect(p.allowsMobileForAutoDownload(now: t0))

        let later = t0.addingTimeInterval(3_601)
        #expect(!p.isAllowanceActive(now: later))
        #expect(p.allowanceRemaining(now: later) == nil)
        #expect(p.decisionForTap(on: .mobile, now: later) == .ask)
    }

    @Test func untilTomorrowEndsAtLocalMidnight() {
        let until = MobileAllowance.untilTomorrow.expiry(from: t0, calendar: sydney)
        #expect(sydney.component(.hour, from: until) == 0)
        #expect(sydney.isDate(until, inSameDayAs: sydney.date(byAdding: .day, value: 1, to: t0)!))
        #expect(until > t0 && until.timeIntervalSince(t0) <= 86_400)
    }

    @Test func promptChoices() {
        let now = wifiOnly.resolve(.downloadNowOnMobile, now: t0)
        #expect(now.allowsMobile && now.oneOff)
        #expect(now.settings == wifiOnly.settings) // doesn't turn on the allowance

        let hour = wifiOnly.resolve(.allowMobileForOneHour, now: t0)
        #expect(hour.allowsMobile && !hour.oneOff)
        #expect(hour.settings.mobileAllowedUntil == t0.addingTimeInterval(3_600))

        let wait = wifiOnly.resolve(.waitForWifi, now: t0)
        #expect(!wait.allowsMobile && !wait.oneOff)
        #expect(wait.settings == wifiOnly.settings)

        #expect(MobilePromptChoice.allCases.map(\.label) == ["Download now on mobile", "Allow mobile for 1 hour", "Wait for Wi-Fi"])
    }

    @Test func expiryPausesMobileDownloadsUntilWifi() {
        let p = DownloadPolicy(settings: DownloadSettings(mobileAllowedUntil: t0.addingTimeInterval(3_600)))
        let during = t0.addingTimeInterval(60), after = t0.addingTimeInterval(3_700)
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: false, isPausedForWifi: false, network: .mobile, now: during) == .none)
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: false, isPausedForWifi: false, network: .mobile, now: after) == .pauseUntilWifi)
        // "Download now on mobile" isn't tied to the allowance.
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: true, isPausedForWifi: false, network: .mobile, now: after) == .none)
        // Paused ones wait on mobile and resume on Wi-Fi.
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: false, isPausedForWifi: true, network: .mobile, now: after) == .none)
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: false, isPausedForWifi: true, network: .wifi, now: after) == .resume)
        // On Wi-Fi it carries on, but Wi-Fi-only, so it can't slip onto mobile while suspended.
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: false, isPausedForWifi: false, network: .wifi, now: after) == .restartWifiOnly)
        #expect(p.adjustment(taskAllowsMobile: true, oneOff: false, isPausedForWifi: false, network: .wifi, now: during) == .none)
        #expect(p.adjustment(taskAllowsMobile: false, oneOff: false, isPausedForWifi: false, network: .wifi, now: after) == .none)
        // Turning the allowance on restarts Wi-Fi-only requests stuck on mobile.
        #expect(p.adjustment(taskAllowsMobile: false, oneOff: false, isPausedForWifi: false, network: .mobile, now: during) == .restartAllowingMobile)
    }
}

@Suite struct DownloadPlannerTests {
    let day: Millis = 86_400_000
    let nowMs = t0.timeIntervalSince1970 * 1000
    let gb: Int64 = 1_073_741_824

    func file(_ id: String, show: String = "a", gb size: Double = 0.1, daysOld: Double = 1, playedHoursAgo: Double? = nil) -> DownloadedFile {
        DownloadedFile(episodeId: id, podcastId: show, bytes: Int64(size * Double(gb)), pubDate: nowMs - daysOld * day,
                       playedAt: playedHoursAgo.map { nowMs - $0 * 3_600_000 })
    }

    @Test func autoDownloadsFirstTenUpNextThenPriorityNew() {
        let queue = (1...14).map { DownloadPlanner.Candidate(episodeId: "q\($0)", podcastId: $0 == 2 ? "off" : "a", pubDate: nowMs - day) }
        let episodes = [
            DownloadPlanner.Candidate(episodeId: "p1", podcastId: "prio", pubDate: nowMs - day),
            DownloadPlanner.Candidate(episodeId: "p2", podcastId: "prio", pubDate: nowMs - 2 * day),
            DownloadPlanner.Candidate(episodeId: "p3", podcastId: "prio", pubDate: nowMs - 3 * day),
            DownloadPlanner.Candidate(episodeId: "pOld", podcastId: "prio", pubDate: nowMs - 30 * day),
            DownloadPlanner.Candidate(episodeId: "pPlayed", podcastId: "prio", pubDate: nowMs - day / 2, played: true),
            DownloadPlanner.Candidate(episodeId: "n1", podcastId: "normal", pubDate: nowMs - day),
            DownloadPlanner.Candidate(episodeId: "ghost", podcastId: "prio", pubDate: nowMs, hasEnclosure: false),
        ]
        let wanted = DownloadPlanner.autoDownloads(
            queue: queue, episodes: episodes, upNextCount: 10,
            autoDownload: { $0 != "off" }, isPriority: { $0 == "prio" }, keepLatest: { _ in 2 }, now: nowMs)
        #expect(wanted == ["q1", "q3", "q4", "q5", "q6", "q7", "q8", "q9", "q10", "p1", "p2"])
    }

    @Test func deletesPlayedAfter24Hours() {
        let files = [file("fresh", playedHoursAgo: 2), file("stale", playedHoursAgo: 25), file("unplayed")]
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: [], playing: nil, keepLatest: { _ in 10 }, deletePlayedAfter: 86_400, capBytes: 5 * gb, now: nowMs)
        #expect(doomed == ["stale"])
        let never = DownloadPlanner.filesToDelete(
            files: files, queue: [], playing: nil, keepLatest: { _ in 10 }, deletePlayedAfter: nil, capBytes: 5 * gb, now: nowMs)
        #expect(never.isEmpty)
    }

    @Test func keepsLatestNPerShowButNeverUpNext() {
        let files = [
            file("a1", daysOld: 1), file("a2", daysOld: 2), file("a3", daysOld: 3), file("a4", daysOld: 4),
            file("b1", show: "b", daysOld: 9),
        ]
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: ["a4"], playing: nil, keepLatest: { $0 == "a" ? 2 : 1 }, deletePlayedAfter: 86_400, capBytes: 5 * gb, now: nowMs)
        #expect(Set(doomed) == ["a3"])
    }

    @Test func storageCapNeverTouchesTopThree() {
        // 8 × 1 GB, all in Up Next, cap 5 GB: delete from the bottom, never q1–q3.
        let files = (1...8).map { file("q\($0)", gb: 1, daysOld: Double($0)) }
        let queue = (1...8).map { "q\($0)" }
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: queue, playing: nil, keepLatest: { _ in 1 }, deletePlayedAfter: 86_400, capBytes: 5 * gb, now: nowMs)
        #expect(doomed == ["q8", "q7", "q6"])

        // A cap the top three alone exceed: they stay anyway.
        let tight = DownloadPlanner.filesToDelete(
            files: files, queue: queue, playing: nil, keepLatest: { _ in 1 }, deletePlayedAfter: 86_400, capBytes: gb, now: nowMs)
        #expect(Set(tight) == Set((4...8).map { "q\($0)" }))
    }

    @Test func capPrefersPlayedThenOldestOutsideUpNext() {
        let files = [
            file("q1", gb: 2), file("old", show: "x", gb: 2, daysOld: 30), file("new", show: "y", gb: 2, daysOld: 2),
            file("played", show: "z", gb: 2, daysOld: 1, playedHoursAgo: 1),
        ]
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: ["q1"], playing: nil, keepLatest: { _ in 5 }, deletePlayedAfter: 86_400, capBytes: 5 * gb, now: nowMs)
        #expect(doomed == ["played", "old"])
    }

    @Test func keepLatestAllDeletesNothingButStillCleansUp() {
        // "All" (nil): no show's extras go, but played files and the cap still apply.
        let files = [
            file("a1", gb: 1, daysOld: 1), file("a2", gb: 1, daysOld: 2), file("a3", gb: 1, daysOld: 3), file("a4", gb: 1, daysOld: 4),
            file("played", gb: 1, daysOld: 5, playedHoursAgo: 25),
        ]
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: [], playing: nil, keepLatest: { _ in nil }, deletePlayedAfter: 86_400, capBytes: 5 * gb, now: nowMs)
        #expect(doomed == ["played"])
        let overCap = DownloadPlanner.filesToDelete(
            files: files, queue: [], playing: nil, keepLatest: { _ in nil }, deletePlayedAfter: nil, capBytes: 3 * gb, now: nowMs)
        #expect(overCap == ["played", "a4"])
    }

    @Test func priorityShowWithAllStillDownloadsOnlyTheNewestFew() {
        let episodes = (1...6).map { DownloadPlanner.Candidate(episodeId: "p\($0)", podcastId: "prio", pubDate: nowMs - Double($0) * day / 2) }
        let wanted = DownloadPlanner.autoDownloads(
            queue: [], episodes: episodes, autoDownload: { _ in true }, isPriority: { _ in true }, keepLatest: { _ in nil }, now: nowMs)
        #expect(wanted == ["p1", "p2", "p3"])
        #expect(DownloadPlanner.priorityDownloadsWithoutLimit == 3)
    }

    @Test func neverDeletesWhatsPlaying() {
        let files = [file("playing", playedHoursAgo: 48)]
        let doomed = DownloadPlanner.filesToDelete(
            files: files, queue: [], playing: "playing", keepLatest: { _ in 0 }, deletePlayedAfter: 0, capBytes: 0, now: nowMs)
        #expect(doomed.isEmpty)
    }
}

@MainActor
@Suite(.serialized) struct DownloadManagerTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "poddle-dl-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "poddle-dl-tests-\(UUID().uuidString)")!

    func makeManager(_ network: ManualNetworkMonitor, now: @escaping () -> Date = { t0 }) -> DownloadManager {
        DownloadManager(directory: dir, configuration: .ephemeral, monitor: network, defaults: defaults, now: now)
    }

    /// A small local "enclosure" (URLSession downloads file:// URLs too).
    func sampleFile() throws -> URL {
        let src = FileManager.default.temporaryDirectory.appending(path: "poddle-src-\(UUID().uuidString).mp3")
        try Data(repeating: 7, count: 64_000).write(to: src)
        return src
    }

    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func downloadsOnWifiAndHandsOffTheFile() async throws {
        let net = ManualNetworkMonitor(.wifi)
        let manager = makeManager(net)
        var ready: (String, URL)?
        manager.onFileReady = { ready = ($0, $1) }
        let src = try sampleFile()
        #expect(manager.request("ep1", url: src) == .started)
        await waitFor { manager.records["ep1"]?.state == .done }
        #expect(manager.downloads["ep1"]?.state == .done)
        #expect(ready?.0 == "ep1")
        let local = try #require(manager.localFile(for: "ep1"))
        #expect(local.pathExtension == "mp3")
        #expect(manager.storageUsed == 64_000)
        #expect(manager.request("ep1", url: src) == .alreadyDownloaded)

        manager.setLoudness(-19.5, for: "ep1")
        // State survives a relaunch.
        let again = makeManager(net)
        #expect(again.localFile(for: "ep1") != nil)
        #expect(again.loudness(for: "ep1") == -19.5)

        again.remove("ep1")
        #expect(again.localFile(for: "ep1") == nil)
        #expect(!FileManager.default.fileExists(atPath: local.path(percentEncoded: false)))
    }

    @Test func removeAllDeletesEveryFile() async throws {
        let net = ManualNetworkMonitor(.wifi)
        let manager = makeManager(net)
        let src = try sampleFile()
        _ = manager.request("ep1", url: src)
        _ = manager.request("ep2", url: src)
        await waitFor { manager.records["ep1"]?.state == .done && manager.records["ep2"]?.state == .done }
        let files = [try #require(manager.localFile(for: "ep1")), try #require(manager.localFile(for: "ep2"))]
        manager.removeAll()
        #expect(manager.records.isEmpty)
        #expect(manager.storageUsed == 0)
        for f in files { #expect(!FileManager.default.fileExists(atPath: f.path(percentEncoded: false))) }
        // And it stays that way after a relaunch.
        #expect(makeManager(net).records.isEmpty)
    }

    @Test func mobileTapPromptsAndAllowanceChipCountsDown() async throws {
        let net = ManualNetworkMonitor(.mobile)
        var clock = t0
        let manager = makeManager(net, now: { clock })
        await waitFor { manager.network == .mobile }
        let src = try sampleFile()
        #expect(manager.request("ep2", url: src) == .needsMobilePrompt)
        #expect(manager.records["ep2"] == nil)

        manager.resolvePrompt(.allowMobileForOneHour, episodeId: "ep2", url: src)
        #expect(manager.mobileAllowanceRemaining == 3_600)
        #expect(manager.records["ep2"]?.taskAllowsMobile == true)
        clock = t0.addingTimeInterval(1_800)
        #expect(manager.mobileAllowanceRemaining == 1_800)
        #expect(manager.request("ep3", url: src) == .started)

        manager.stopMobileAllowance()
        #expect(manager.mobileAllowanceRemaining == nil)
        #expect(manager.request("ep4", url: src) == .needsMobilePrompt)
        // Persisted per device.
        manager.setMode(.wifiAndMobile)
        #expect(makeManager(net).settings.mode == .wifiAndMobile)
    }

    /// A download started on mobile under the allowance, paused when it ran out, then resumed on
    /// Wi-Fi mustn't resume from its resume data: that request may still use mobile.
    @Test func resumingAfterTheAllowanceEndsIsWifiOnly() async throws {
        #expect(DownloadManager.canResume(taskAllowsMobile: true, allowsMobile: false) == false)
        #expect(DownloadManager.canResume(taskAllowsMobile: false, allowsMobile: false))
        #expect(DownloadManager.canResume(taskAllowsMobile: true, allowsMobile: true))

        let net = ManualNetworkMonitor(.mobile)
        let manager = makeManager(net)
        await waitFor { manager.network == .mobile }
        // Never answers, so it stays in flight (TEST-NET-1).
        let slow = URL(string: "http://192.0.2.1/episode.mp3")!
        manager.resolvePrompt(.allowMobileForOneHour, episodeId: "ep6", url: slow)
        #expect(manager.records["ep6"]?.taskAllowsMobile == true)

        manager.stopMobileAllowance()
        #expect(manager.records["ep6"]?.state == .pausedForWifi)
        // Resume data from the mobile-allowed request.
        try Data("resume".utf8).write(to: manager.resumeURL("ep6"))

        net.set(.wifi)
        await waitFor { manager.network == .wifi }
        #expect(manager.records["ep6"]?.state == .downloading)
        #expect(manager.records["ep6"]?.taskAllowsMobile == false)
        #expect(!FileManager.default.fileExists(atPath: manager.resumeURL("ep6").path(percentEncoded: false)))
        manager.remove("ep6")
    }

    @Test func allowanceEndingOnWifiRestartsWifiOnly() async throws {
        let net = ManualNetworkMonitor(.mobile)
        let manager = makeManager(net)
        await waitFor { manager.network == .mobile }
        let slow = URL(string: "http://192.0.2.1/episode2.mp3")!
        manager.resolvePrompt(.allowMobileForOneHour, episodeId: "ep7", url: slow)
        net.set(.wifi)
        await waitFor { manager.network == .wifi }
        #expect(manager.records["ep7"]?.taskAllowsMobile == true)
        manager.stopMobileAllowance()
        #expect(manager.records["ep7"]?.state == .downloading)
        #expect(manager.records["ep7"]?.taskAllowsMobile == false)
        manager.remove("ep7")
    }

    @Test func waitForWifiQueuesAWifiOnlyRequest() async throws {
        let net = ManualNetworkMonitor(.mobile)
        let manager = makeManager(net)
        await waitFor { manager.network == .mobile }
        let src = try sampleFile()
        manager.resolvePrompt(.waitForWifi, episodeId: "ep5", url: src)
        #expect(manager.records["ep5"]?.taskAllowsMobile == false)
        // (A file:// URL ignores the network, so it may already be done.)
        #expect([.waitingForWifi, .done].contains(manager.downloads["ep5"]?.state))
    }

    /// Never answers, so a task stays in flight (TEST-NET-1).
    func slow(_ name: String) -> URL { URL(string: "http://192.0.2.1/\(name).mp3")! }

    @Test func atMostTwoAtOnceInUpNextOrder() async throws {
        let manager = makeManager(ManualNetworkMonitor(.wifi))
        await waitFor { manager.network == .wifi }
        for id in ["a", "b", "c", "d"] { manager.request(id, url: slow(id), auto: true) }
        #expect(manager.records.values.filter { $0.state == .downloading }.map(\.episodeId).sorted() == ["a", "b"])
        #expect(manager.records["c"]?.state == .queued && manager.records["d"]?.state == .queued)
        #expect(manager.download(for: "d")?.state == .queued)

        // A slot frees up: the next in Up Next order starts, not the next requested.
        manager.setOrder(["d", "c"])
        #expect(manager.records["d"]?.state == .queued)
        manager.remove("a")
        #expect(manager.records["d"]?.state == .downloading)
        #expect(manager.records["c"]?.state == .queued)

        // A tap goes ahead of auto-downloads.
        manager.request("tap", url: slow("tap"))
        #expect(manager.records["tap"]?.state == .queued)
        manager.remove("b")
        #expect(manager.records["tap"]?.state == .downloading)
        #expect(manager.records["c"]?.state == .queued)

        // Failures free slots too.
        let taskId = try #require(manager.taskIdentifier(for: "d"))
        manager.handle(.failed("d", taskId: taskId, message: "nope", resumeData: nil))
        #expect(manager.records["d"]?.state == .failed)
        #expect(manager.records["c"]?.state == .downloading)
        for id in ["c", "d", "tap"] { manager.remove(id) }
    }

    @Test func pausedDownloadsWaitInLineWhenWifiReturns() async throws {
        let net = ManualNetworkMonitor(.mobile)
        let manager = makeManager(net)
        await waitFor { manager.network == .mobile }
        manager.allowMobile(.oneHour)
        for id in ["a", "b", "c"] { manager.request(id, url: slow(id), auto: true) }
        manager.stopMobileAllowance()
        #expect(manager.records["a"]?.state == .pausedForWifi && manager.records["b"]?.state == .pausedForWifi)
        // Nothing's running, but "c" can't use mobile, so it waits for Wi-Fi.
        #expect(manager.download(for: "c")?.state == .waitingForWifi)
        net.set(.wifi)
        await waitFor { manager.network == .wifi }
        #expect(manager.records.values.count { $0.state == .downloading } == 2)
        #expect(manager.records.values.count { $0.state == .queued } == 1)
        for id in ["a", "b", "c"] { manager.remove(id) }
    }

    /// Progress ticks redraw only the views that read `DownloadProgress`, never lists or rows.
    @Test func progressDoesNotInvalidateListsButStateChangesDo() async throws {
        var clock = t0
        let manager = makeManager(ManualNetworkMonitor(.wifi), now: { clock })
        await waitFor { manager.network == .wifi }
        let store = MockStore.makeStore(sync: false)
        store.downloader = manager
        let queued = MockData.playingEpisodeId
        #expect(store.queue.contains { $0.id == queued } && !store.inbox.isEmpty)

        manager.request(queued, url: slow("progress"))
        let taskId = try #require(manager.taskIdentifier(for: queued))
        manager.handle(.progress(queued, taskId: taskId, written: 1_000, expected: 100_000))
        #expect(store.download(for: queued)?.state == .downloading)

        let lists: [(String, () -> Void)] = [
            ("queue", { _ = store.queue }), ("inbox", { _ = store.inbox }), ("item", { _ = store.item(queued) }),
        ]
        let progress = try #require(store.downloadProgress(queued))
        var written: Int64 = 1_000
        for _ in 1...3 {
            for (name, read) in lists {
                clock = clock.addingTimeInterval(1) // past the 4-a-second throttle
                written += 4_000
                let fired = invalidates(read) {
                    manager.handle(.progress(queued, taskId: taskId, written: written, expected: 100_000))
                }
                #expect(!fired, "progress invalidated \(name)")
            }
        }
        clock = clock.addingTimeInterval(1)
        #expect(invalidates({ _ = progress.fraction }) {
            manager.handle(.progress(queued, taskId: taskId, written: 50_000, expected: 100_000))
        })
        #expect(progress.fraction == 0.5)
        #expect(manager.records[queued]?.bytesWritten == 1_000) // untouched since the first bytes

        let done = invalidates({ _ = store.queue; _ = store.inbox; _ = store.item(queued) }) {
            manager.handle(.finished(queued, taskId: taskId, fileName: "progress.mp3", bytes: 100_000))
        }
        #expect(done)
        #expect(store.item(queued)?.isDownloaded == true)
        #expect(progress.fraction == 1)
        manager.remove(queued)
    }

    private func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
        let fired = Flag()
        withObservationTracking(read) { fired.value = true }
        change()
        return fired.value
    }
}

private final class Flag: @unchecked Sendable { var value = false }
