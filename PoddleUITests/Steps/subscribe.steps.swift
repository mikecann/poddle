import UIKit
import XCTest

/// features/app/subscribe.feature
final class SubscribeSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("they search Discover for {string}") { w, a in
            try w.goTo(tab: "discover")
            let field = try w.waitFor("discover.search")
            field.tap()
            field.typeText(a.string(0))
        }

        s.when("they follow {string} from the results") { w, a in
            // The result card holding that title.
            let card = w.app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'discover.result.'"))
                .containing(NSPredicate(format: "label == %@", a.string(0))).firstMatch
            guard card.waitForExistence(timeout: 20) else { throw World.Failure("\(a.string(0)) isn't in the results") }
            let id = card.identifier.dropFirst("discover.result.".count)
            try w.tap("discover.follow.\(id)")
            try w.eventually("the button to say Following") { w.element("discover.follow.\(id)").label.contains("Following") }
        }

        s.when("they paste the feed URL for {string} into Discover's URL field") { w, a in
            let shows = try w.call("shows")["shows"] as? [[String: Any]] ?? []
            guard let url = shows.first(where: { $0["title"] as? String == a.string(0) })?["feedUrl"] as? String else {
                throw World.Failure("No fixture show \(a.string(0))")
            }
            UIPasteboard.general.string = url
            try w.goTo(tab: "discover")
            // Discover offers Paste for the link on the clipboard. The simulator refuses that direct
            // read under automation, as if they'd tapped "Don't Allow", so Discover falls back to its
            // URL field, which is pasted into through the edit menu.
            if w.element("discover.paste").exists { try w.tap("discover.paste") } else { try w.tap("discover.type") }
            let field = w.element("discover.urlField")
            let toast = w.element("discover.toast")
            try w.eventually("Discover to add it, or to offer the URL field", timeout: 20) {
                if toast.exists, toast.label.hasPrefix("Following") { w.memo["discoverToast"] = toast.label }
                return w.memo["discoverToast"] != nil || field.exists
            }
            if w.memo["discoverToast"] != nil { return }
            field.tap()
            try w.withoutIdleWaits {
                field.press(forDuration: 1.0)
                let paste = w.app.menuItems["Paste"].firstMatch
                guard paste.waitForExistence(timeout: 5) else { throw World.Failure("No Paste in the edit menu") }
                paste.tap()
            }
            try w.eventually("the field to hold the URL") { (field.value as? String) == url }
            try w.tap("discover.add")
            try w.eventually("Discover to add the show", timeout: 20) {
                if toast.exists, toast.label.hasPrefix("Following") { w.memo["discoverToast"] = toast.label; return true }
                return false
            }
        }

        s.then("Discover says {string}") { w, a in
            let said = try w.memo["discoverToast"] ?? w.waitFor("discover.toast", timeout: 20, "Discover's message").label
            XCTAssertEqual(said, a.string(0))
        }

        s.when("they open the page for {string}") { w, a in try w.openShow(a.string(0)) }

        s.when("they tap \"< Library\"") { w, _ in try w.tap("back") }

        s.then("they're back on the Library with {string}") { w, a in
            try w.waitGone("podcast.list", timeout: 5)
            try w.waitFor("library.show.\(try w.podcastId(a.string(0)))", timeout: 5, "\(a.string(0)) in the Library")
        }

        s.when("they unsubscribe from {string} on its page") { w, a in
            try w.openShow(a.string(0))
            try w.tap("podcast.follow")
            let confirm = w.app.buttons["Unsubscribe"].firstMatch
            guard confirm.waitForExistence(timeout: 10) else { throw World.Failure("No unsubscribe confirmation") }
            confirm.tap()
        }

        s.then("they don't follow {string} any more") { w, a in
            try w.eventually("the server to say unsubscribed", timeout: 20) {
                (try w.call("podcast", ["email": w.email, "show": a.string(0)])["subscribed"] as? Bool) == false
            }
        }

        s.then("they follow {string} again") { w, a in
            try w.eventually("the server to say subscribed", timeout: 20) {
                (try w.call("podcast", ["email": w.email, "show": a.string(0)])["subscribed"] as? Bool) == true
            }
            try w.eventually("the page to say Following") { w.element("podcast.follow").label.contains("Following") }
        }
    }
}
