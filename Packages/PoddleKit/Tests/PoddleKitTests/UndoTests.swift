import Foundation
import Testing
@testable import PoddleKit

@MainActor
@Suite struct UndoTests {
    let store = MockStore.makeStore(sync: false)

    var queueIds: [String] { store.queue.map(\.id) }

    @Test func archiveFromUpNextComesBackInTheSamePlace() {
        let before = queueIds
        let id = "ep_conan_mail"
        let point = store.restorePoint([id])
        store.archive(id)
        #expect(!queueIds.contains(id))
        #expect(store.item(id)?.state.archived == true)

        store.restore(point)
        #expect(queueIds == before)
        #expect(store.item(id)?.state.archived == false)
    }

    @Test func removeFromUpNextComesBackInTheSamePlace() {
        let before = queueIds
        for id in ["ep_syntax_910", "ep_mike_tue", "ep_atp_649"] {
            let point = store.restorePoint([id])
            store.removeFromQueue(id)
            #expect(!queueIds.contains(id))
            store.restore(point)
            #expect(queueIds == before)
        }
        #expect(store.snapshot.queue.map(\.orderKey) == store.snapshot.queue.map(\.orderKey).sorted())
    }

    @Test func markPlayedRestoresPositionAndPlace() {
        let id = "ep_hardfork_shop"
        store.savePosition(id, 600)
        let before = queueIds
        let point = store.restorePoint([id])
        store.markPlayed(id)
        #expect(store.item(id)?.state.played == true)
        #expect(store.item(id)?.state.position == 0)

        store.restore(point)
        #expect(store.item(id)?.state.played == false)
        #expect(store.item(id)?.state.playedAt == nil)
        #expect(store.item(id)?.state.position == 600)
        #expect(queueIds == before)
    }

    @Test func markPlayedOnSomethingNotQueuedDoesNotQueueIt() {
        let id = "ep_syntax_911"
        #expect(!store.snapshot.isQueued(id))
        let point = store.restorePoint([id])
        store.markPlayed(id)
        store.restore(point)
        #expect(store.item(id)?.state.played == false)
        #expect(!store.snapshot.isQueued(id))
    }

    @Test func clearQueueRestoresEverything() {
        let before = queueIds
        let point = store.queueRestorePoint()
        store.clearQueue(keeping: MockData.playingEpisodeId)
        #expect(queueIds == [MockData.playingEpisodeId])
        store.restore(point)
        #expect(queueIds == before)
    }

    @Test func unsubscribeRestoresTheShowAndItsQueuedEpisodes() {
        let before = queueIds
        let point = store.restorePoint(podcastId: "pod_syntax")
        store.unsubscribe("pod_syntax")
        #expect(store.podcast("pod_syntax")?.subscribed == false)
        #expect(!queueIds.contains("ep_syntax_910"))

        store.resubscribe("pod_syntax")
        store.restore(point)
        #expect(store.podcast("pod_syntax")?.subscribed == true)
        #expect(queueIds == before)
    }

    @Test func markAllPlayedRestoresEachEpisode() {
        let point = store.restorePoint(podcastId: "pod_syntax")
        let unplayed = store.episodes(of: "pod_syntax").filter { !$0.state.played }.map(\.id)
        store.markAllPlayed("pod_syntax")
        #expect(store.unplayedCount("pod_syntax") == 0)
        store.restore(point)
        #expect(store.episodes(of: "pod_syntax").filter { !$0.state.played }.map(\.id) == unplayed)
    }

    @Test func deleteDownloadWaitsForTheToast() {
        let id = "ep_hardfork_shop"
        #expect(store.download(for: id)?.state == .done)

        store.removeDownloadLater(id)
        #expect(store.download(for: id) == nil)
        #expect(store.downloads[id] == nil)
        #expect(store.item(id)?.isDownloaded == false)

        // Undo: it was never deleted.
        store.cancelDownloadRemoval(id)
        #expect(store.download(for: id)?.state == .done)

        // Expired: now it goes.
        store.removeDownloadLater(id)
        store.commitDownloadRemoval(id)
        #expect(store.pendingDownloadRemovals.isEmpty)
        #expect(store.download(for: id) == nil)
        store.cancelDownloadRemoval(id)
        #expect(store.download(for: id) == nil)
    }

