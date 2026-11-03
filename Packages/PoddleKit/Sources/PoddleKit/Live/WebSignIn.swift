import AuthenticationServices
import CryptoKit
import Foundation
import Synchronization

/// How the app's sign-in sheet (`SignInSheet`, an ASWebAuthenticationSession) ended, as the
/// answer `Account.signIn` gets. Here rather than in the app so it can be tested.
public enum WebSignIn {
    /// Reads the sheet's completion handler: the page it landed back on, or why it didn't.
    /// `elapsed` is the time since the sheet was asked to open.
    public static func outcome(url: URL?, error: Error?, after elapsed: TimeInterval) -> Result<URL, AccountError> {
        if let url { return .success(url) }
        let error = error as NSError?
        // A cancel that comes back before anyone could have seen the sheet is iOS refusing to
        // open it, not someone closing it.
        if error?.domain == ASWebAuthenticationSessionErrorDomain,
           error?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue, elapsed > 1.5 {
            return .failure(.cancelled)
        }
        return .failure(.sheetRefused(error?.code ?? 0))
    }
}

/// Passes on the first answer it's given and quietly drops any after it.
///
/// For handing a callback API's ending to a continuation, which crashes the app if it's resumed
/// twice. ASWebAuthenticationSession can call its completion handler with an error and also
/// return false from start() (PODDLE-8), so both paths go through one of these.
public final class FirstAnswer<Value: Sendable>: Sendable {
    private let deliver: @Sendable (Value) -> Void
    private let done = Mutex(false)

    public init(_ deliver: @escaping @Sendable (Value) -> Void) {
        self.deliver = deliver
    }

    public var answered: Bool { done.withLock { $0 } }

    public func callAsFunction(_ value: Value) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { deliver(value) }
    }
}

/// The nonce for one native Sign in with Apple: the request carries `hashed`, Apple signs it
/// into the identity token, and the backend checks `raw` against it, so a token only works
/// for the sign-in it was made for.
public struct AppleSignInNonce: Sendable, Hashable {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    public static func make() -> AppleSignInNonce {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return AppleSignInNonce(raw: bytes.map { String(format: "%02x", $0) }.joined())
    }

    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
