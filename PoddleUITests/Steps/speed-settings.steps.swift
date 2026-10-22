import XCTest

/// features/app/speed-settings.feature
final class SpeedSettingsSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.given("they've opened the playback settings in Now Playing") { w, _ in try openSettings(w) }
        s.when("they open the playback settings") { w, _ in try openSettings(w) }

        s.when("they choose {float}× speed") { w, a in try choose(w, a.double(0)) }

        s.when("they turn on {string}") { w, a in try setToggle(w, a.string(0), on: true) }
        s.when("they turn off {string}") { w, a in try setToggle(w, a.string(0), on: false) }

        s.then("the default speed is {float}×") { w, a in try defaultSpeed(w, a.double(0)) }

        s.then("{string} has no speed of its own") { w, a in
            try w.eventually("\(a.string(0)) to have no speed override", timeout: 20) {
                let overrides = try w.call("podcast", ["email": w.email, "show": a.string(0)])["overrides"] as? [String: Any] ?? [:]
                return overrides["playbackSpeed"] == nil
            }
        }
        s.then("{string} has its own speed of {float}×") { w, a in
            try w.eventually("\(a.string(0)) to play at \(a.double(1))×", timeout: 20) {
                let overrides = try w.call("podcast", ["email": w.email, "show": a.string(0)])["overrides"] as? [String: Any] ?? [:]
                return (overrides["playbackSpeed"] as? Double) == a.double(1)
            }
        }

        s.when("they play {string}") { w, a in
            try w.closeNowPlaying()
            try w.goTo(tab: "upNext")
            try w.rowTitle(a.string(0)).tap()
            try w.eventually("the mini player to show \(a.string(0))") { w.element("miniPlayer").staticTexts[a.string(0)].exists }
        }

        s.then("Now Playing's speed is {float}×") { w, a in try nowPlayingSpeed(w, a.double(0)) }
    }

    @MainActor static func openSettings(_ w: World) throws {
        try w.openNowPlaying()
        try w.tap("nowPlaying.speed")
        try w.waitFor("playbackSettings.customize")
    }

    @MainActor static func choose(_ w: World, _ speed: Double) throws {
        // The preset's identifier is its label: "1.4", "1.25", "2.0".
        let hundredths = Int((speed * 100).rounded())
        let label = hundredths % 10 == 0 ? String(format: "%.1f", speed) : String(format: "%.2f", speed)
        try w.tap("playbackSettings.preset.\(label)")
    }

    @MainActor static func setToggle(_ w: World, _ label: String, on: Bool) throws {
        let toggle = try w.waitFor("playbackSettings.customize")
        XCTAssertEqual(toggle.label, label)
        let isOn = { (toggle.value as? String) == "1" }
        // A loaded machine can swallow the tap: try again, but only once the first has had time to land.
        for _ in 0..<3 where isOn() != on {
            toggle.tap()
            try? w.eventually("\(label) to be \(on ? "on" : "off")", timeout: 8) { isOn() == on }
        }
        try w.eventually("\(label) to be \(on ? "on" : "off")", timeout: 5) { isOn() == on }
    }

    @MainActor static func defaultSpeed(_ w: World, _ speed: Double) throws {
        try w.eventually("the default speed to be \(speed)×", timeout: 20) {
            (try w.call("globalSettings", ["email": w.email])["playbackSpeed"] as? Double) == speed
        }
    }

    @MainActor static func nowPlayingSpeed(_ w: World, _ speed: Double) throws {
        try w.openNowPlaying()
        if !w.element("nowPlaying.speed").exists { try w.tap("nowPlaying.page.player") }
        let label = try w.waitFor("nowPlaying.speed")
        let want = "Speed \(String(format: "%.1f", speed))×"
        try w.eventually("the speed to read \(want)") { label.label.hasPrefix(want) }
    }
}
