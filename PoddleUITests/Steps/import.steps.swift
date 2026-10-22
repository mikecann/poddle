import XCTest

/// features/app/import.feature
final class ImportSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.given("they have an Overcast export on the phone") { w, _ in
            let path = try w.call("overcastExport")["path"] as! String
            // Stands in for picking it in the system's file picker.
            w.launchExtras += ["-PoddleImportFile", path]
        }

        s.when("they import the Overcast export from Profile") { w, _ in
            try w.goTo(tab: "profile")
            try w.tap("settings.import")
            try w.tap("import.start", timeout: 15)
        }

        s.then("the import finishes") { w, _ in
            try w.waitFor("import.seeStats", timeout: 90, "the finished import")
        }

        s.then("{string} is one of their past shows") { w, a in
            try w.eventually("\(a.string(0)) in past shows", timeout: 20) {
                (try w.call("pastShows", ["email": w.email])["shows"] as? [String] ?? []).contains(a.string(0))
            }
            try w.goTo(tab: "library")
            try w.tap("library.filter.past")
            try w.waitFor("library.show.\(try w.podcastId(a.string(0)))", timeout: 15, "\(a.string(0)) under Past shows")
        }
    }
}
