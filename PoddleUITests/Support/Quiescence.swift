import Foundation
import ObjectiveC
import XCTest

/// XCTest waits for the app to go idle before every action. On iOS 27 an open context menu
/// keeps animating, so that wait never ends and the scenario hangs. `World.withoutIdleWaits`
/// swaps XCTest's private quiescence waits for no-ops for the few actions that happen while a
/// menu is open, then puts the originals straight back. If a future Xcode renames them, nothing
/// is swapped and the menu steps hang again, which XCTest's test timeout reports.
extension World {
    func withoutIdleWaits<T>(_ body: () throws -> T) rethrows -> T {
        let twoArgs: @convention(block) (AnyObject, Bool, Bool) -> Bool = { _, _, _ in true }
        let threeArgs: @convention(block) (AnyObject, Bool, AnyObject?, Bool) -> Bool = { _, _, _, _ in true }
        let noOps: [(String, Any)] = [
            ("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", twoArgs),
            ("waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:", threeArgs),
        ]
        var originals: [(Method, IMP)] = []
        if let cls = NSClassFromString("XCUIApplicationProcess") {
            for (name, noOp) in noOps {
                guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { continue }
                originals.append((method, method_setImplementation(method, imp_implementationWithBlock(noOp))))
            }
        }
        defer { for (method, imp) in originals { method_setImplementation(method, imp) } }
        return try body()
    }
}
