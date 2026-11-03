import AuthenticationServices
import Foundation
import Synchronization

/// How the app's sign-in sheet (`SignInSheet`, an ASWebAuthenticationSession) ended, as the
/// answer `Account.signIn` gets. Here rather than in the app so it can be tested.
public enum WebSignIn {
    /// start() said no without a word from the completion handler.
    public static let couldNotStart = AccountError.failed("Couldn't open the sign-in page. Try again.")

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
        return .failure(.failed("Couldn't open the sign-in page (\(error?.code ?? 0)). Try again."))
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
