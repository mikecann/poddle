import XCTest

/// Steps every app feature can use: who follows what, opening the app, and where you are.
final class CommonSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        func follow(_ w: World, _ show: String, upNext: [String] = []) throws {
            try w.call("signUp", ["email": w.email])
            try w.call("follow", ["email": w.email, "show": show, "upNext": upNext])
        }

        s.given("the listener follows {string}") { w, a in try follow(w, a.string(0)) }
        s.given("the listener follows {string} with {string} in Up Next") { w, a in
            try follow(w, a.string(0), upNext: [a.string(1)])
        }
        s.given("the listener follows {string} with {string} and {string} in Up Next") { w, a in
            try follow(w, a.string(0), upNext: [a.string(1), a.string(2)])
        }
        s.given("the listener follows {string} with {string}, {string} and {string} in Up Next") { w, a in
            try follow(w, a.string(0), upNext: [a.string(1), a.string(2), a.string(3)])
        }
        s.given("the listener has an account") { w, _ in try w.call("signUp", ["email": w.email]) }
        s.given("they also follow {string} with {string} at the end of Up Next") { w, a in
            try follow(w, a.string(0), upNext: [a.string(1)])
        }

        // MARK: What the server has

        s.then("Up Next on the server is {string}") { w, a in try serverUpNext(w, a.values) }
        s.then("Up Next on the server is {string} and {string}") { w, a in try serverUpNext(w, a.values) }
        s.then("Up Next on the server is {string}, {string} and {string}") { w, a in try serverUpNext(w, a.values) }
        s.then("Up Next on the server is {string}, {string}, {string} and {string}") { w, a in try serverUpNext(w, a.values) }
        s.then("{string} is played") { w, a in try episodeState(w, a.string(0), "played", true) }
        s.then("{string} isn't played") { w, a in try episodeState(w, a.string(0), "played", false) }
        s.then("{string} isn't archived") { w, a in try episodeState(w, a.string(0), "archived", false) }
        s.then("{string} is played within {int} seconds") { w, a in
            try episodeState(w, a.string(0), "played", true, timeout: Double(a.int(1)))
        }

        // MARK: Library and show pages

        s.then("{string} is in their Library") { w, a in
            try w.goTo(tab: "library")
            try w.eventually("\(a.string(0)) in the server's library", timeout: 20) {
                (try w.call("library", ["email": w.email])["shows"] as? [String] ?? []).contains(a.string(0))
            }
            try w.waitFor("library.show.\(try w.podcastId(a.string(0)))", timeout: 20, "\(a.string(0)) in the Library")
        }
        s.then("the page for {string} lists {string}") { w, a in try showPageLists(w, a.string(0), [a.string(1)]) }
        s.then("the page for {string} lists {string}, {string} and {string}") { w, a in
            try showPageLists(w, a.string(0), Array(a.values.dropFirst()))
        }

        // MARK: Undo

        s.then("the Undo toast says {string}") { w, a in
            let toast = try w.waitFor("undoToast", timeout: 10, "the Undo toast")
            XCTAssertTrue(toast.label.hasPrefix(a.string(0)), "The toast says \"\(toast.label)\"")
        }
        s.when("they press Undo") { w, _ in try w.pressUndo() }

        // MARK: Playing

        s.given("they've opened Now Playing") { w, _ in try w.openNowPlaying() }
        s.when("they open Now Playing") { w, _ in try w.openNowPlaying() }
        s.then("it's playing") { w, _ in try w.eventually("it to be playing", timeout: 20) { w.isPlaying() } }
        s.then("the position is about {int} seconds") { w, a in
            let want = Double(a.int(0))
            var last = 0.0
            do {
                try w.eventually("the position to be about \(Int(want)) s", timeout: 10) {
                    last = try w.position()
                    return abs(last - want) <= 4
                }
            } catch { throw World.Failure("\(error) (it's \(last) s)") }
        }
        s.then("Now Playing shows {string}") { w, a in
            try w.waitFor("nowPlaying.close", timeout: 15, "Now Playing")
            try w.waitForText(a.string(0))
        }

        s.given("they've opened Poddle signed in") { w, _ in try openSignedIn(w) }
        s.when("they open Poddle and sign in") { w, _ in try openSignedIn(w) }

        s.then("they're on Up Next") { w, _ in
            let tab = try w.waitFor("tab.upNext")
            try w.eventually("the Up Next tab to be selected") { tab.isSelected }
            try w.waitFor("upNext.list")
        }

        s.then("they're still signed out") { w, _ in
            try w.waitFor("signIn.apple", timeout: 20, "the sign-in screen")
            XCTAssertFalse(w.element("tab.upNext").exists, "the tabs are still there")
        }

        s.then("the mini player shows {string}") { w, a in
            let mini = try w.waitFor("miniPlayer", timeout: 20)
            try w.eventually("the mini player to show \(a.string(0))") { mini.staticTexts[a.string(0)].exists }
        }

        s.then("Up Next lists {string}") { w, a in
            try w.goTo(tab: "upNext")
            try w.eventually("Up Next to list \(a.values)") { try w.upNextOnScreen() == a.values }
        }
        s.then("Up Next lists {string} then {string}") { w, a in
            try w.goTo(tab: "upNext")
            try w.eventually("Up Next to list \(a.values)", timeout: 20) { try w.upNextOnScreen() == a.values }
        }
        s.then("Up Next lists {string}, {string} then {string}") { w, a in
            try w.goTo(tab: "upNext")
            try w.eventually("Up Next to list \(a.values)", timeout: 20) { try w.upNextOnScreen() == a.values }
        }
    }

    @MainActor static func serverUpNext(_ w: World, _ want: [String]) throws {
        var last: [String] = []
        do {
            try w.eventually("the server's Up Next to be \(want)", timeout: 20) {
                last = try w.upNextOnServer()
                return last == want
            }
        } catch { throw World.Failure("\(error) (it's \(last))") }
    }

    @MainActor static func episodeState(_ w: World, _ title: String, _ key: String, _ want: Bool, timeout: TimeInterval = 20) throws {
        try w.eventually("\(title) to be \(want ? "" : "not ")\(key)", timeout: timeout) {
            (try w.call("episode", ["email": w.email, "title": title])[key] as? Bool) == want
        }
    }

    @MainActor static func showPageLists(_ w: World, _ show: String, _ titles: [String]) throws {
        try w.openShow(show)
        for title in titles {
            try w.waitFor("podcast.episode.\(try w.episodeId(title))", timeout: 20, "\(title) on the page for \(show)")
        }
    }

    /// Opens a fresh install signed in as the scenario's person, and waits for the first sync.
    @MainActor static func openSignedIn(_ w: World) throws {
        w.launch(signedInAs: w.email, extra: w.launchExtras)
        try w.waitFor("tab.upNext", timeout: 30, "the tabs after signing in")
        let queued = try w.upNextOnServer()
        if let first = queued.first {
            let mini = try w.waitFor("miniPlayer", timeout: 30)
            try w.eventually("the mini player to show \(first)", timeout: 20) { mini.staticTexts[first].exists }
        }
    }
}
