import Foundation
import ConvexMobile

/// What `LiveStore` needs from Convex, as raw JSON. The real one wraps convex-swift; tests use a
/// fake. Calls are made as whoever `setAuth` was given (Convex Auth's access token).
public protocol ConvexTransport: Sendable {
    /// Who to call as. The client asks the source for a token when it connects, and again with
    /// `forceRefresh` when the server refuses one. Nil: not signed in.
    func setAuth(_ source: (any AuthTokenSource)?) async
    func query(_ name: String, _ args: [String: JSONValue]) async throws -> Data
    func mutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data
    func action(_ name: String, _ args: [String: JSONValue]) async throws -> Data
    /// A live query. Yields the new result every time it changes and finishes with an error if
    /// the function throws.
    func subscribe(_ name: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<Data, Error>
    /// `true` while the WebSocket is connected.
    func connectionStates() -> AsyncStream<Bool>
    /// POSTs a file to a Convex storage upload URL and returns the response body.
    func upload(to url: URL, data: Data, contentType: String) async throws -> Data
}

public enum TransportError: Error, Sendable, Hashable, LocalizedError {
    /// Not signed in, or the session has run out (`unauthenticated`), or an admin token was
    /// refused (`unauthorized` / `unconfigured`). Retried once a session is back.
    case unauthorized(String)
    /// The function threw. Retrying the same call won't help.
    case server(String)
    /// Couldn't reach the deployment. Retry later.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .unauthorized(m): "Not authorised: \(m)"
        case let .server(m): m
        case let .network(m): "Network: \(m)"
        }
    }

    public var isRetryable: Bool { if case .server = self { false } else { true } }
}

/// The real transport, over convex-swift's Rust client. It talks to the UniFFI layer directly so
/// results stay raw JSON (the Swift wrapper only hands back `Decodable` values) and so one-shot
/// queries are available.
public final class ConvexMobileTransport: ConvexTransport, @unchecked Sendable {
    private let client: MobileConvexClient
    private let socket = SocketWatcher()

    public init(deploymentURL: URL) {
        client = MobileConvexClient(
            deploymentUrl: deploymentURL.absoluteString, clientId: "poddle-swift", webSocketStateSubscriber: socket
        )
    }

    public func setAuth(_ source: (any AuthTokenSource)?) async {
        try? await client.setAuthCallback(provider: source.map(TokenBridge.init))
    }

    /// convex-swift's pull-style token callback, backed by `Account`.
    private final class TokenBridge: AuthTokenProvider, @unchecked Sendable {
        let source: any AuthTokenSource
        init(_ source: any AuthTokenSource) { self.source = source }
        func fetchToken(forceRefresh: Bool) async throws -> String? { await source.accessToken(forceRefresh: forceRefresh) }
    }

    private static func encode(_ args: [String: JSONValue]) -> [String: String] {
        args.mapValues(\.jsonString)
    }

    public func query(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        try await call { try await client.query(name: name, args: Self.encode(args)) }
    }

    public func mutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        try await call { try await client.mutation(name: name, args: Self.encode(args)) }
    }

    public func action(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        try await call { try await client.action(name: name, args: Self.encode(args)) }
    }

    private func call(_ body: () async throws -> String) async throws -> Data {
        do { return Data(try await body().utf8) } catch { throw Self.map(error) }
    }

    public func subscribe(_ name: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let subscriber = Subscriber(continuation)
        let client = client
        let encoded = Self.encode(args)
        let task = Task {
            do {
                let handle = try await client.subscribe(name: name, args: encoded, subscriber: subscriber)
                subscriber.attach(handle)
            } catch {
                continuation.finish(throwing: Self.map(error))
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            subscriber.cancel()
        }
        return stream
    }

    public func connectionStates() -> AsyncStream<Bool> { socket.stream() }

    public func upload(to url: URL, data: Data, contentType: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (body, response) = try await URLSession.shared.upload(for: request, from: data)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw TransportError.server("Upload failed (\(http.statusCode))")
            }
            return body
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.network(error.localizedDescription)
        }
    }

    static func map(_ error: Error) -> TransportError {
        guard let e = error as? ClientError else { return .network(error.localizedDescription) }
        switch e {
        case let .ConvexError(data):
            let value = try? JSONValue.decode(Data(data.utf8))
            let code = value?["code"]?.string
            let message = value?["message"]?.string ?? data
            return ["unauthenticated", "unauthorized", "unconfigured"].contains(code ?? "") ? .unauthorized(message) : .server(message)
        case let .ServerError(msg): return .server(msg)
        case let .InternalError(msg): return .network(msg)
        }
    }

    private final class Subscriber: QuerySubscriber, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private let lock = NSLock()
        private var handle: SubscriptionHandle?
        private var cancelled = false

        init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

        func attach(_ handle: SubscriptionHandle) {
            lock.lock()
            let wasCancelled = cancelled
            if !wasCancelled { self.handle = handle }
            lock.unlock()
            if wasCancelled { handle.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let h = handle
            handle = nil
            lock.unlock()
            h?.cancel()
        }

        func onUpdate(value: String) { continuation.yield(Data(value.utf8)) }

        func onError(message: String, value: String?) {
            let error: ClientError = value.map { .ConvexError(data: $0) } ?? .ServerError(msg: message)
            continuation.finish(throwing: ConvexMobileTransport.map(error))
        }
    }

    private final class SocketWatcher: WebSocketStateSubscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var connected = false
        private var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]

        func onStateChange(state: WebSocketState) {
            lock.lock()
            connected = state == .connected
            let value = connected
            let all = Array(listeners.values)
            lock.unlock()
            for l in all { l.yield(value) }
        }

        func stream() -> AsyncStream<Bool> {
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            lock.lock()
            listeners[id] = continuation
            let value = connected
            lock.unlock()
            continuation.yield(value)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.listeners[id] = nil
                self.lock.unlock()
            }
            return stream
        }
    }
}
