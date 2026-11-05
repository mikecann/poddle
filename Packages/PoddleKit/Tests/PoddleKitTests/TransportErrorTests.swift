import ConvexMobile
import Foundation
import Testing
@testable import PoddleKit

/// A ConvexError's message is written for people and worth showing (PODDLE-E: adding a show by
/// a link that couldn't be reached). Any other server error is hidden text in prod, so it isn't.
@Suite struct TransportErrorTests {
    @Test func aConvexErrorCarriesItsMessageForPeople() {
        let error = ConvexMobileTransport.map(ClientError.ConvexError(
            data: #"{"code":"feedUnreachable","message":"Couldn't reach feeds.example.com. Try again later."}"#
        ))
        #expect(error == .refused(code: "feedUnreachable", message: "Couldn't reach feeds.example.com. Try again later."))
        #expect(error.userMessage == "Couldn't reach feeds.example.com. Try again later.")
        #expect(!error.isRetryable)
    }

    @Test func aHiddenServerErrorHasNothingToShow() {
        let error = ConvexMobileTransport.map(ClientError.ServerError(msg: "[Request ID: abc] Server Error"))
        #expect(error.userMessage == nil)
        #expect(!error.isRetryable)
    }

    @Test func signInRefusalsStillRetryOnceThereIsASession() {
        let error = ConvexMobileTransport.map(ClientError.ConvexError(data: #"{"code":"unauthenticated","message":"Sign in first"}"#))
        #expect(error == .unauthorized("Sign in first"))
        #expect(error.isRetryable)
    }
}
