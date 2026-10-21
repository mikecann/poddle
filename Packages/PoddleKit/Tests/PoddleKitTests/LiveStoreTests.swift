import Foundation
import Testing
@testable import PoddleKit

private let deployment = URL(string: "https://qualified-hedgehog-912.convex.cloud")!

private func makeStore(_ fake: FakeTransport, _ disk: LiveDisk, clock: TickingClock = TickingClock()) -> LiveStore {
    LiveStore(
        deploymentURL: deployment, token: "test-token", deviceId: "device-1",
        transport: { _ in fake }, disk: { _ in disk }, timing: .fast, now: { clock.now() }
    )
}

@Suite struct OutboxTests {
    @Test func survivesRelaunchAndReplaysInOrder() async throws {
        let fake = FakeTransport()
        fake.online = false
        let disk = tempDisk()
        defer { disk.erase() }

        let first = makeStore(fake, disk)
        _ = await first.snapshots()
        try await first.send(.setStarred(episodeId: "ep1", true))
        try await first.send(.enqueue(episodeId: "ep2", position: .last))
        try await first.send(.setPlayed(episodeId: "ep3", true))
        let queued = await first.pendingEntries
        #expect(queued.count == 3)
        await first.stop()
        #expect(fake.mutations.isEmpty)

        // Relaunch, still offline: the outbox is back, and the cached snapshot shows the actions.
        let seed = LiveStore.cachedSnapshot(disk: disk)
        #expect(seed.state("ep1").isStarred)
        #expect(seed.isQueued("ep2"))
        #expect(seed.state("ep3").played)
        let second = makeStore(fake, disk)
        #expect(await second.pendingEntries == queued)

        // Back online: replayed in order, unchanged, with the original times.
        _ = await second.snapshots()
        fake.online = true
        #expect(await eventually { await second.pendingEntries.isEmpty })
        #expect(fake.mutations.map(\.name) == ["episodes:setStarredState", "queue:add", "episodes:setPlayedState"])
        #expect(fake.mutations.map { $0.args["at"] } == queued.map { .number($0.at) })
        #expect(fake.mutations.allSatisfy { $0.args["token"] == "test-token" })
        #expect(fake.mutations[1].args["position"] == "bottom")
        #expect(disk.loadOutbox().pending.isEmpty)
        await second.stop()
    }

    @Test func networkErrorsRetryWithoutLosingAnything() async throws {
        let fake = FakeTransport()
        fake.failNext = 3
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        for i in 1...4 { try await store.send(.setArchived(episodeId: "ep\(i)", true)) }
        #expect(await eventually { await store.pendingEntries.isEmpty })
        #expect(fake.mutations.map { $0.args["episodeId"] } == ["ep1", "ep2", "ep3", "ep4"])
        #expect(await store.failedEntries.isEmpty)
        await store.stop()
    }

    @Test func rejectedActionsAreKeptForRetry() async throws {
        let fake = FakeTransport()
        fake.rejects = ["queue:add"]
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        try await store.send(.enqueue(episodeId: "ep1", position: .next))
        try await store.send(.setStarred(episodeId: "ep2", true))
        #expect(await eventually { await store.pendingEntries.isEmpty })
        // The rejection didn't block the next action, and it's kept, on disk too.
        #expect(fake.mutations.map(\.name) == ["episodes:setStarredState"])
        #expect(await store.failedEntries.map(\.mutation) == [.enqueue(episodeId: "ep1", position: .next)])
        #expect(disk.loadOutbox().failed.count == 1)
        #expect(await store.status.failed == 1)

        fake.rejects = []
        await store.retryFailed()
        #expect(await eventually { await store.pendingEntries.isEmpty })
        #expect(fake.mutations.map(\.name) == ["episodes:setStarredState", "queue:add"])
        #expect(await store.failedEntries.isEmpty)
        await store.stop()
    }

    @Test func privateSubscribeUsesTheNewPodcastId() async throws {
        let fake = FakeTransport()
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        try await store.send(.subscribe(SubscribeRequest(feedURL: "https://example.com/feed?token=abc", title: "Secret", isPrivate: true)))
        #expect(await eventually { await store.pendingEntries.isEmpty })
        #expect(fake.mutations.map(\.name) == ["podcasts:subscribe", "podcasts:setPrivate"])
        #expect(fake.mutations[0].args["title"] == "Secret")
        #expect(fake.mutations[0].args["author"] == nil) // optional args are left out, never null
        #expect(fake.mutations[1].args["podcastId"] == "pod_new")
        await store.stop()
    }

