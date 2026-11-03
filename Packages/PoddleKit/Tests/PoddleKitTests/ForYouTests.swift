import Foundation
import Testing
@testable import PoddleKit

struct ForYouTests {
    @Test func decodesWhatTheServerSends() throws {
        let json = #"""
        {"hasKey":true,"keyEnding":"abcd","refreshing":false,"refreshedAt":1000,
         "picks":[{"id":"e1","title":"New","showTitle":"Hard Fork","feedUrl":"https://f/x.xml","appleId":12,"pubDate":2000,"duration":3000,"reason":"Because","chartPosition":14}]}
        """#
        let model = try JSONDecoder().decode(ForYouDoc.self, from: Data(json.utf8)).model
        #expect(model.hasKey)
        #expect(model.keyEnding == "abcd")
        #expect(model.picks.first?.feedURL == "https://f/x.xml")
        #expect(model.picks.first?.chartPosition == 14)
    }

    @Test func aPickOpensByTitleAndDateWithoutFollowing() {
        let pick = SuggestedEpisode(id: "e1", title: "New", showTitle: "Hard Fork", feedURL: "https://f/x.xml", pubDate: 2000, duration: 3000, reason: "Because")
        guard case let .episode(episode) = pick.target else { Issue.record("not an episode"); return }
        #expect(episode.title == "New")
        #expect(episode.pubDate == 2000)
        #expect(episode.feedURL == "https://f/x.xml")
    }
}
