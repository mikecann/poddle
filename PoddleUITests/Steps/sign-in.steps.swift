import XCTest

/// features/app/sign-in.feature
final class SignInSteps: StepModule {
    override class func register(_ s: StepRegistry) {
        s.when("{string} opens Poddle and tries to sign in") { w, a in
            w.email = a.string(0)
            w.launch(signedInAs: a.string(0))
        }

        s.then("the sign-in screen says {string}") { w, a in
            let error = try w.waitFor("signIn.error", timeout: 20, "the sign-in error")
            try w.eventually("the error to say \(a.string(0))") { error.staticTexts[a.string(0)].exists || error.label.contains(a.string(0)) }
        }

        s.when("they sign out from Profile") { w, _ in
            try w.goTo(tab: "profile")
            try w.tap("settings.signOut")
            // The confirmation sheet's button.
            let confirm = w.app.buttons["Sign Out"].firstMatch
            try w.eventually("the sign-out confirmation") { w.app.sheets.buttons["Sign Out"].exists || w.app.buttons.matching(identifier: "Sign Out").count > 1 }
            (w.app.sheets.buttons["Sign Out"].exists ? w.app.sheets.buttons["Sign Out"] : confirm).tap()
        }

        s.then("nothing from {string} is on screen") { w, a in
            try w.eventually("\(a.string(0)) to be gone") {
                !w.app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", a.string(0))).firstMatch.exists
                    && !w.app.staticTexts["Sunrise in A"].exists
            }
        }

        s.when("they delete their account from Profile") { w, _ in
            try w.goTo(tab: "profile")
            try w.tap("settings.deleteAccount")
            let first = w.app.buttons["Delete Account"].firstMatch
            guard first.waitForExistence(timeout: 10) else { throw World.Failure("No \"Delete Account\" confirmation") }
            first.tap()
            let sure = w.app.alerts.buttons["Delete Everything"].firstMatch
            guard sure.waitForExistence(timeout: 10) else { throw World.Failure("No \"Are you sure?\" alert") }
            sure.tap()
        }

        s.then("the listener has no account any more") { w, _ in
            try w.eventually("the account to be gone", timeout: 20) {
                (try w.call("user", ["email": w.config.users["listener"]!])["exists"] as? Bool) == false
            }
        }
    }
}
