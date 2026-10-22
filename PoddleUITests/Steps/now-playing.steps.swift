import XCTest

/// features/app/now-playing.feature
final class NowPlayingSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("they swipe right on Now Playing") { w, _ in try swipePages(w, right: true) }
        s.when("they swipe left on Now Playing") { w, _ in try swipePages(w, right: false) }

        s.then("Now Playing shows the show notes with chapters {string}, {string} and {string}") { w, a in
            try w.waitForText("Show notes")
            for (i, title) in a.values.enumerated() {
                let chapter = try w.waitFor("notes.chapter.\(i)", timeout: 15, "chapter \(i + 1)")
                XCTAssertTrue(chapter.label.contains(title), "Chapter \(i + 1) is \"\(chapter.label)\"")
            }
        }

        s.when("they tap the timestamp {string} in the show notes") { w, a in
            let link = w.app.links[a.string(0)].firstMatch
            guard link.waitForExistence(timeout: 10) else { throw World.Failure("No \(a.string(0)) link in the notes") }
            if !link.isHittable { w.app.swipeUp() }
            link.tap()
        }

        s.when("they go back to the player page") { w, _ in
            try w.tap("nowPlaying.page.player")
            try w.waitFor("nowPlaying.scrubber")
        }

        s.then("Now Playing shows the playback settings for {string}") { w, a in
            try w.waitForText("Playback settings")
            let toggle = try w.waitFor("playbackSettings.customize")
            XCTAssertEqual(toggle.label, "Customize for \(a.string(0))")
        }

        s.when("they drag the artwork left, right and up") { w, _ in
            let art = try w.waitFor("nowPlaying.artwork")
            let centre = art.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            for offset in [CGVector(dx: -120, dy: 0), CGVector(dx: 120, dy: 0), CGVector(dx: 0, dy: -150)] {
                // Back to the player page each time: a sideways drag may turn the page, which is fine.
                if !w.element("nowPlaying.artwork").isHittable { try w.tap("nowPlaying.page.player") }
                centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(offset), withVelocity: .default, thenHoldForDuration: 0.1)
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
        }

        s.then("{string} is still what's playing") { w, a in
            try w.closeNowPlaying()
            let mini = try w.waitFor("miniPlayer")
            XCTAssertTrue(mini.staticTexts[a.string(0)].exists, "The mini player moved on to something else")
        }
    }

    @MainActor static func swipePages(_ w: World, right: Bool) throws {
        // Across the artwork: it has no drag gestures of its own, so sideways swipes turn the page.
        let art = try w.waitFor("nowPlaying.artwork")
        if right { art.swipeRight() } else { art.swipeLeft() }
    }
}
