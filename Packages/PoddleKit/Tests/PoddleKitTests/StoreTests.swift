import Foundation
import Testing
@testable import PoddleKit

@MainActor
@Suite struct MockStoreActionTests {
    let store = MockStore.makeStore(sync: false)

    var queueIds: [String] { store.queue.map(\.id) }

    @Test func sampleDataMatchesTheDesign() {
        let upNext = store.upNext(excluding: MockData.playingEpisodeId)
        #expect(upNext.count == 6)
        #expect(Format.queueSummary(count: upNext.count, wallSeconds: store.wallTime(upNext)) == "6 episodes · 4h 42m at your speeds")
        #expect(upNext.first?.timeLabel == "38m left at 1.8×")
        let conan = upNext.first { $0.podcast.id == "pod_conan" }
        #expect(conan?.timeLabel == "52m at 1.2×")
        #expect(conan?.speed.isOverride == true)
        #expect(upNext.filter(\.isDownloaded).count == 5)
        // Up Next rows show real lengths: 68.4 minutes left of Syntax, the whole 62.4 of Conan.
        #expect(upNext.first?.lengthLabel == "1h 8m left")
        #expect(conan?.lengthLabel == "1h 2m")
        #expect(store.item(MockData.playingEpisodeId)?.timeLabel == "52m left at 1.4×")
        #expect(store.podcast("pod_mike")?.isPrivate == true)
        #expect(store.cadence("pod_syntax") == "3 a week")
    }

    @Test func queueNextAndLast() {
        let inboxEp = "ep_syntax_912"
        #expect(store.inbox.contains { $0.id == inboxEp })
        store.playNext(inboxEp)
        #expect(queueIds[1] == inboxEp)
        #expect(!store.inbox.contains { $0.id == inboxEp })

        store.queueLast("ep_syntax_911")
        #expect(queueIds.last == "ep_syntax_911")

        // Idempotent: applying again changes nothing.
        let before = store.snapshot.queue
        store.queueLast("ep_syntax_911")
        store.playNext(inboxEp)
        #expect(store.snapshot.queue == before)
    }

    @Test func moveToTopAndReorder() {
        store.moveToTop("ep_atp_649")
        #expect(queueIds.first == "ep_atp_649")
        #expect(queueIds[1] == MockData.playingEpisodeId)

        // Drag Mike Pod (index 4 of the visible list) to the top of the visible list.
        let visible = store.upNext(excluding: "ep_atp_649").map(\.id)
        let from = visible.firstIndex(of: "ep_mike_tue")!
        store.moveQueue(ids: visible, from: IndexSet(integer: from), to: 0)
        #expect(store.upNext(excluding: "ep_atp_649").first?.id == "ep_mike_tue")
        #expect(queueIds.first == "ep_atp_649")
        #expect(store.snapshot.queue.map(\.orderKey) == store.snapshot.queue.map(\.orderKey).sorted())
    }

    @Test func dragToEnd() {
        let visible = store.upNext(excluding: MockData.playingEpisodeId).map(\.id)
        store.moveQueue(ids: visible, from: IndexSet(integer: 0), to: visible.count)
        #expect(queueIds.last == visible[0])
    }

    @Test func removeArchiveAndMarkPlayed() {
        store.removeFromQueue("ep_hardfork_shop")
        #expect(!queueIds.contains("ep_hardfork_shop"))
        #expect(store.item("ep_hardfork_shop")?.state.played == false)

        store.markPlayed("ep_conan_mail")
        #expect(!queueIds.contains("ep_conan_mail"))
        #expect(store.item("ep_conan_mail")?.state.played == true)

        store.archive("ep_changelog_kaizen")
        #expect(!store.inbox.contains { $0.id == "ep_changelog_kaizen" })
        #expect(store.item("ep_changelog_kaizen")?.state.archived == true)
    }

    @Test func starAndOlder() {
        store.toggleStar("ep_syntax_912")
        #expect(store.item("ep_syntax_912")?.isStarred == true)
        store.toggleStar("ep_syntax_912")
        #expect(store.item("ep_syntax_912")?.isStarred == false)

        store.markOlderPlayed("ep_syntax_912")
        #expect(store.item("ep_syntax_911")?.state.played == true)
        #expect(store.item("ep_syntax_910")?.state.played == true)
        #expect(store.item("ep_syntax_912")?.state.played == false)
    }

