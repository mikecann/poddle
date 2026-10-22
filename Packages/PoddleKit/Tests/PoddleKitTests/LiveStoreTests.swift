import Foundation
import Testing
@testable import PoddleKit

private let deployment = URL(string: "https://qualified-hedgehog-912.convex.cloud")!

/// Hands out a fixed access token, like a signed-in `Account`.
final class FixedToken: AuthTokenSource, @unchecked Sendable {
    let token: String
    init(_ token: String) { self.token = token }
    func accessToken(forceRefresh: Bool) async -> String? { token }
}

private func makeStore(_ fake: FakeTransport, _ disk: LiveDisk, clock: TickingClock = TickingClock()) -> LiveStore {
    LiveStore(
        deploymentURL: deployment, deviceId: "device-1", userId: "user-mike", auth: FixedToken("mike-token"),
        transport: { _ in fake }, disk: { _, _ in disk }, timing: .fast, now: { clock.now() }
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
        #expect(fake.mutations.allSatisfy { $0.args["token"] == nil })
        #expect(await (fake.auth as? FixedToken)?.token == "mike-token")
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

@Suite struct PlaybackRecordTests {
    private func session(_ id: String, end: Millis, route: String? = nil) -> SessionInput {
        SessionInput(
            sessionId: id, episodeId: "ep1", deviceId: "device-1", startedAt: 1_000, endedAt: end,
            contentStart: 0, contentEnd: end / 1000, rate: 1.8, smartSpeed: true, smartRemovedContent: 2,
            voiceBoost: true, route: route, utcOffsetMinutes: 660
        )
    }

    private func first(_ call: FakeTransport.Call?) -> JSONValue? {
        guard case let .array(a)? = call?.args["sessions"] else { return nil }
        return a.first
    }

    @Test func sessionsGoThroughTheOutboxAndNewerCopiesReplaceWaitingOnes() async throws {
        let fake = FakeTransport()
        fake.online = false
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        try await store.recordSessions([session("s1", end: 10_000)])
        try await store.send(.setStarred(episodeId: "ep0", true))
        try await store.recordSessions([session("s1", end: 20_000), session("s2", end: 5_000)])
        try await store.recordSessions([session("s1", end: 30_000)])
        // The head may already be on its way; everything behind it keeps only the newest copy.
        let pending = await store.pendingEntries.map(\.mutation)
        #expect(pending == [
            .recordSessions([session("s1", end: 10_000)]),
            .setStarred(episodeId: "ep0", true),
            .recordSessions([session("s2", end: 5_000)]),
            .recordSessions([session("s1", end: 30_000)]),
        ])

        fake.online = true
        #expect(await eventually { await store.pendingEntries.isEmpty })
        #expect(fake.mutations.map(\.name) == ["sessions:record", "episodes:setStarredState", "sessions:record", "sessions:record"])
        let sent = first(fake.mutations[0])
        #expect(sent?["sessionId"] == "s1")
        #expect(sent?["utcOffsetMinutes"] == 660)
        #expect(sent?["route"] == nil) // optional fields are left out, never null
        await store.stop()
    }

    @Test func forwarderHandsSessionsToTheOutboxOnce() async throws {
        let fake = FakeTransport()
        fake.online = false
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        let forwarder = await SessionForwarder(dataSource: store, deviceId: "device-1", retryAfter: .milliseconds(10))
        let id = UUID()
        for end in [31_000.0, 61_000] {
            await forwarder.record(ListeningCheckpoint(
                id: id, episodeId: "ep1", wallStart: 1_000, wallEnd: end, contentStart: 0, contentEnd: end / 500,
                rate: 2, smartSpeed: true, smartRemovedContent: 0, voiceBoost: false, route: "headphones", isFinal: false))
            await forwarder.flush()
        }
        // Offline, but the outbox has them on disk: the forwarder has nothing left to retry.
        #expect(await forwarder.pending.isEmpty)
        #expect(await store.pendingEntries.count == 2)

        fake.online = true
        #expect(await eventually { await store.pendingEntries.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.mutations.map(\.name) == ["sessions:record", "sessions:record"])
        #expect(fake.mutations.map { first($0)?["sessionId"] } == [.string(id.uuidString.lowercased()), .string(id.uuidString.lowercased())])
        #expect(first(fake.mutations.last)?["endedAt"] == 61_000)
        await store.stop()
    }

    @Test func registerDeviceSendsTheNewestTokenWithThisDevice() async throws {
        let fake = FakeTransport()
        fake.online = false
        let disk = tempDisk()
        defer { disk.erase() }
        let store = makeStore(fake, disk)
        _ = await store.snapshots()
        try await store.send(.setStarred(episodeId: "ep0", true))
        try await store.registerDevice(apnsToken: "aa11", environment: .sandbox)
        try await store.registerDevice(apnsToken: "bb22", environment: .sandbox)
        fake.online = true
        #expect(await eventually { await store.pendingEntries.isEmpty })
        #expect(fake.mutations.map(\.name) == ["episodes:setStarredState", "devices:register"])
        let args = fake.mutations[1].args
        #expect(args["apnsToken"] == "bb22")
        #expect(args["apnsEnvironment"] == "sandbox")
        #expect(args["deviceId"] == "device-1")
        #expect(args["platform"] == "macOS")
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
        #expect(episodeQueries.allSatisfy { $0.args["token"] == nil })
    }
}


