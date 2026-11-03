import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import PoddleKit

/// Runs Apple's or Google's sign-in page in a secure sheet that shares Safari's sign-ins, and
/// catches the moment it lands back on Poddle. The deployment's /app/signed-in page passes its
/// query on to poddle://signed-in (convex/http.ts), which the sheet catches.
///
/// It's a web flow because Convex Auth v2 has no way to accept a native Sign in with Apple
/// identity token: its Apple provider only redeems a code from Apple's web page.
@MainActor
final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ page: URL) async throws -> URL {
        let opened = Date.now
        let result: Result<URL, AccountError> = await withCheckedContinuation { continuation in
            // iOS can call the completion handler with an error *and* return false from start(), and
            // resuming a continuation twice crashes the app (PODDLE-8, App Review on 1.0.6). The
            // first ending wins.
            let finish = FirstAnswer<Result<URL, AccountError>> { continuation.resume(returning: $0) }
            let session = ASWebAuthenticationSession(url: page, callback: .customScheme("poddle")) { url, error in
                finish(WebSignIn.outcome(url: url, error: error, after: Date.now.timeIntervalSince(opened)))
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish(.failure(WebSignIn.couldNotStart)) }
        }
        self.session = nil
        if case let .failure(error) = result, error != .cancelled {
            // So we find out why it wouldn't open, not just that it didn't.
            Diagnostics.note("Sign-in sheet didn't open: \(error.localizedDescription)")
        }
        return try result.get()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            Self.appWindow() ?? ASPresentationAnchor()
            #else
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }

    #if os(iOS)
    /// The app's own window to show the sheet over: the key one if it's ours, else any visible
    /// normal-level one in the frontmost scene. ChefKit's overlay floats above at alert level, so
    /// it's skipped. Never a window without a scene, which iOS refuses to present from.
    private static func appWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { rank($0.activationState) < rank($1.activationState) }
        for scene in scenes {
            if let key = scene.keyWindow, key.windowLevel == .normal { return key }
            if let window = scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal }) { return window }
        }
        return scenes.first.map { UIWindow(windowScene: $0) }
    }

    private static func rank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: 0
        case .foregroundInactive: 1
        case .background: 2
        default: 3
        }
    }
    #endif
}

extension Account {
    /// Apple or Google, start to finish: the provider's page in the sheet, then the code back to Convex Auth.
    func signIn(with provider: Provider, sheet: SignInSheet) async throws {
        let (page, state) = try await startWebSignIn(provider)
        let landed = try await sheet.open(page)
        try await completeWebSignIn(provider, landedOn: landed, state: state)
    }
}