    @Test func archiveOlderOnlyTouchesInbox() {
        store.archiveOlder("ep_changelog_kaizen")
        #expect(store.item("ep_changelog_news")?.state.archived == true)
        #expect(store.item("ep_changelog_htmx")?.state.archived == false)
    }

    @Test func speedScopes() {
        #expect(store.defaultSpeedScope(for: "pod_dwarkesh") == .show("pod_dwarkesh"))
        #expect(store.defaultSpeedScope(for: "pod_syntax") == .allPodcasts)

        store.setSpeed(1.63, scope: .show("pod_dwarkesh"))
        #expect(store.resolved("pod_dwarkesh").speed.value == 1.65)
        store.setSpeed(2.0, scope: .allPodcasts)
        #expect(store.resolved("pod_syntax").speed == Resolved(2.0, isOverride: false))
        #expect(store.resolved("pod_dwarkesh").speed.value == 1.65)

        store.resetSpeed(scope: .show("pod_dwarkesh"))
        #expect(store.resolved("pod_dwarkesh").speed == Resolved(2.0, isOverride: false))
    }

    @Test func showSettings() {
        store.updateSettings("pod_syntax") { $0.voiceBoost = false; $0.skipIntro = 30 }
        let r = store.resolved("pod_syntax")
        #expect(r.voiceBoost == Resolved(false, isOverride: true))
        #expect(r.skipIntro.value == 30)
        store.updateSettings("pod_syntax") { $0.voiceBoost = nil }
        #expect(store.resolved("pod_syntax").voiceBoost == Resolved(true, isOverride: false))
        store.updateGlobal { $0.voiceBoost = false }
        #expect(store.resolved("pod_syntax").voiceBoost.value == false)
    }

    @Test func subscribeAndUnsubscribe() {
        let practical = MockData.search("practical").results[0]
        #expect(!store.isFollowing(feedURL: practical.feedURL))
        store.subscribe(practical)
        #expect(store.isFollowing(feedURL: practical.feedURL))
        #expect(store.library.contains { $0.title == "Practical AI" })

        store.unsubscribe("pod_hardfork")
        #expect(!store.library.contains { $0.id == "pod_hardfork" })
        #expect(!queueIds.contains("ep_hardfork_shop"))
        #expect(store.pastShows.contains { $0.id == "pod_hardfork" })
    }

    @Test func clearQueueKeepsCurrent() {
        store.clearQueue(keeping: MockData.playingEpisodeId)
        #expect(queueIds == [MockData.playingEpisodeId])
    }

    @Test func search() {
        let r = MockData.search("ai pod")
        #expect(r.results.prefix(5).map(\.title) == ["Latent Space", "Practical AI", "No Priors", "The Cognitive Revolution", "Dwarkesh Podcast"])
        #expect(MockData.search("").results.isEmpty)
    }
}

@MainActor
@Suite struct SyncTests {
    @Test func mockServerEchoesMutations() async throws {
        let seed = MockData.snapshot()
        let source = MockStore(snapshot: seed, latency: 0)
        let store = PoddleStore(dataSource: source, seed: seed)
        store.markPlayed("ep_conan_mail")
        store.subscribe(MockData.search("acquired").results[0])
        for _ in 0..<100 where !store.pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.pending.isEmpty)
        #expect(store.item("ep_conan_mail")?.state.played == true)
        // The server swapped the optimistic show for its own, episodes and all.
        let acquired = try #require(store.library.first { $0.title == "Acquired" })
        #expect(!acquired.id.hasPrefix("local-"))
        #expect(store.episodes(of: acquired.id).count == 5)
        #expect(store.inbox.contains { $0.podcast.id == acquired.id })
    }

    @Test func importStreamsToDone() async throws {
        let seed = MockData.snapshot()
        let store = PoddleStore(dataSource: MockStore(snapshot: seed, latency: 0), seed: seed)
        store.startImport(fileName: "overcast.opml", data: Data(), assumedSpeed: 1.8)
        for _ in 0..<200 where store.importProgress?.phase != .done { try await Task.sleep(for: .milliseconds(10)) }
        let p = try #require(store.importProgress)
        #expect(p.phase == .done)
        #expect(p.podcasts == 84)
        #expect(p.playedEpisodes == 3412)
        #expect(p.hours == 1920)
    }

    @Test func statsLoad() async {
        let store = MockStore.makeStore(sync: false)
        await store.loadStats(year: Calendar.current.component(.year, from: Date()))
        #expect(store.stats.map { Format.hours($0.listenedSeconds) } == "612h")
        #expect(store.stats?.heatmap.count == 7)
        #expect(store.stats?.heatmap.first?.count == 24)
    }
}