    @Test func positionSavesCoalesce() async throws {
        let fake = FakeTransport()
        fake.online = false
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        try await store.send(.setStarred(episodeId: "ep0", true))
        for p in [10.0, 40, 70] { try await store.send(.savePosition(episodeId: "ep1", position: p, device: "x")) }
        let pending = await store.pendingEntries
        #expect(pending.count == 2)
        #expect(pending.last?.calls.first?.args["position"] == 70)
        #expect(pending.last?.calls.first?.args["deviceId"] == "device-1")
        await store.stop()
    }
}

@Suite struct MutationMappingTests {
    let base = MockData.snapshot(now: Date(timeIntervalSince1970: 1_790_000_000))

    @Test func settingsPatchesOnlyCarryChangedFields() {
        var g = base.global
        g.skipBack = 10
        let calls = LiveStore.calls(for: .updateGlobalSettings(g), at: 5, base: base, deviceId: "d")
        #expect(calls.count == 1)
        #expect(calls[0].name == "settings:updateGlobal")
        #expect(calls[0].args["patch"] == ["skipBackSeconds": 10])

        var s = base.podcastSettings["pod_conan"] ?? PodcastSettings(podcastId: "pod_conan")
        s.speed = nil
        s.autoAdd = .dontAdd
        let show = LiveStore.calls(for: .updatePodcastSettings(s), at: 5, base: base, deviceId: "d")
        #expect(show.first?.args["patch"]?["newEpisodes"] == "none")
        #expect(show.first?.args["patch"]?["playbackSpeed"] == .null) // null = back to "use default"
        #expect(LiveStore.calls(for: .updateGlobalSettings(base.global), at: 5, base: base, deviceId: "d").isEmpty)
    }

    @Test func clearQueueKeepsThePlayingItem() {
        let playing = base.queue[0].episodeId
        let calls = LiveStore.calls(for: .clearQueue(keeping: playing), at: 5, base: base, deviceId: "d")
        #expect(calls.count == base.queue.count - 1)
        #expect(calls.allSatisfy { $0.name == "queue:remove" && $0.args["episodeId"] != .string(playing) })
    }

    @Test func archivingAQueuedEpisodeAlsoRemovesIt() {
        let queued = base.queue[1].episodeId
        let calls = LiveStore.calls(for: .setArchived(episodeId: queued, true), at: 5, base: base, deviceId: "d")
        #expect(calls.map(\.name) == ["episodes:setArchivedState", "queue:remove"])
    }

    @Test func markOlderPlayedUsesBeforePubDate() {
        let ep = base.episodes.values.first!
        let calls = LiveStore.calls(for: .markOlderPlayed(episodeId: ep.id), at: 5, base: base, deviceId: "d")
        #expect(calls.first?.name == "podcasts:markAllPlayed")
        #expect(calls.first?.args["beforePubDate"] == .number(ep.pubDate))
    }
}

@Suite struct SnapshotCacheTests {
    @Test func cacheRoundTrips() throws {
        let disk = tempDisk()
        defer { disk.erase() }
        var cache = LiveCache()
        cache.snapshot = MockData.snapshot(now: Date(timeIntervalSince1970: 1_790_000_000))
        cache.since = ["episodes": 123, "podcasts": 456]
        cache.syncedAt = 789
        cache.stats["2026"] = MockData.stats(year: 2026, currentYear: 2026)
        cache.years = [2026, 2025]
        try disk.save(cache)
        #expect(disk.loadCache() == cache)
        #expect(LiveStore.cachedSnapshot(disk: disk) == cache.snapshot)
    }

