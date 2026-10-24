import Foundation
import Testing
@testable import PoddleKit

/// "Keep latest" (decisions.md, 25 Oct 2026): All or 1 to 50, the same number for Up Next and downloads.
@Suite struct KeepLatestTests {
    @Test func stepperGoesFromAllToOneAndUpToFifty() {
        #expect(GlobalSettings.defaults.keepLatest == .all)
        #expect(KeepLatest.all.stepped(1) == .latest(1))
        #expect(KeepLatest.latest(1).stepped(-1) == .all)
        #expect(KeepLatest.all.stepped(-1) == .all)
        #expect(KeepLatest.latest(50).stepped(1) == .latest(50))
        #expect(KeepLatest.latest(3).stepped(1) == .latest(4))
        // Off the list (a script, say): steps from the nearest end.
        #expect(KeepLatest.latest(80).stepped(-1) == .latest(49))
        #expect(KeepLatest.all.label == "All")
        #expect(KeepLatest.latest(1).label == "1 ep")
        #expect(KeepLatest.latest(3).label == "3 eps")
    }

    @Test func showInheritsTheDefaultUnlessItHasItsOwn() {
        let g = GlobalSettings(keepLatest: .latest(5))
        #expect(ResolvedSettings(global: g, override: nil).keepLatest == Resolved(.latest(5), isOverride: false))
        let own = PodcastSettings(podcastId: "p", keepLatest: .all)
        #expect(ResolvedSettings(global: g, override: own).keepLatest == Resolved(.all, isOverride: true))
        #expect(own.hasOverrides)
    }

    @Test func readsNumbersAndAllFromTheAPI() {
        #expect(SettingsMapping.podcast("p", ["keepLatestDownloaded": .number(1)]).keepLatest == .latest(1))
        #expect(SettingsMapping.podcast("p", ["keepLatestDownloaded": .string("all")]).keepLatest == .all)
        #expect(SettingsMapping.podcast("p", [:]).keepLatest == nil)
        #expect(SettingsMapping.global(["keepLatest": .number(4)]).keepLatest == .latest(4))
        #expect(SettingsMapping.global(["keepLatest": .string("all")]).keepLatest == .all)
    }

    @Test func ignoresTheGlobalRowsOldDownloadCount() {
        // An old app's Settings stepper left keepLatestDownloaded on the global row. It isn't the default for shows.
        let g = SettingsMapping.global(["keepLatestDownloaded": .number(3)])
        #expect(g.keepLatest == .all)
    }

    @Test func writesTheShowFieldAndTheNewDefault() {
        let show = SettingsMapping.fields(PodcastSettings(podcastId: "p", keepLatest: .all))
        #expect(show["keepLatestDownloaded"] == .string("all"))
        #expect(SettingsMapping.fields(PodcastSettings(podcastId: "p", keepLatest: .latest(2)))["keepLatestDownloaded"] == .number(2))
        #expect(SettingsMapping.fields(PodcastSettings(podcastId: "p"))["keepLatestDownloaded"] == .null)

        var g = GlobalSettings.defaults
        let before = SettingsMapping.fields(g)
        #expect(before["keepLatest"] == .string("all"))
        #expect(before["keepLatestDownloaded"] == nil)
        g.keepLatest = .latest(1)
        #expect(SettingsMapping.patch(from: before, to: SettingsMapping.fields(g)) == ["keepLatest": .number(1)])
    }

    @Test func oldCachesWithAPlainNumberStillDecode() throws {
        struct Box: Codable, Equatable { var keepLatest: KeepLatest?; var global: KeepLatest }
        let old = Data(#"{"keepLatest": 3, "global": 3}"#.utf8)
        #expect(try JSONDecoder().decode(Box.self, from: old) == Box(keepLatest: .latest(3), global: .latest(3)))
        let round = try JSONDecoder().decode(Box.self, from: JSONEncoder().encode(Box(keepLatest: .all, global: .latest(2))))
        #expect(round == Box(keepLatest: .all, global: .latest(2)))
        let cached = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(GlobalSettings.defaults))
        #expect(cached == .defaults)
    }
}
