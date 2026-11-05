import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import PoddleKit

/// Sign in with Apple through the iPhone's own sheet (Face ID, no web page), which hands back
/// an identity token for `auth:signInWithAppleNative` to check. It's what Mike wants in all his
/// apps (docs/decisions.md). Apple's automated check of each submission fails here with error
/// 1000, as it does on every other way in (PODDLE-A, C and D), so that isn't a bug in this.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential: Sendable {
        var identityToken: String
        var firstName: String?
        var lastName: String?
    }

    private var finish: FirstAnswer<Result<Credential, AccountError>>?
    private var controller: ASAuthorizationController?

    func authorize(nonce: AppleSignInNonce) async throws -> Credential {
        #if DEBUG
        if let fake = Self.fakeSignIn { return try await fake(nonce) }
        #endif
        let result: Result<Credential, AccountError> = await withCheckedContinuation { continuation in
            // The delegate could in principle hear twice (an error after a cancel); resuming
            // twice would crash, so the first answer wins.
            finish = FirstAnswer { continuation.resume(returning: $0) }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce.hashed
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
        finish = nil
        controller = nil
        return try result.get()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                finish?(.failure(.failed("Apple didn't send back who you are. Try again.")))
                return
            }
            finish?(.success(Credential(identityToken: token, firstName: credential.fullName?.givenName,
                                        lastName: credential.fullName?.familyName)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let code = (error as NSError).code
        MainActor.assumeIsolated {
            if code == ASAuthorizationError.canceled.rawValue {
                finish?(.failure(.cancelled))
            } else {
                finish?(.failure(.failed("Couldn't sign in with Apple (\(code)). Try again.")))
            }
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            SignInSheet.appWindow() ?? ASPresentationAnchor()
            #else
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }

    #if DEBUG
    /// `-PoddleFakeAppleSignIn <email> -PoddleFakeAppleURL <url>` (the e2e suite): the simulator
    /// has no Apple Account, so ask the fixture server's stand-in for Apple for the identity
    /// token instead of the system sheet. The backend only trusts that stand-in on the e2e
    /// world's local backend (convex/lib/e2e.ts).
    private static var fakeSignIn: ((AppleSignInNonce) async throws -> Credential)? {
        let defaults = UserDefaults.standard
        guard let email = defaults.string(forKey: "PoddleFakeAppleSignIn"),
              let base = defaults.string(forKey: "PoddleFakeAppleURL").flatMap(URL.init(string:)) else { return nil }
        return { nonce in
            var request = URLRequest(url: base.appending(path: "_token"))
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(["email": email, "nonce": nonce.hashed])
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Reply: Decodable { var identityToken: String }
            return Credential(identityToken: try JSONDecoder().decode(Reply.self, from: data).identityToken)
        }
    }
    #endif
}
