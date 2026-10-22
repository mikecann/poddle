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
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: page, callback: .customScheme("poddle")) { url, error in
                if let url { return continuation.resume(returning: url) }
                // A cancel that comes back before anyone could have seen the sheet is iOS refusing to
                // open it, not someone closing it.
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin,
                   Date.now.timeIntervalSince(opened) > 1.5 {
                    continuation.resume(throwing: AccountError.cancelled)
                } else {
                    let code = (error as NSError?)?.code ?? 0
                    continuation.resume(throwing: AccountError.failed("Couldn't open the sign-in page (\(code)). Try again."))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AccountError.failed("Couldn't open the sign-in page. Try again."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
            #else
            NSApplication.shared.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}

extension Account {
    /// Apple or Google, start to finish: the provider's page in the sheet, then the code back to Convex Auth.
    func signIn(with provider: Provider, sheet: SignInSheet) async throws {
        let (page, state) = try await startWebSignIn(provider)
        let landed = try await sheet.open(page)
        try await completeWebSignIn(provider, landedOn: landed, state: state)
    }
}
