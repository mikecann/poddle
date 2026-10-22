import XCTest

/// features/app/stats.feature
final class StatsSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("they listen for a few seconds") { w, _ in
            try w.tap("miniPlayer.playPause")
            try w.eventually("it to play", timeout: 20) { w.isPlaying() }
            RunLoop.current.run(until: Date().addingTimeInterval(8))
            // Pausing closes the listening session and sends it.
            try w.tap("miniPlayer.playPause")
            try w.eventually("it to pause") { !w.isPlaying() }
        }

        s.then("Stats lists {string} in their top shows") { w, a in
            try w.eventually("the server to count the listening", timeout: 30) {
                let top = try w.call("stats", ["email": w.email])["topShows"] as? [[String: Any]] ?? []
                return top.contains { ($0["podcast"] as? [String: Any])?["title"] as? String == a.string(0) }
            }
            try w.goTo(tab: "stats")
            try w.waitForText("Top shows", timeout: 20)
            try w.waitForText(a.string(0), timeout: 20)
        }
    }
}