    @Test func liveResultsAreCachedForTheNextLaunch() async throws {
        let fake = FakeTransport()
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        let stream = await store.snapshots()
        fake.push("podcasts:list", """
        [{"_id":"p1","_creationTime":1,"feedUrl":"https://a.example/feed","title":"Alpha","isPrivate":false,"subscribed":true,
          "subscriptionUpdatedAt":1,"episodeCount":1,"createdAt":1,"updatedAt":1,"appleId":617416468}]
        """)
        fake.push("queue:upNext", """
        [{"item":{"_id":"q1","episodeId":"e1","podcastId":"p1","orderKey":"a0","addedAt":5,"addedBy":"manual","orderUpdatedAt":5,"updatedAt":5},
          "row":{"episode":{"_id":"e1","podcastId":"p1","title":"One","pubDate":1000,"duration":3600,"transcripts":[],"isGhost":false,"firstSeenAt":1,"updatedAt":1},
                 "state":{"_id":"s1","episodeId":"e1","podcastId":"p1","position":120,"positionUpdatedAt":9,"played":false,"playedUpdatedAt":0,
                          "starred":true,"starredAt":7,"starredUpdatedAt":7,"archived":false,"archivedUpdatedAt":0,"inInbox":false,"inboxUpdatedAt":0,"updatedAt":9},
                 "podcast":{"_id":"p1","title":"Alpha","isPrivate":false}}}]
        """)
        var latest = LibrarySnapshot()
        for await s in stream {
            latest = s
            if s.queue.count == 1 && s.podcasts["p1"] != nil { break }
        }
        #expect(latest.podcasts["p1"]?.appleId == "617416468")
        #expect(latest.state("e1").position == 120)
        #expect(latest.state("e1").isStarred)
        await store.flush()
        let reloaded = LiveStore.cachedSnapshot(disk: disk)
        #expect(reloaded.queue.map(\.episodeId) == ["e1"])
        #expect(reloaded.episodes["e1"]?.duration == 3600)
        await store.stop()
    }
}

@Suite struct CatchUpTests {
    @Test func pagesTablesAndAppliesDeletions() async throws {
        let fake = FakeTransport()
        fake.respond = { name, args in
            guard name == "sync:changes", let table = args["table"]?.string else { return Data("null".utf8) }
            let cursor = args["paginationOpts"]?["cursor"]?.string
            let json: String
            switch (table, cursor) {
            case ("episodes", nil):
                json = #"{"page":[{"_id":"e1","podcastId":"p1","title":"One","pubDate":10,"transcripts":[],"isGhost":false,"firstSeenAt":1,"updatedAt":100}],"isDone":false,"continueCursor":"c1","maxUpdatedAt":100}"#
            case ("episodes", "c1"):
                json = #"{"page":[{"_id":"e2","podcastId":"p1","title":"Two","pubDate":20,"transcripts":[],"isGhost":true,"firstSeenAt":1,"updatedAt":250}],"isDone":true,"continueCursor":"c2","maxUpdatedAt":250}"#
            case ("queueItems", _):
                json = #"{"page":[{"_id":"q1","episodeId":"e1","podcastId":"p1","orderKey":"a1","addedAt":1,"addedBy":"auto","orderUpdatedAt":1,"updatedAt":90},{"_id":"q2","episodeId":"e2","podcastId":"p1","orderKey":"a0","addedAt":1,"addedBy":"manual","orderUpdatedAt":1,"updatedAt":95}],"isDone":true,"continueCursor":"x","maxUpdatedAt":95}"#
            case ("deletions", _):
                json = #"{"page":[{"_id":"d1","table":"queueItems","docId":"q2","episodeId":"e2","deletedAt":96,"updatedAt":96}],"isDone":true,"continueCursor":"x","maxUpdatedAt":96}"#
            case ("globalSettings", _):
                json = #"{"page":[{"_id":"g","skipBackSeconds":10,"newEpisodes":"none","fieldTimes":{},"updatedAt":50}],"isDone":true,"continueCursor":"x","maxUpdatedAt":50}"#
            default:
                json = #"{"page":[],"isDone":true,"continueCursor":"","maxUpdatedAt":null}"#
            }
            return Data(json.utf8)
        }
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        await store.catchUp()
        let cache = await store.cachedState
        #expect(cache.snapshot.episodes.keys.sorted() == ["e1", "e2"])
        #expect(cache.snapshot.episodes["e2"]?.isGhost == true)
        #expect(cache.snapshot.queue.map(\.id) == ["q1"]) // q2 was deleted
        #expect(cache.snapshot.global.skipBack == 10)
        #expect(cache.snapshot.global.autoAdd == .dontAdd)
        #expect(cache.since["episodes"] == 250)
        #expect(cache.syncedAt != nil)

        // The next pass asks from the stored cursor; the server applies its own overlap.
        await store.catchUp()
        let episodeQueries = fake.queries.filter { $0.args["table"] == "episodes" }
        #expect(episodeQueries.first?.args["since"] == 0)
        #expect(episodeQueries.last?.args["since"] == 250)
        #expect(episodeQueries.allSatisfy { $0.args["token"] == "test-token" })
    }
}
