import XCTest

/// features/app/discover.feature
final class DiscoverSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("they open the episode {string} from the results") { w, a in
            // An episode row reads as one button: its title, then the show, date and length.
            let row = w.app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'discover.episode.' AND label BEGINSWITH %@", a.string(0))).firstMatch
            guard row.waitForExistence(timeout: 20) else { throw World.Failure("\(a.string(0)) isn't in the episode results") }
            try w.reveal(row, a.string(0))
            row.tap()
            try w.waitFor("episode.play", timeout: 20, "the page for \(a.string(0))")
        }

        s.when("they download it from its page") { w, _ in
            // Before: the page's own icon says it isn't downloaded (and proves the page check below can see it).
            try w.eventually("the page to say Not downloaded", timeout: 10) {
                try episodePage(w).descendants(matching: .any).matching(NSPredicate(format: "label == 'Not downloaded'")).firstMatch.exists
            }
            try w.tap("episode.download")
            try w.waitGone("episode.download", timeout: 10)
        }

        // On the episode page: a finished download shows no icon, so it's done once nothing there
        // says otherwise (the same rule as Up Next's rows). Only the page itself counts: the hidden
        // Up Next tab can keep a stale row in the accessibility tree that never updates.
        s.then("it finishes downloading") { w, _ in
            let page = try episodePage(w)
            let notYet = NSPredicate(format: "label IN %@ OR label BEGINSWITH 'Downloading'",
                                     ["Not downloaded", "Waiting for Wi-Fi", "Download failed"])
            try w.eventually("the episode to be downloaded", timeout: 30) {
                !page.descendants(matching: .any).matching(notYet).firstMatch.exists
            }
        }

        s.then("they still don't follow {string}") { w, a in
            // The show reaches their library (unfollowed) once the queued episode has synced.
            try w.eventually("the server to know the show, unfollowed", timeout: 20) {
                (try? w.call("podcast", ["email": w.email, "show": a.string(0)])["subscribed"] as? Bool) == false
            }
        }

        s.when("they open {string} from the results") { w, a in
            let card = w.app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'discover.result.'"))
                .containing(NSPredicate(format: "label == %@", a.string(0))).firstMatch
            guard card.waitForExistence(timeout: 20) else { throw World.Failure("\(a.string(0)) isn't in the results") }
            let title = card.staticTexts[a.string(0)].firstMatch
            try w.reveal(title, a.string(0))
            title.tap()
            try w.waitFor("podcast.list", timeout: 20, "the page for \(a.string(0))")
        }

        s.then("its page lists {string}, {string} and {string}") { w, a in
            let list = try w.waitFor("podcast.list", timeout: 10)
            for title in a.values {
                try w.eventually("\(title) on the page", timeout: 20) { list.staticTexts[title].exists }
            }
        }

        s.then("its page offers to follow it") { w, _ in
            XCTAssertEqual(try w.waitFor("podcast.follow").label, "Follow")
        }
    }

    /// The episode page's scroll view, by type, so a child that inherits the identifier can't stand in for it.
    @MainActor static func episodePage(_ w: World) throws -> XCUIElement {
        let page = w.app.scrollViews.matching(identifier: "episode.page").firstMatch
        guard page.waitForExistence(timeout: 10) else { throw World.Failure("the episode page never appeared") }
        return page
    }
}
