import XCTest

/// features/app/share-links.feature
final class ShareLinksSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.given("someone else follows {string}") { w, a in
            let friend = w.config.users["friend"]!
            try w.call("signUp", ["email": friend])
            let followed = try w.call("follow", ["email": friend, "show": a.string(0)])
            for episode in followed["episodes"] as? [[String: Any]] ?? [] {
                w.memo["episode:\(episode["title"] as! String)"] = episode["id"] as? String
            }
        }

        s.when("the listener opens the share link for {string} at {int} seconds") { w, a in
            try openLink(w, "\(w.config.siteUrl)/e/\(try w.episodeId(a.string(0)))?t=\(a.int(1))")
        }

        s.when("the listener opens a share link to an episode that doesn't exist") { w, _ in
            try openLink(w, "\(w.config.siteUrl)/e/k17nosuchepisode0000000000000000")
        }

        s.then("the episode page for {string} opens") { w, a in
            try w.waitFor("episode.close", timeout: 20, "the episode page")
            try w.waitForText(a.string(0))
        }

        s.then("it offers {string}") { w, a in
            let play = try w.waitFor("episode.play")
            try w.eventually("the button to say \(a.string(0))") { play.label.contains(a.string(0)) }
        }

        s.then("its show notes list {string} and {string} on their own lines") { w, a in
            let notes = w.app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", a.string(0))).firstMatch
            guard notes.waitForExistence(timeout: 10) else { throw World.Failure("No show notes with \(a.string(0))") }
            let both = w.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "• \(a.string(0))\n• \(a.string(1))")).firstMatch
            XCTAssertTrue(both.exists, "The notes read \"\(notes.label)\"")
        }

        s.when("they play from there") { w, _ in try w.tap("episode.play") }

        s.then("they're told the link couldn't be opened") { w, _ in
            let alert = w.app.alerts["Couldn't open that link"]
            // Up to a minute: a failed fetch mid sign-in is retried before anything is called missing.
            guard alert.waitForExistence(timeout: 60) else { throw World.Failure("No \"Couldn't open that link\" alert") }
        }
    }

    /// A fresh install, signed in, opening the link as if it had been tapped (`-PoddleOpenURL`).
    @MainActor static func openLink(_ w: World, _ url: String) throws {
        w.launch(signedInAs: w.email, extra: ["-PoddleOpenURL", url])
        try w.waitFor("tab.upNext", timeout: 30, "the tabs after signing in")
    }
}
