import Foundation
import Testing
@testable import PoddleKit

@Suite struct StatsMappingTests {
    /// `stats:yearInReview` as the backend sends it, minus the fields the app doesn't read.
    private func doc(extra: String = "") throws -> YearInReviewDoc {
        let json = """
        {
          "year": 2026, "availableFrom": "2026-12-01",
          "totals": { "wall": 36000, "content": 54000, "speedSaved": 15000, "smartSaved": 3000, "timeSaved": 18000,
                      "estimatedWall": 0, "sessions": 42, "averageSpeed": 1.5 },
          "episodesCompleted": 12,
          "topShows": [
            { "podcast": { "_id": "p1", "title": "One", "isPrivate": false }, "wall": 7200, "content": 9000, "sessions": 3 },
            { "podcast": { "_id": "p2", "title": "Two", "isPrivate": true }, "wall": 3600, "content": 5400, "sessions": 2 }
          ],
          "topEpisode": null, "longestStreak": { "length": 4 }, "biggestDay": null, "busiestMonth": null,
          "personality": null, "firstEpisode": null, "lastEpisode": null, "newShows": [],
          "heatmap": [], "months": [], "includesEstimated": false, "estimatedBefore": null\(extra)
        }
        """
        return try JSONDecoder().decode(YearInReviewDoc.self, from: Data(json.utf8))
    }

    @Test func usesTheBackendsOtherShowCountAndName() throws {
        let r = StatsMapping.yearInReview(try doc(extra: #", "otherShowCount": 3, "listenerName": "Ada Lovelace""#))
        #expect(r.otherShowCount == 3)
        #expect(r.otherShowsSeconds == 36000 - 7200 - 3600)
        #expect(r.listenerName == "Ada")
    }

    @Test func anOlderBackendWithoutTheNewFieldsStillDecodes() throws {
        let r = StatsMapping.yearInReview(try doc())
        #expect(r.otherShowCount == 0)
        #expect(r.listenerName == "You")
    }

    @Test func listenerNameFallsBackToYou() {
        #expect(StatsMapping.listenerName("Mike Cann") == "Mike")
        #expect(StatsMapping.listenerName("  Mike ") == "Mike")
        #expect(StatsMapping.listenerName(nil) == "You")
        #expect(StatsMapping.listenerName("") == "You")
        #expect(StatsMapping.listenerName("   ") == "You")
        #expect(StatsMapping.listenerName("test@example.com") == "You")
    }

    @Test func otherShowsLine() {
        #expect(Format.otherShows(0) == nil)
        #expect(Format.otherShows(1) == "+ 1 OTHER SHOW")
        #expect(Format.otherShows(79) == "+ 79 OTHER SHOWS")
    }
}
