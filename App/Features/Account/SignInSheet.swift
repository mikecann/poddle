import AuthenticationServices
import Foundation
import SwiftUI
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
            // resuming a continuation twice crashes the app (PODDLE-8, Apple's automated check of 1.0.6). The
            // first ending wins.
            let finish = FirstAnswer<Result<URL, AccountError>> { continuation.resume(returning: $0) }
            let session = ASWebAuthenticationSession(url: page, callback: .customScheme("poddle")) { url, error in
                finish(WebSignIn.outcome(url: url, error: error, after: Date.now.timeIntervalSince(opened)))
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish(.failure(.sheetRefused(nil))) }
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
    static func appWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { rank($0.activationState) < rank($1.activationState) }
        for scene in scenes {
            if let key = scene.keyWindow, key.windowLevel == .normal { return key }
            if let window = scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal }) { return window }
        }
        return scenes.first.map { UIWindow(windowScene: $0) }
    }


    // MARK: Safari, when iOS won't open the sheet

    /// Waiting for Safari to come back on poddle://signed-in, and whether Poddle has gone to
    /// the background since (so coming back to the foreground means they've returned).
    private static var browserWait: FirstAnswer<Result<URL, AccountError>>?
    private static var leftForBrowser = false

    /// The same sign-in page in Safari. Its last stop (/app/signed-in) sends Safari on to
    /// poddle://signed-in, which reopens Poddle and comes in through `browserReturned`.
    func openInBrowser(_ page: URL) async throws -> URL {
        let result: Result<URL, AccountError> = await withCheckedContinuation { continuation in
            let finish = FirstAnswer<Result<URL, AccountError>> { continuation.resume(returning: $0) }
            Self.browserWait = finish
            Self.leftForBrowser = false
            UIApplication.shared.open(page) { opened in
                if !opened { finish(.failure(.failed("Couldn't open Safari to sign in. Try again."))) }
            }
        }
        Self.browserWait = nil
        if case let .failure(error) = result, error != .cancelled {
            Diagnostics.note("Sign-in in Safari didn't work either: \(error.localizedDescription)")
        }
        return try result.get()
    }

    /// poddle://signed-in, from Safari. True when it was ours to handle.
    static func browserReturned(_ url: URL) -> Bool {
        guard url.scheme == "poddle", url.host() == "signed-in" else { return false }
        browserWait?(.success(url))
        return true
    }

    /// Back in Poddle without Safari sending them back on the link: they gave up, so the
    /// buttons come back. A short wait first, since the link and the app becoming active can
    /// arrive in either order.
    static func scenePhaseChanged(to phase: ScenePhase) {
        guard let waiting = browserWait else { return }
        if phase == .background { leftForBrowser = true }
        guard phase == .active, leftForBrowser else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            waiting(.failure(.cancelled))
        }
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
    /// Apple: the iPhone's own Sign in with Apple sheet. Only if that sheet itself fails (not
    /// a cancel, and not the server saying no) does it fall back to Apple's web page.
    func signInWithApple(native: AppleSignIn, sheet: SignInSheet) async throws {
        let nonce = AppleSignInNonce.make()
        let credential: AppleSignIn.Credential
        do {
            credential = try await native.authorize(nonce: nonce)
        } catch AccountError.cancelled {
            throw AccountError.cancelled
        } catch {
            Diagnostics.note("Native Sign in with Apple didn't work: \(error.localizedDescription)")
            try await signIn(with: .apple, sheet: sheet)
            return
        }
        try await signInWithApple(identityToken: credential.identityToken, nonce: nonce.raw,
                                  firstName: credential.firstName, lastName: credential.lastName)
    }

    /// Apple's or Google's web page, start to finish: in the sheet, or in Safari when iOS won't
    /// open the sheet, then the code back to Convex Auth.
    func signIn(with provider: Provider, sheet: SignInSheet) async throws {
        let (page, state) = try await startWebSignIn(provider)
        let landed: URL
        do {
            landed = try await sheet.open(page)
        } catch AccountError.sheetRefused {
            #if os(iOS)
            landed = try await sheet.openInBrowser(page)
            #else
            throw AccountError.sheetRefused(nil)
            #endif
        }
        try await completeWebSignIn(provider, landedOn: landed, state: state)
    }
}
