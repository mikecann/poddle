import Foundation
import Observation

/// Session tokens from Convex Auth, plus who they belong to.
public struct AuthSession: Codable, Sendable, Hashable {
    public var accessToken: String
    /// Milliseconds since 1970, as Convex Auth sends them.
    public var accessTokenExpiresAt: Double
    public var refreshToken: String
    public var refreshTokenExpiresAt: Double
    public var userId: String
    public var name: String?
    public var email: String?
    /// Their Google photo. Apple doesn't give one.
    public var picture: String?

    public init(accessToken: String, accessTokenExpiresAt: Double, refreshToken: String, refreshTokenExpiresAt: Double,
                userId: String, name: String? = nil, email: String? = nil, picture: String? = nil) {
        self.accessToken = accessToken; self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken; self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.userId = userId; self.name = name; self.email = email; self.picture = picture
    }
}

/// Hands the Convex client a fresh access token. `Account` is the real one.
public protocol AuthTokenSource: AnyObject, Sendable {
    /// The current access token, refreshed first if it's about to run out (or `forceRefresh`).
    /// Nil when signed out.
    func accessToken(forceRefresh: Bool) async -> String?
}

/// Where the session is kept between launches. The Keychain, or memory in tests.
public protocol SessionStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession)
    func delete()
}

/// The session in the Keychain, one per deployment so dev and prod never mix.
public struct KeychainSessionStore: SessionStore {
    let account: String
    static let service = "com.mikecann.poddle.session"
    public init(deployment: LiveConfig) { account = deployment.deploymentName }
    public func load() -> AuthSession? {
        Keychain.readData(service: Self.service, account: account).flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }
    public func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        Keychain.writeData(service: Self.service, account: account, data)
    }
    public func delete() { Keychain.delete(service: Self.service, account: account) }
}

public enum AccountError: Error, Sendable, Hashable, LocalizedError {
    /// Closed the sign-in sheet.
    case cancelled
    /// Not on the allowlist (`PODDLE_ALLOWED_EMAILS`).
    case inviteOnly(String)
    /// Couldn't reach the deployment.
    case network(String)
    /// The server said no, or sent something unexpected.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case let .inviteOnly(m): m
        case let .network(m): "Can't reach Poddle (\(m)). Check your connection and try again."
        case let .failed(m): m
        }
    }
}

/// Plain request/response calls to Convex's HTTP API (`/api/query`, `/api/mutation`), for
/// signing in and refreshing before the live client has a session.
public protocol ConvexHTTPCalling: Sendable {
    func call(_ kind: String, _ path: String, _ args: [String: JSONValue], token: String?) async throws -> JSONValue
}

public struct ConvexHTTP: ConvexHTTPCalling {
    public let deploymentURL: URL
    public init(deploymentURL: URL) { self.deploymentURL = deploymentURL }

    public func call(_ kind: String, _ path: String, _ args: [String: JSONValue], token: String?) async throws -> JSONValue {
        var request = URLRequest(url: deploymentURL.appending(path: "api/\(kind)"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let body: JSONValue = ["path": .string(path), "args": .object(args), "format": "json"]
        request.httpBody = Data(body.jsonString.utf8)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError.network((error as? URLError).map { "\($0.code.rawValue)" } ?? error.localizedDescription)
        }
        guard let envelope = try? JSONValue.decode(data) else { throw AccountError.failed("The server sent something unexpected.") }
        if envelope["status"]?.string == "success" { return envelope["value"] ?? .null }
        let code = envelope["errorData"]?["code"]?.string
        let message = envelope["errorData"]?["message"]?.string ?? envelope["errorData"]?.string ?? envelope["errorMessage"]?.string
            ?? "Something went wrong signing in. Try again."
        throw code == "inviteOnly" ? AccountError.inviteOnly(message) : AccountError.failed(message)
    }
}

/// Who's signed in, with Convex Auth v2 (Apple, Google, or test sign-in on dev). Keeps the
/// session in the Keychain and refreshes the short-lived access token for the Convex client.
/// The web sign-in sheet itself is the app's job (`SignInSheet`): it gets a page from
/// `startWebSignIn` and hands the code it comes back with to `completeWebSignIn`.
@MainActor
@Observable
public final class Account: AuthTokenSource {
    public enum Provider: String, Sendable {
        case apple = "Apple"
        case google = "Google"
    }

    /// What screens show about who's signed in. Changes on sign-in and sign-out, never on a refresh.
    public struct Profile: Sendable, Hashable {
        public var userId: String
        public var name: String?
        public var email: String?
        public var picture: String?
    }

    public private(set) var profile: Profile?
    public var isSignedIn: Bool { profile != nil }
    public var userId: String? { profile?.userId }

    @ObservationIgnored public let config: LiveConfig
    @ObservationIgnored private var session: AuthSession? {
        didSet {
            let next = session.map { Profile(userId: $0.userId, name: $0.name, email: $0.email, picture: $0.picture) }
            if next != profile { profile = next }
        }
    }
    @ObservationIgnored private let store: any SessionStore
    @ObservationIgnored private let http: any ConvexHTTPCalling
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var refreshing: Task<AuthSession?, Never>?

