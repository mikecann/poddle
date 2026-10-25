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

        s.given("{string} keeps the latest {int} episode") { w, a in
            try w.call("setShowSettings", ["email": w.email, "show": a.string(0), "patch": ["keepLatestDownloaded": a.int(1)]])
        }

        s.given("{string} is at the end of Up Next too") { w, a in
            try w.call("queue", ["email": w.email, "episodes": [a.string(0)]])
            try w.eventually("\(a.string(0)) in the app's Up Next", timeout: 20) { try w.upNextOnScreen().last == a.string(0) }
        }

        s.when("they set {string} to keep the latest {int} episode") { w, a in
            let want = a.int(1)
            try w.openShow(a.string(0))
            try w.tap("podcast.settings")
            // The stepper goes All, 1, 2 … 50, and a show starts on the default, All.
            let value = try w.waitFor("showSettings.keepLatest.value", timeout: 10, "the Keep latest stepper")
            try w.reveal(value, "Keep latest")
            let label = want == 1 ? "1 ep" : "\(want) eps"
            for _ in 0..<want where value.label != label { try w.tap("showSettings.keepLatest.more") }
            try w.eventually("Keep latest to show \(label)", timeout: 5) { value.label == label }
            try w.eventually("the server to have it", timeout: 20) {
                let overrides = try w.call("podcast", ["email": w.email, "show": a.string(0)])["overrides"] as? [String: Any]
                return (overrides?["keepLatestDownloaded"] as? NSNumber)?.intValue == want
            }
            try w.tap("showSettings.done")
            try w.goTo(tab: "upNext")
        }
    }
}
