import XCTest

/// features/app/downloads.feature
final class DownloadsSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.given("they don't auto-download") { w, _ in
            try w.call("setGlobal", ["email": w.email, "patch": ["autoDownload": "never"]])
        }

        s.when("they download {string} from its menu") { w, a in try w.rowMenu(a.string(0), choose: "Download") }
        s.given("they've downloaded {string}") { w, a in
            try w.rowMenu(a.string(0), choose: "Download")
            try downloaded(w, a.string(0))
        }

        s.when("they remove the download of {string}") { w, a in
            try w.rowMenu(a.string(0), choose: "Remove download")
            try w.waitFor("undoToast", timeout: 10, "the Undo toast")
        }

        s.when("the Undo toast goes away by itself") { w, _ in try w.waitGone("undoToast", timeout: 25) }

        s.then("{string} shows as downloaded") { w, a in try downloaded(w, a.string(0)) }

        s.then("{string} shows as not downloaded") { w, a in
            let parts = try w.rowParts(a.string(0))
            try w.eventually("\(a.string(0)) to say Not downloaded", timeout: 15) { label(parts, "Not downloaded").exists }
            XCTAssertFalse(label(parts, "Downloaded").exists)
        }
    }

    /// The row's part with exactly this label (the row's identifier is on each part).
    @MainActor static func label(_ parts: XCUIElementQuery, _ text: String) -> XCUIElement {
        parts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    @MainActor static func downloaded(_ w: World, _ title: String) throws {
        let parts = try w.rowParts(title)
        try w.eventually("\(title) to be downloaded", timeout: 30) {
            label(parts, "Downloaded").exists && !label(parts, "Not downloaded").exists
        }
    }
}
