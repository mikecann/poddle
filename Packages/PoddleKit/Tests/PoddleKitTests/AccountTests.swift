import Foundation
import Testing
@testable import PoddleKit

/// Answers Convex Auth's functions like the server would.
final class FakeAuthServer: ConvexHTTPCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _refreshes = 0
    var calls: [String] { lock.withLock { _calls } }
    var refreshes: Int { lock.withLock { _refreshes } }
    var expiresIn: Double = 60_000
    var revoked = false
    var offline = false

    func tokens(_ n: Int) -> JSONValue {
        ["accessToken": .string("access-\(n)"), "accessTokenExpiresAt": .number(Date().timeIntervalSince1970 * 1000 + expiresIn),
         "refreshToken": .string("refresh-\(n)"), "refreshTokenExpiresAt": 9e15, "userId": "user-1"]
    }

    func call(_ kind: String, _ path: String, _ args: [String: JSONValue], token: String?) async throws -> JSONValue {
        lock.withLock { _calls.append(path) }
        if offline { throw AccountError.network("offline") }
        switch path {
        case "auth:signInForTesting":
            if args["email"] == "stranger@example.com" { throw AccountError.inviteOnly("Poddle is invite-only for now.") }
            return ["status": "complete", "tokens": tokens(0)]
        case "users:me":
            return ["userId": "user-1", "name": "Mike", "email": "mike.cann@gmail.com", "picture": nil]
        case "auth:refreshSession":
            try await Task.sleep(for: .milliseconds(20))
            if revoked { return ["kind": "noSession"] }
            let n = lock.withLock { _refreshes += 1; return _refreshes }
            return ["kind": "rotated", "tokens": tokens(n)]
        case "auth:startSignInWithGoogle":
            return ["redirect": "https://accounts.google.com/o/oauth2/auth?x=1", "state": "st"]
        case "auth:completeSignInWithGoogle":
            #expect(args["code"] == "abc" && args["state"] == "st")
            return ["status": "complete", "tokens": tokens(0)]
        default:
            return .null
        }
    }
}

private let config = LiveConfig(deploymentURL: URL(string: "https://striped-turtle-260.ap-southeast-2.convex.cloud")!)

@MainActor
@Suite struct AccountTests {
    @Test func siteURLIsTheConvexSite() {
        #expect(config.siteURL.absoluteString == "https://striped-turtle-260.ap-southeast-2.convex.site")
        #expect(config.deploymentName == "striped-turtle-260")
    }

    @Test func testSignInSavesTheSessionAndWhoItIs() async throws {
        let server = FakeAuthServer()
        let store = MemorySessionStore()
        let account = Account(config: config, store: store, http: server)
        #expect(!account.isSignedIn)
        try await account.signInForTesting(email: "mike.cann@gmail.com")
        #expect(account.profile == .init(userId: "user-1", name: "Mike", email: "mike.cann@gmail.com", picture: nil))
        #expect(store.load()?.refreshToken == "refresh-0")
        // A relaunch picks it straight back up, offline or not.
        #expect(Account(config: config, store: store, http: server).userId == "user-1")
    }

    @Test func inviteOnlyComesThroughAsItsOwnError() async {
        let account = Account(config: config, store: MemorySessionStore(), http: FakeAuthServer())
        await #expect(throws: AccountError.inviteOnly("Poddle is invite-only for now.")) {
            try await account.signInForTesting(email: "stranger@example.com")
        }
        #expect(!account.isSignedIn)
    }

    @Test func webSignInRoundTrip() async throws {
        let server = FakeAuthServer()
        let account = Account(config: config, store: MemorySessionStore(), http: server)
        let (page, state) = try await account.startWebSignIn(.google)
        #expect(page.host() == "accounts.google.com")
        #expect(account.returnURL.absoluteString == "https://striped-turtle-260.ap-southeast-2.convex.site/app/signed-in")
        await #expect(throws: AccountError.cancelled) {
            try await account.completeWebSignIn(.google, landedOn: URL(string: "poddle://signed-in?convexAuthError=access_denied")!, state: state)
        }
        try await account.completeWebSignIn(.google, landedOn: URL(string: "poddle://signed-in?convexAuthCode=abc")!, state: state)
        #expect(account.userId == "user-1")
    }

    @Test func refreshesOnceWhenTheTokenIsAboutToExpire() async throws {
        let server = FakeAuthServer()
        server.expiresIn = 1_000 // inside the 5 s window
        let account = Account(config: config, store: MemorySessionStore(), http: server)
        try await account.signInForTesting(email: nil)
        async let a = account.accessToken(forceRefresh: false)
        async let b = account.accessToken(forceRefresh: false)
        let tokens = await [a, b]
        #expect(server.refreshes == 1)
        #expect(tokens == ["access-1", "access-1"])
        server.expiresIn = 60_000
        #expect(await account.accessToken(forceRefresh: true) == "access-2")
        #expect(await account.accessToken(forceRefresh: false) == "access-2")
    }

    @Test func offlineKeepsTheSessionAndAnEndedOneSignsOut() async throws {
        let server = FakeAuthServer()
        let account = Account(config: config, store: MemorySessionStore(), http: server)
        try await account.signInForTesting(email: nil)
        server.offline = true
        #expect(await account.accessToken(forceRefresh: true) == "access-0")
        #expect(account.isSignedIn)
        server.offline = false
        server.revoked = true
        #expect(await account.accessToken(forceRefresh: true) == nil)
        #expect(!account.isSignedIn)
    }

    @Test func signOutClearsLocallyAndTellsTheServer() async throws {
        let server = FakeAuthServer()
        let store = MemorySessionStore()
        let account = Account(config: config, store: store, http: server)
        try await account.signInForTesting(email: nil)
        await account.signOut()
        #expect(!account.isSignedIn)
        #expect(store.load() == nil)
        #expect(server.calls.last == "auth:signOut")
    }
}