    public init(config: LiveConfig, store: (any SessionStore)? = nil, http: (any ConvexHTTPCalling)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.store = store ?? KeychainSessionStore(deployment: config)
        self.http = http ?? ConvexHTTP(deploymentURL: config.deploymentURL)
        self.now = now
        session = self.store.load()
        profile = session.map { Profile(userId: $0.userId, name: $0.name, email: $0.email, picture: $0.picture) }
    }

    // MARK: Signing in

    /// Where the provider's sign-in page should send people back to: the deployment's own site,
    /// which bounces to poddle://signed-in (convex/http.ts).
    public var returnURL: URL { config.siteURL.appending(path: "app/signed-in") }

    /// Starts Apple or Google sign-in. Open `page` in the sheet, then pass what it lands on to
    /// `completeWebSignIn` with `state`.
    public func startWebSignIn(_ provider: Provider) async throws -> (page: URL, state: String) {
        let start = try await http.call("mutation", "auth:startSignInWith\(provider.rawValue)",
                                        ["redirectTo": .string(returnURL.absoluteString)], token: nil)
        guard let redirect = start["redirect"]?.string.flatMap(URL.init(string:)), let state = start["state"]?.string else {
            throw AccountError.failed("Something went wrong signing in. Try again.")
        }
        return (redirect, state)
    }

    /// Finishes sign-in with the URL the sheet came back on (`poddle://signed-in?convexAuthCode=…`).
    public func completeWebSignIn(_ provider: Provider, landedOn url: URL, state: String) async throws {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "convexAuthError" })?.value {
            throw error == "access_denied" ? AccountError.cancelled : AccountError.failed("Sign-in didn't finish (\(error)). Try again.")
        }
        guard let code = query.first(where: { $0.name == "convexAuthCode" })?.value else {
            throw AccountError.failed("Sign-in didn't finish. Try again.")
        }
        let result = try await http.call("mutation", "auth:completeSignInWith\(provider.rawValue)",
                                         ["code": .string(code), "state": .string(state)], token: nil)
        try await finish(result)
    }

    /// Dev only (`PODDLE_TEST_SIGNIN=1` on the deployment): sign in as `email`, or as a fresh test
    /// user without one. The server refuses it everywhere else.
    public func signInForTesting(email: String?) async throws {
        var args: [String: JSONValue] = [:]
        if let email, !email.isEmpty { args["email"] = .string(email) }
        try await finish(try await http.call("mutation", "auth:signInForTesting", args, token: nil))
    }

    private func finish(_ result: JSONValue) async throws {
        guard result["status"]?.string == "complete", let tokens = result["tokens"],
              var next = try? JSONDecoder().decode(AuthSession.self, from: Data(tokens.jsonString.utf8)) else {
            throw AccountError.failed("Something went wrong signing in. Try again.")
        }
        // Who this is, for Settings. Not essential, so a hiccup here doesn't stop sign-in.
        if let me = try? await http.call("query", "users:me", [:], token: next.accessToken) {
            next.name = me["name"]?.string
            next.email = me["email"]?.string
            next.picture = me["picture"]?.string
        }
        save(next)
    }

    // MARK: Using the session

    public nonisolated func accessToken(forceRefresh: Bool) async -> String? {
        await token(forceRefresh: forceRefresh)
    }

    /// The access token, refreshed first if it runs out in the next few seconds. Offline, the old
    /// one comes back (the server will refuse it, and the client asks again when it reconnects).
    public func token(forceRefresh: Bool = false) async -> String? {
        guard let session else { return nil }
        let nowMs = now().timeIntervalSince1970 * 1000
        if !forceRefresh, session.accessTokenExpiresAt - nowMs > 5_000 { return session.accessToken }
        return await refreshed()?.accessToken ?? self.session?.accessToken
    }

    /// One refresh at a time: refresh tokens rotate, so two at once would trip over each other.
    private func refreshed() async -> AuthSession? {
        if let refreshing { return await refreshing.value }
        guard let current = session else { return nil }
        let http = http
        let task = Task { () -> AuthSession? in
            do {
                let result = try await http.call("mutation", "auth:refreshSession", ["refreshToken": .string(current.refreshToken)], token: nil)
                guard result["kind"]?.string == "rotated", let tokens = result["tokens"],
                      var next = try? JSONDecoder().decode(AuthSession.self, from: Data(tokens.jsonString.utf8)) else {
                    // The session's over (expired or revoked): signed out.
                    if self.session?.refreshToken == current.refreshToken { self.clear() }
                    return nil
                }
                next.name = current.name
                next.email = current.email
                next.picture = current.picture
                self.save(next)
                return next
            } catch {
                // Offline or the server's having a moment: keep the session and try later.
                return nil
            }
        }
        refreshing = task
        let result = await task.value
        refreshing = nil
        return result
    }

    /// Signed out here straight away, then the server's told (best effort).
    public func signOut() async {
        let refreshToken = session?.refreshToken
        clear()
        if let refreshToken {
            _ = try? await http.call("mutation", "auth:signOut", ["refreshToken": .string(refreshToken)], token: nil)
        }
    }

    private func save(_ next: AuthSession) {
        session = next
        store.save(next)
    }

    private func clear() {
        session = nil
        store.delete()
    }
}

/// An in-memory `SessionStore`, for tests and previews.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession?
    public init(_ value: AuthSession? = nil) { self.value = value }
    public func load() -> AuthSession? { lock.withLock { value } }
    public func save(_ session: AuthSession) { lock.withLock { value = session } }
    public func delete() { lock.withLock { value = nil } }
}
