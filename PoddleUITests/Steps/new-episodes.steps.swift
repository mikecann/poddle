import XCTest

/// features/app/new-episodes.feature
final class NewEpisodesSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("{string} publishes {string}") { w, a in
            // Into the fixture feed, then fetched straight away (testing:refreshFeed).
            try w.call("publish", ["show": a.string(0), "title": a.string(1)])
        }

        s.when("they set new episodes from {string} to {string}") { w, a in
            try w.openShow(a.string(0))
            try w.tap("podcast.settings")
            let choice = w.app.buttons.matching(NSPredicate(format: "identifier == 'showSettings.newEpisodes' AND label == %@", a.string(1))).firstMatch
            guard choice.waitForExistence(timeout: 10) else { throw World.Failure("No \"\(a.string(1))\" choice") }
            try w.reveal(choice, a.string(1))
            choice.tap()
            let rule = ["Up Next top": "upNextTop", "Don't add": "none", "Up Next bottom": "upNextBottom"][a.string(1)]!
            try w.eventually("the server to have the new rule", timeout: 20) {
                let resolved = try w.call("podcast", ["email": w.email, "show": a.string(0)])["resolved"] as? [String: Any]
                return resolved?["newEpisodes"] as? String == rule
            }
            try w.tap("showSettings.done")
            try w.goTo(tab: "upNext")
        }
    }
}
