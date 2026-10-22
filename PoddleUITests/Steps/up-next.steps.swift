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
    }
}
