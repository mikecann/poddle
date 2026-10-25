import XCTest

/// features/app/up-next.feature
final class UpNextSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("they drag {string} above {string}") { w, a in
            try w.tap("upNext.edit")
            let moving = try w.rowFrame(a.string(0))
            let target = try w.rowFrame(a.string(1))
            // In edit mode each row has a reorder handle at its trailing edge.
            let handles = w.app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")).allElementsBoundByIndex
            guard let handle = handles.first(where: { $0.frame.midY > moving.minY && $0.frame.midY < moving.maxY }) else {
                throw World.Failure("No reorder handle on \(a.string(0)) (found \(handles.count))")
            }
            let to = w.app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: handle.frame.midX, dy: target.minY + 8))
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
            try w.tap("upNext.edit")
        }

        s.when("they archive {string} from its menu") { w, a in try w.rowMenu(a.string(0), choose: "Archive") }

        s.when("they swipe {string} left to remove it") { w, a in try w.swipeRow(a.string(0), by: -130) }

        s.when("they swipe {string} all the way left to mark it played") { w, a in try w.swipeRow(a.string(0), by: -330) }

        s.given("they've also queued every episode of {string}, {string} and {string}") { w, a in
            // Following a show they already follow is fine: `follow` takes its episodes out of Up Next
            // first, and they all go back on the end here.
            for show in a.values {
                let episodes = try w.call("follow", ["email": w.email, "show": show])["episodes"] as? [[String: String]] ?? []
                try w.call("queue", ["email": w.email, "episodes": episodes.map { $0["title"]! }])
            }
        }

        s.when("they scroll to the end of Up Next") { w, _ in
            try w.goTo(tab: "upNext")
            // The whole queue has synced: the last episode on the server has its row.
            if let last = try w.upNextOnServer().last {
                try w.eventually("\(last) in Up Next", timeout: 20) { try w.rowParts(last).firstMatch.exists }
            }
            try w.scrollToEnd(watching: w.element("upNext.end"))
        }

        s.then("{string} and the end of the list sit above the mini player") { w, a in
            let mini = try w.waitFor("miniPlayer", timeout: 20).frame
            let row = try w.rowParts(a.string(0)).allElementsBoundByIndex.filter { $0.exists }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let end = w.element("upNext.end")
            guard !row.isNull, end.exists else { throw World.Failure("\(a.string(0)) or the end of the list isn't on screen") }
            for (what, frame) in [(a.string(0), row), ("The end of the list", end.frame)] {
                XCTAssertLessThanOrEqual(frame.maxY, mini.minY, "\(what) (\(frame)) is behind the mini player (\(mini))")
            }
        }
    }
}
