import Foundation
import XCTest

/// Finding and waiting for things on screen. Prefer accessibility identifiers (`tab.upNext`,
/// `upNext.row.<episode id>`, `nowPlaying.playPause`) over visible text.
extension World {
    /// The first element anywhere with that accessibility identifier.
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    func waitFor(_ id: String, timeout: TimeInterval = 15, _ what: String? = nil) throws -> XCUIElement {
        let e = element(id)
        guard e.waitForExistence(timeout: timeout) else { throw Failure("\(what ?? id) never appeared") }
        return e
    }

    func tap(_ id: String, timeout: TimeInterval = 15) throws {
        let e = try waitFor(id, timeout: timeout)
        // The tab bar, mini player and Undo toast never scroll.
        let fixed = ["tab.", "miniPlayer", "undoToast", "nowPlaying.", "signIn."].contains { id.hasPrefix($0) }
        if !fixed { try reveal(e, id) }
        try eventually("\(id) to be tappable", timeout: 15) { e.isHittable }
        e.tap()
    }

    /// Scrolls until the element sits clear of the tab bar, mini player and toast (and the top bar).
    func reveal(_ e: XCUIElement, _ what: String) throws {
        let window = app.windows.firstMatch.frame
        let tabBar = element("tab.upNext")
        let bottom = (tabBar.exists ? tabBar.frame.minY : window.maxY) - (element("miniPlayer").exists ? 110 : 20)
        let top = window.minY + 50
        // Mid-transition (a tab switch, a push) the frame can still be empty.
        try? eventually("\(what) to have a frame", timeout: 3) { !e.frame.isEmpty }
        var lastFrame = CGRect.null
        for _ in 0..<12 {
            let f = e.frame
            if f.minY >= top && f.maxY <= bottom { return }
            // Scrolling doesn't move it: it isn't in a scroll view, so leave it to the tap.
            if f == lastFrame { return }
            lastFrame = f
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let distance = f.maxY > bottom ? -min(f.maxY - bottom + 40, 300) : min(top - f.minY + 40, 300)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        if !e.isHittable { throw Failure("Couldn't scroll \(what) into view") }
    }

    /// Polls `check` until it's true.
    func eventually(_ what: String, timeout: TimeInterval = 25, _ check: () throws -> Bool) throws {
        let until = Date().addingTimeInterval(timeout)
        while true {
            if try check() { return }
            if Date() > until { throw Failure("Timed out after \(Int(timeout)) s waiting for \(what)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    func waitGone(_ id: String, timeout: TimeInterval = 15) throws {
        try eventually("\(id) to go", timeout: timeout) { !element(id).exists }
    }

    /// Visible text, anywhere.
    func text(_ label: String) -> XCUIElement {
        app.staticTexts[label].firstMatch
    }

    func waitForText(_ label: String, timeout: TimeInterval = 15) throws {
        guard text(label).waitForExistence(timeout: timeout) else { throw Failure("\"\(label)\" never appeared") }
    }

    func goTo(tab: String) throws {
        try tap("tab.\(tab)")
    }

    // MARK: Episodes and shows by title

    /// The episode's id, from the backend (cached for the scenario).
    func episodeId(_ title: String) throws -> String {
        if let id = memo["episode:\(title)"] { return id }
        let id = try call("episode", ["email": email, "title": title])["id"] as! String
        memo["episode:\(title)"] = id
        return id
    }

    func podcastId(_ show: String) throws -> String {
        if let id = memo["show:\(show)"] { return id }
        let id = try call("podcast", ["email": email, "show": show])["id"] as! String
        memo["show:\(show)"] = id
        return id
    }

    /// Up Next as the app shows it, top to bottom, by episode title (rows are `upNext.row.<id>`).
    /// Read from one snapshot of the screen: querying each part separately takes seconds, longer
    /// than an Undo toast lasts.
    func upNextOnScreen() throws -> [String] {
        let prefix = "upNext.row."
        // The row's identifier lands on each of its parts, so keep each row's topmost one.
        var top: [String: CGFloat] = [:]
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix(prefix), node.frame.height > 0 {
                top[node.identifier] = min(top[node.identifier] ?? .infinity, node.frame.minY)
            }
            for child in node.children { walk(child) }
        }
        walk(try app.snapshot())
        var titles = try knownEpisodeTitles()
        let ids = top.keys.map { String($0.dropFirst(prefix.count)) }
        if ids.contains(where: { titles[$0] == nil }) { titles = try knownEpisodeTitles(refresh: true) }
        return top.sorted { $0.value < $1.value }.map { row in
            let id = String(row.key.dropFirst(prefix.count))
            return titles[id] ?? id
        }
    }

    /// id → title for every episode of every show in their library. Asked once, and again only
    /// when the screen shows an episode it doesn't know (polling stays fast, inside an Undo toast's life).
    func knownEpisodeTitles(refresh: Bool = false) throws -> [String: String] {
        if !refresh, let cached = titleCache { return cached }
        let episodes = try call("catalog", ["email": email])["episodes"] as? [[String: String]] ?? []
        let titles = Dictionary(episodes.map { ($0["id"]!, $0["title"]!) }, uniquingKeysWith: { a, _ in a })
        titleCache = titles
        return titles
    }

    /// Back to the top of the Library tab, then into a show's page.
    func openShow(_ show: String) throws {
        try goTo(tab: "library")
        try eventually("the Library tab", timeout: 5) {
            element("back").isHittable || element("library.grid").exists || element("library.list").exists
        }
        // A tap can be swallowed by a system alert the interruption monitor deals with, so try again.
        // A tap can be swallowed by a system alert the interruption monitor deals with, so try again.
        for _ in 0..<3 where element("back").exists {
            if element("back").isHittable { element("back").tap() }
            try? eventually("the page to go back", timeout: 3) { !element("back").exists }
        }
        try tap("library.show.\(try podcastId(show))", timeout: 20)
        try waitFor("podcast.list", timeout: 10, "the page for \(show)")
    }

    /// Up Next on the server, by title.
    func upNextOnServer() throws -> [String] {
        try call("upNext", ["email": email])["upNext"] as? [String] ?? []
    }
}

// MARK: - Rows, swipes, menus and the Undo toast

extension World {
    /// Every part of an Up Next row (its identifier lands on each of them).
    func rowParts(_ title: String) throws -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "upNext.row.\(try episodeId(title))")
    }

    /// The row's title text: a safe place to tap, press or start a swipe.
    func rowTitle(_ title: String, timeout: TimeInterval = 15) throws -> XCUIElement {
        let e = try rowParts(title).matching(NSPredicate(format: "label == %@", title)).firstMatch
        guard e.waitForExistence(timeout: timeout) else { throw Failure("\"\(title)\" isn't in Up Next") }
        try reveal(e, title)
        return e
    }

    /// The whole row's frame, from its parts.
    func rowFrame(_ title: String) throws -> CGRect {
        _ = try rowTitle(title)
        return try rowParts(title).allElementsBoundByIndex.filter { $0.exists }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    /// Drags a row sideways from near its trailing edge. Negative is to the left.
    func swipeRow(_ title: String, by dx: CGFloat) throws {
        let frame = try rowFrame(title)
        let window = app.windows.firstMatch
        let startX = dx < 0 ? frame.maxX - 30 : frame.minX + 30
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startX, dy: frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: .default, thenHoldForDuration: 0.15)
    }

    /// Long-presses a row and picks from its menu.
    func rowMenu(_ title: String, choose item: String) throws {
        let row = try rowTitle(title)
        try withoutIdleWaits {
            row.press(forDuration: 1.2)
            let button = app.buttons[item].firstMatch
            guard button.waitForExistence(timeout: 10) else { throw Failure("No \"\(item)\" in the menu for \(title)") }
            button.tap()
            // Let the menu finish closing before the next idle wait.
            try eventually("the menu to close", timeout: 5) { !app.buttons[item].exists }
        }
    }

    func pressUndo() throws {
        let toast = try waitFor("undoToast", timeout: 10, "the Undo toast")
        let button = element("undoToast.undo")
        if button.exists, button.isHittable {
            button.tap()
        } else {
            // The toast reads as one element; its Undo button is at the trailing end.
            toast.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        try waitGone("undoToast", timeout: 5)
    }

    // MARK: Now Playing

    func openNowPlaying() throws {
        if element("nowPlaying.close").exists { return }
        try waitFor("miniPlayer", timeout: 20)
        // The card's text, not its buttons.
        element("miniPlayer").coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        try waitFor("nowPlaying.close", timeout: 10, "Now Playing")
    }

    func closeNowPlaying() throws {
        guard element("nowPlaying.close").exists else { return }
        try tap("nowPlaying.close")
        try waitGone("nowPlaying.close", timeout: 10)
    }

    /// Now Playing's position in seconds, from the scrubber ("0:12 of 1:00").
    func position() throws -> Double {
        let scrubber = try waitFor("nowPlaying.scrubber", timeout: 10)
        let value = (scrubber.value as? String) ?? ""
        guard let clock = value.components(separatedBy: " of ").first else { throw Failure("Scrubber says \"\(value)\"") }
        return clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// Whether the main transport shows Pause (it's playing), in Now Playing or the mini player.
    func isPlaying() -> Bool {
        let np = element("nowPlaying.playPause")
        if np.exists { return np.label == "Pause" }
        return element("miniPlayer.playPause").label == "Pause"
    }
}
