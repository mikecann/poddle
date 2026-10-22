import XCTest

/// features/app/playback.feature
final class PlaybackSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.given("they'd stopped {string} at {int} seconds") { w, a in
            try w.call("setPosition", ["email": w.email, "title": a.string(0), "position": a.int(1)])
        }

        s.when("they tap {string} in Up Next") { w, a in try w.rowTitle(a.string(0)).tap() }

        s.when("they press play in the mini player") { w, _ in try w.tap("miniPlayer.playPause") }

        s.then("the position moves on") { w, _ in
            let start = try w.position()
            try w.eventually("the position to move on from \(start) s", timeout: 15) { try w.position() >= start + 2 }
            w.memo["position"] = String(try w.position())
        }

        s.when("they pause") { w, _ in
            try w.tap("nowPlaying.playPause")
            try w.eventually("it to pause") { !w.isPlaying() }
        }

        s.then("the position stays put") { w, _ in
            let start = try w.position()
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            XCTAssertEqual(try w.position(), start, accuracy: 0.5, "It kept going while paused")
        }

        s.when("they resume") { w, _ in
            try w.tap("nowPlaying.playPause")
            try w.eventually("it to play") { w.isPlaying() }
        }

        s.when("they skip forward") { w, _ in
            w.memo["before"] = String(try w.position())
            try w.tap("nowPlaying.skipForward")
        }

        s.when("they skip back") { w, _ in
            w.memo["before"] = String(try w.position())
            try w.tap("nowPlaying.skipBack")
        }

        s.then("the position jumps about {int} seconds forward") { w, a in try jumped(w, by: Double(a.int(0))) }
        s.then("the position jumps about {int} seconds back") { w, a in try jumped(w, by: -Double(a.int(0))) }
    }

    /// Skips happen while paused, so the jump is exact; allow a little for rounding.
    @MainActor static func jumped(_ w: World, by want: Double) throws {
        let before = Double(w.memo["before"]!)!
        var last = before
        do {
            try w.eventually("a jump of about \(Int(want)) s from \(before) s", timeout: 8) {
                last = try w.position()
                let d = last - before
                return d >= want - 2 && d <= want + 4
            }
        } catch { throw World.Failure("\(error) (it's at \(last) s)") }
    }
}
