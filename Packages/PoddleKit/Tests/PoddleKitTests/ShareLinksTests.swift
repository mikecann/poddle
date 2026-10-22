import Foundation
import Testing
@testable import PoddleKit

struct ShareLinksTests {
    let links = ShareLinks(base: URL(string: "https://poddle.mikecann.app")!)

    @Test func makesEpisodeAndShowLinks() {
        #expect(links.episode("jx73abc").absoluteString == "https://poddle.mikecann.app/e/jx73abc")
        #expect(links.episode("jx73abc", at: 754.9).absoluteString == "https://poddle.mikecann.app/e/jx73abc?t=754")
        #expect(links.episode("jx73abc", at: 0).absoluteString == "https://poddle.mikecann.app/e/jx73abc")
        #expect(links.show("m17b").absoluteString == "https://poddle.mikecann.app/s/m17b")
        let dev = ShareLinks(base: URL(string: "https://striped-turtle-260.ap-southeast-2.convex.site")!)
        #expect(dev.show("m17b").absoluteString == "https://striped-turtle-260.ap-southeast-2.convex.site/s/m17b")
    }

    @Test func readsTheLinksBack() {
        #expect(ShareLinks.parse(links.episode("jx73abc", at: 90)) == .episode(id: "jx73abc", startAt: 90))
        #expect(ShareLinks.parse(links.show("m17b")) == .show(id: "m17b"))
        #expect(ShareLinks.parse(URL(string: "poddle://e/jx73abc?t=12:34")!) == .episode(id: "jx73abc", startAt: 754))
        #expect(ShareLinks.parse(URL(string: "poddle://s/m17b")!) == .show(id: "m17b"))
        #expect(ShareLinks.parse(URL(string: "https://poddle.mikecann.app/e/jx73abc/")!) == .episode(id: "jx73abc", startAt: nil))
        #expect(ShareLinks.parse(URL(string: "https://poddle.mikecann.app/e/jx73abc?t=1h2m3s")!) == .episode(id: "jx73abc", startAt: 3723))
        #expect(ShareLinks.parse(URL(string: "https://poddle.mikecann.app/e/jx73abc?t=soon")!) == .episode(id: "jx73abc", startAt: nil))
    }

    @Test func ignoresEverythingElse() {
        for s in ["poddle://signed-in?convexAuthCode=x", "https://poddle.mikecann.app/me", "https://poddle.mikecann.app/",
                  "https://poddle.mikecann.app/e/", "https://poddle.mikecann.app/e/a/b", "https://poddle.mikecann.app/e/a%2Fb",
                  "ftp://poddle.mikecann.app/e/abc"] {
            #expect(ShareLinks.parse(URL(string: s)!) == nil, "\(s)")
        }
    }

    @Test func privateShowsAreNotShared() {
        var podcast = Podcast(id: "p", feedURL: "https://x.test/feed?auth=1", isPrivate: true, title: "Secret", author: "", artworkURL: nil, subscribed: true)
        #expect(!ShareLinks.canShare(podcast))
        podcast.isPrivate = false
        #expect(ShareLinks.canShare(podcast))
    }
}