@Suite struct AccountSwitchTests {
    /// One folder per person under a temp deployment folder, like `LiveDisk.forUser`.
    private func perUser(_ root: URL) -> @Sendable (URL, String) -> LiveDisk {
        { _, user in LiveDisk(directory: root.appending(path: user)) }
    }

    @Test func eachPersonHasTheirOwnCacheAndOutbox() async throws {
        let fake = FakeTransport()
        fake.online = false
        let root = FileManager.default.temporaryDirectory.appending(path: "poddle-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveStore(
            deploymentURL: deployment, deviceId: "device-1", userId: "mike", auth: FixedToken("m"),
            transport: { _ in fake }, disk: perUser(root), timing: .fast, now: { TickingClock().now() }
        )
        let stream = await store.snapshots()
        var it = stream.makeAsyncIterator()
        _ = await it.next()
        try await store.send(.setStarred(episodeId: "ep1", true))
        #expect(await store.pendingEntries.count == 1)

        // Mike signs out: nothing to see, and nothing can be queued.
        await store.switchAccount(userId: nil, auth: nil)
        #expect(await store.pendingEntries.isEmpty)
        try await store.send(.setStarred(episodeId: "ep2", true))
        #expect(await store.pendingEntries.isEmpty)

        // Ana signs in: she starts empty, never sees Mike's queued action.
        await store.switchAccount(userId: "ana", auth: FixedToken("a"))
        #expect(await store.pendingEntries.isEmpty)
        #expect(await store.cachedState.snapshot.state("ep1").isStarred == false)
        try await store.send(.enqueue(episodeId: "ep3", position: .last))

        // Mike again: his queued star is still waiting, and replays once online, as him.
        await store.switchAccount(userId: "mike", auth: FixedToken("m"))
        #expect(await store.pendingEntries.map(\.mutation) == [.setStarred(episodeId: "ep1", true)])
        fake.online = true
        #expect(await eventually { await store.pendingEntries.isEmpty })
        #expect(fake.mutations.map(\.name) == ["episodes:setStarredState"])
        #expect(await (fake.auth as? FixedToken)?.token == "m")
        #expect(LiveDisk(directory: root.appending(path: "ana")).loadOutbox().pending.count == 1)
        await store.stop()
    }

    @Test func signedOutStartsNothing() async {
        let fake = FakeTransport()
        let store = LiveStore(
            deploymentURL: deployment, deviceId: "device-1", userId: nil, auth: nil,
            transport: { _ in fake }, disk: { _, _ in tempDisk() }, timing: .fast
        )
        _ = await store.snapshots()
        await store.catchUp()
        #expect(fake.queries.isEmpty)
        #expect(LiveStore.cachedSnapshot(disk: nil) == LibrarySnapshot())
    }
}

@Suite struct SharedLinkTests {
    @Test func fetchesALinkedEpisodeAndShowThatArentInTheLibrary() async throws {
        let fake = FakeTransport()
        fake.respond = { name, args in
            switch (name, args["episodeId"]?.string ?? args["podcastId"]?.string) {
            case ("episodes:get", "e9"?):
                Data(#"{"row":{"episode":{"_id":"e9","podcastId":"p9","title":"Shared","duration":600,"transcripts":[],"isGhost":false,"firstSeenAt":1,"updatedAt":1},"state":null,"podcast":{"_id":"p9","title":"Elsewhere","isPrivate":false}},"inQueue":false}"#.utf8)
            case ("podcasts:get", "p9"?):
                Data(#"{"podcast":{"_id":"p9","_creationTime":1,"feedUrl":"https://b.example/feed","title":"Elsewhere","description":"About it","isPrivate":false,"subscribed":false,"subscriptionUpdatedAt":0,"episodeCount":1,"createdAt":1,"updatedAt":1},"overrides":{},"resolved":{},"feed":{}}"#.utf8)
            case ("sync:changes", _):
                Data(#"{"page":[],"isDone":true,"continueCursor":"","maxUpdatedAt":null}"#.utf8)
            default: Data("null".utf8)
            }
        }
        let disk = tempDisk()
        defer { disk.erase() }
        let live = makeStore(fake, disk)
        let store = await MainActor.run { PoddleStore(dataSource: live, deviceId: "device-1") }

        #expect(await store.loadShared(.episode(id: "e9", startAt: 30)))
        await MainActor.run {
            #expect(store.item("e9")?.episode.title == "Shared")
            #expect(store.podcast("p9")?.subscribed == false)
        }
        #expect(await store.loadShared(.show(id: "p9")))
        await MainActor.run { #expect(store.podcast("p9")?.feedURL == "https://b.example/feed") }
        // Private feeds and unknown ids come back null from the server.
        #expect(await store.loadShared(.episode(id: "nope", startAt: nil)) == false)
        await live.stop()
    }
}