    @Test func customizeToggle() {
        // Syntax follows the defaults: edits change them.
        #expect(!store.customizesPlayback("pod_syntax"))
        store.setPlaybackSpeed(1.8, podcastId: "pod_syntax")
        #expect(store.global.speed == 1.8)
        store.editPlayback("pod_syntax", show: { $0.voiceBoost = false }, global: { $0.voiceBoost = false })
        #expect(store.global.voiceBoost == false)
        #expect(store.settings(for: "pod_syntax").voiceBoost == nil)

        // On: starts from the current values, then edits only touch the show.
        store.setCustomizesPlayback("pod_syntax", true)
        #expect(store.customizesPlayback("pod_syntax"))
        let s = store.settings(for: "pod_syntax")
        #expect(s.speed == 1.8)
        #expect(s.voiceBoost == false)
        #expect(s.smartSpeed == store.global.smartSpeed)
        store.setPlaybackSpeed(2.2, podcastId: "pod_syntax")
        store.editPlayback("pod_syntax", show: { $0.skipIntro = 30 }, global: { $0.skipIntro = 30 })
        #expect(store.global.speed == 1.8)
        #expect(store.global.skipIntro == 0)
        #expect(store.resolved("pod_syntax").speed == Resolved(2.2, isOverride: true))
        #expect(store.resolved("pod_syntax").skipIntro.value == 30)

        // Off: back to the defaults, other per-show settings untouched.
        store.setCustomizesPlayback("pod_syntax", false)
        #expect(!store.customizesPlayback("pod_syntax"))
        #expect(store.resolved("pod_syntax").speed == Resolved(1.8, isOverride: false))
        #expect(store.settings(for: "pod_syntax").autoAdd == .upNextTop)
    }
}

@Suite struct ShowNotesTests {
    @Test func timestamps() {
        #expect(ShowNotes.seconds(fromTimestamp: "12:34") == 754)
        #expect(ShowNotes.seconds(fromTimestamp: "1:02:03") == 3723)
        #expect(ShowNotes.seconds(fromTimestamp: "00:00") == 0)
        #expect(ShowNotes.seconds(fromTimestamp: "12:75") == nil)
        #expect(ShowNotes.seconds(fromTimestamp: "abc") == nil)
        #expect(ShowNotes.seekSeconds(URL(string: "poddle-seek://754")!) == 754)
        #expect(ShowNotes.seekSeconds(URL(string: "https://example.com")!) == nil)
    }

    @Test func htmlBlocks() {
        let blocks = ShowNotes.blocks(html: """
            <p>Hello <strong>world</strong> &amp; friends.<br/>Second line</p>
            <ul><li>(04:12) Why RL</li><li>See <a href="https://x.com/a">this</a></li></ul>
            <script>nope()</script><h3>Links</h3><p>https://example.com/page.</p>
            """)
        #expect(blocks.count == 5)
        guard case let .paragraph(first) = blocks[0] else { Issue.record("not a paragraph"); return }
        #expect(String(first.characters) == "Hello world & friends.\nSecond line")
        let bold = first.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(first[$0.range].characters) } == "world")

        guard case let .bullet(stamp) = blocks[1] else { Issue.record("not a bullet"); return }
        #expect(String(stamp.characters) == "(04:12) Why RL")
        #expect(stamp.runs.compactMap(\.link).first == URL(string: "poddle-seek://252"))

        guard case let .bullet(link) = blocks[2] else { Issue.record("not a bullet"); return }
        #expect(link.runs.compactMap(\.link).first == URL(string: "https://x.com/a"))

        guard case let .heading(h) = blocks[3] else { Issue.record("not a heading"); return }
        #expect(String(h.characters) == "Links")

        guard case let .paragraph(bare) = blocks[4] else { Issue.record("not a paragraph"); return }
        #expect(String(bare.characters) == "https://example.com/page.")
        #expect(bare.runs.compactMap(\.link).first == URL(string: "https://example.com/page"))
    }

    @Test func plainText() {
        let blocks = ShowNotes.blocks(html: "First para\nline two\n\nSecond at 1:05:00")
        #expect(blocks.count == 2)
        guard case let .paragraph(second) = blocks[1] else { Issue.record("not a paragraph"); return }
        #expect(second.runs.compactMap(\.link).first == URL(string: "poddle-seek://3900"))
    }
}