@MainActor
@Suite struct MockPlayerTests {
    @Test func ticksAtTheShowsSpeed() async {
        let store = MockStore.makeStore(sync: false)
        let player = MockPlayer(store: store)
        player.load(MockData.playingEpisodeId)
        #expect(player.position == MockData.playingPosition)
        #expect(player.rate == 1.4)
        player.resume()
        let start = player.position
        player.tick(now: Date().addingTimeInterval(10))
        #expect(abs(player.position - start - 14) < 0.5)
        player.pause()
        #expect(store.item(MockData.playingEpisodeId)!.state.position > start)
    }

    @Test func finishingAdvancesTheQueue() {
        let store = MockStore.makeStore(sync: false)
        let player = MockPlayer(store: store)
        player.load(MockData.playingEpisodeId)
        player.resume()
        player.seek(to: player.duration - 1)
        player.tick(now: Date().addingTimeInterval(5))
        #expect(store.item(MockData.playingEpisodeId)?.state.played == true)
        #expect(player.currentEpisodeId == "ep_syntax_910")
        #expect(player.isPlaying)
    }

    @Test func playNowMovesCurrentDown() {
        let store = MockStore.makeStore(sync: false)
        let player = MockPlayer(store: store)
        player.load(MockData.playingEpisodeId)
        player.play("ep_conan_mail")
        #expect(store.queue.map(\.id).prefix(2) == ["ep_conan_mail", MockData.playingEpisodeId])
        // Conan skips its 45 s cold open.
        #expect(player.position == 45)
        player.pause()
    }

    @Test func chaptersAndSleep() async {
        let store = MockStore.makeStore(sync: false)
        let player = MockPlayer(store: store)
        player.load(MockData.playingEpisodeId)
        _ = await store.chapters(for: MockData.playingEpisodeId)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(player.chapters.count == 9)
        #expect(player.currentChapterIndex == 4)
        player.nextChapter()
        #expect(player.currentChapterIndex == 5)
        player.setSleepTimer(.endOfEpisode)
        #expect(player.sleepTimer == .endOfEpisode)
    }
}

/// Regressions the e2e suite found (docs/testing.md).
@MainActor
@Suite struct AccountAndPastShowsTests {
    @Test func pastShowsFromTheServerShowWithoutLocalHistory() {
        // An Overcast import's unsubscribed show: the server knows it has history, but its
        // episodes aren't synced, so nothing here says so.
        var seed = MockData.snapshot()
        let id = seed.podcasts.keys.sorted().first!
        seed.podcasts[id]?.subscribed = false
        for (episodeId, episode) in seed.episodes where episode.podcastId == id { seed.states[episodeId] = nil }
        seed.queue.removeAll { seed.episodes[$0.episodeId]?.podcastId == id }
        let without = MockStore.makeStore(seed: seed, downloads: [:], sync: false)
        #expect(!without.pastShows.contains { $0.id == id })

        seed.pastShowIds = [id]
        let with = MockStore.makeStore(seed: seed, downloads: [:], sync: false)
        #expect(with.pastShows.map(\.id).contains(id))
    }

    @Test func signingInAgainAsksScreensToReload() {
        let store = MockStore.makeStore(sync: false)
        let before = store.accountGeneration
        store.resetForAccountChange()
        #expect(store.accountGeneration == before + 1)
        #expect(store.stats == nil)
    }
}
