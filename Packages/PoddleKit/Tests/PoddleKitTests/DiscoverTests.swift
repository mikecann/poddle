import Foundation
import Testing
@testable import PoddleKit

// One episode without following its show (decisions.md, 27 Oct 2026).

@MainActor
@Suite struct UnfollowedShowTests {
    @Test func downloadingFromAShowYouDontFollowAlsoQueuesIt() {
        let store = MockStore.makeStore(sync: false)
        store.unsubscribe("pod_hardfork")
        #expect(!store.queue.contains { $0.id == "ep_hardfork_kids" })
        store.download("ep_hardfork_kids")
        #expect(store.queue.last?.id == "ep_hardfork_kids")
        // Already there: it isn't moved.
        store.queueLast("ep_syntax_911")
        store.download("ep_hardfork_kids")
        #expect(store.queue.last?.id == "ep_syntax_911")
    }

    @Test func downloadingFromAFollowedShowLeavesUpNextAlone() {
        let store = MockStore.makeStore(sync: false)
        let before = store.snapshot.queue
        store.download("ep_syntax_911")
        #expect(store.snapshot.queue == before)
    }

    @Test func searchFindsEpisodesByNameAndOpensOne() async throws {
        let seed = MockData.snapshot()
        let store = PoddleStore(dataSource: MockStore(snapshot: seed, latency: 0), seed: seed)
        let r = try await store.search("smart glasses")
        #expect(r.episodes.map(\.title) == ["We tried the new smart glasses"])
        #expect(r.episodes.first?.showTitle == "Hard Fork")
        let opened = await store.open(.episode(try #require(r.episodes.first)))
        #expect(opened == OpenedFeed(podcastId: "pod_hardfork", episodeId: "ep_hardfork_glasses"))
    }
}

@Suite struct OpenFeedLiveTests {
    @Test func searchesEpisodesAndOpensOneWithoutFollowing() async throws {
        let fake = FakeTransport()
        fake.respond = { name, args in
            switch name {
            case "directory:search": Data("[]".utf8)
            case "directory:searchEpisodes":
                Data(#"[{"appleId":1000700000001,"title":"A deep dive on AI model distillation attacks","showTitle":"Risky Business Features","author":"Patrick Gray","feedUrl":"https://risky.biz/feeds/risky-business-features/","guid":"https://risky.biz/RBFEATURES17/","audioUrl":"https://media3.risky.biz/RBFEATURES17.mp3","pubDate":1792620000000,"duration":2712}]"#.utf8)
            case "feedActions:openFeed": Data(#"{"podcastId":"p9","episodeId":"e9"}"#.utf8)
            case "episodes:get" where args["episodeId"]?.string == "e9":
                Data(#"{"row":{"episode":{"_id":"e9","podcastId":"p9","title":"A deep dive on AI model distillation attacks","duration":2712,"transcripts":[],"isGhost":false,"firstSeenAt":1,"updatedAt":1},"state":null,"podcast":{"_id":"p9","title":"Risky Business Features","isPrivate":false}},"inQueue":false}"#.utf8)
            case "sync:changes": Data(#"{"page":[],"isDone":true,"continueCursor":"","maxUpdatedAt":null}"#.utf8)
            default: Data("null".utf8)
            }
        }
        let disk = LiveDisk(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { disk.erase() }
        let live = LiveStore(
            deploymentURL: URL(string: "https://example.convex.cloud")!, deviceId: "device-1", userId: "user-mike",
            auth: nil, transport: { _ in fake }, disk: { _, _ in disk }, timing: .fast
        )
        let store = await MainActor.run { PoddleStore(dataSource: live, deviceId: "device-1") }

        let response = try await store.search("distillation attacks")
        let episode = try #require(response.episodes.first)
        #expect(episode.showTitle == "Risky Business Features")
        #expect(episode.duration == 2712)

        let opened = await store.open(.episode(episode))
        #expect(opened == OpenedFeed(podcastId: "p9", episodeId: "e9"))
        let call = try #require(fake.actions.first { $0.name == "feedActions:openFeed" })
        #expect(call.args["feedUrl"]?.string == "https://risky.biz/feeds/risky-business-features/")
        #expect(call.args["episodeGuid"]?.string == "https://risky.biz/RBFEATURES17/")
        #expect(call.args["enclosureUrl"]?.string == "https://media3.risky.biz/RBFEATURES17.mp3")
        await MainActor.run {
            #expect(store.item("e9")?.episode.title == "A deep dive on AI model distillation attacks")
            #expect(store.podcast("p9")?.subscribed == false)
        }
        // Opening isn't following: no subscribe went out.
        #expect(!fake.mutations.contains { $0.name == "podcasts:subscribe" })
    }

    @Test func aFailingEpisodeSearchStillShowsShows() async throws {
        let fake = FakeTransport()
        fake.respond = { name, _ in
            switch name {
            case "directory:search": Data(#"[{"appleId":1,"title":"Risky Business","feedUrl":"https://risky.biz/feeds/risky-business/","subscribed":false}]"#.utf8)
            case "sync:changes": Data(#"{"page":[],"isDone":true,"continueCursor":"","maxUpdatedAt":null}"#.utf8)
            default: Data("not json".utf8)
            }
        }
        let disk = LiveDisk(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { disk.erase() }
        let live = LiveStore(
            deploymentURL: URL(string: "https://example.convex.cloud")!, deviceId: "device-1", userId: "user-mike",
            auth: nil, transport: { _ in fake }, disk: { _, _ in disk }, timing: .fast
        )
        let store = await MainActor.run { PoddleStore(dataSource: live, deviceId: "device-1") }
        let response = try await store.search("risky")
        #expect(response.results.map(\.title) == ["Risky Business"])
        #expect(response.episodes.isEmpty)
    }
}
