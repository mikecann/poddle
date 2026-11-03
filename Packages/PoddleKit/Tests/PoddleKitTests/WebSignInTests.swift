import AuthenticationServices
import Foundation
import Testing
@testable import PoddleKit

/// The sign-in sheet's ending: how it's read, and that only one ending ever reaches the caller.
/// iOS can both call the sheet's completion handler with an error and return false from start(),
/// and a second resume of a continuation crashes the app (PODDLE-8, App Review on 1.0.6).
struct WebSignInTests {
    private let cancel = NSError(domain: ASWebAuthenticationSessionErrorDomain,
                                 code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
    private let page = URL(string: "poddle://signed-in?code=abc")!

    @Test func landingBackOnPoddleIsTheAnswer() {
        #expect(WebSignIn.outcome(url: page, error: nil, after: 0.2) == .success(page))
    }

    @Test func closingTheSheetIsACancel() {
        #expect(WebSignIn.outcome(url: nil, error: cancel, after: 4) == .failure(.cancelled))
    }

    @Test func aCancelBeforeAnyoneCouldSeeTheSheetIsIOSRefusingToOpenIt() {
        #expect(WebSignIn.outcome(url: nil, error: cancel, after: 0.3)
            == .failure(.failed("Couldn't open the sign-in page (1). Try again.")))
    }

    @Test func otherErrorsSayWhichOne() {
        let invalid = NSError(domain: ASWebAuthenticationSessionErrorDomain,
                              code: ASWebAuthenticationSessionError.presentationContextInvalid.rawValue)
        #expect(WebSignIn.outcome(url: nil, error: invalid, after: 0.01)
            == .failure(.failed("Couldn't open the sign-in page (3). Try again.")))
    }

    @Test func onlyTheFirstEndingIsPassedOn() {
        let got = Box()
        let finish = FirstAnswer<Int> { got.append($0) }
        finish(1)   // the completion handler's error
        finish(2)   // start() returning false straight after
        #expect(got.values == [1])
        #expect(finish.answered)
    }

    @Test func endingsRacingFromDifferentThreadsStillPassOnOne() async {
        let got = Box()
        let finish = FirstAnswer<Int> { got.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<50 { group.addTask { finish(n) } }
        }
        #expect(got.values.count == 1)
    }

    /// The real thing: a checked continuation, offered two endings, resumes once and doesn't trap.
    @Test func aContinuationOfferedTwoEndingsResumesOnce() async {
        let result: Result<URL, AccountError> = await withCheckedContinuation { continuation in
            let finish = FirstAnswer<Result<URL, AccountError>> { continuation.resume(returning: $0) }
            finish(WebSignIn.outcome(url: nil, error: cancel, after: 0.01))
            finish(.failure(WebSignIn.couldNotStart))
        }
        #expect(result == .failure(.failed("Couldn't open the sign-in page (1). Try again.")))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func append(_ n: Int) { lock.withLock { _values.append(n) } }
}
