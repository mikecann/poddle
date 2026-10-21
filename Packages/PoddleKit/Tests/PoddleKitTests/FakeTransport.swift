import Foundation
@testable import PoddleKit

/// A scriptable stand-in for Convex: records every call, can go offline, can reject functions,
/// and lets a test push live-query results.
final class FakeTransport: ConvexTransport, @unchecked Sendable {
    struct Call: Sendable, Hashable { var name: String; var args: [String: JSONValue] }

    private let lock = NSLock()
    private var _online = true
    private var _rejects: Set<String> = []
    private var _failNext = 0
    private var _mutations: [Call] = []
    private var _queries: [Call] = []
    private var _actions: [Call] = []
    private var subscribers: [String: [AsyncThrowingStream<Data, Error>.Continuation]] = [:]
    private var latest: [String: Data] = [:]
    private var connection: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Answers queries and actions. Defaults to an empty `sync:changes` page.
    var respond: @Sendable (String, [String: JSONValue]) -> Data = { name, _ in
        name == "sync:changes" ? Data(#"{"page":[],"isDone":true,"continueCursor":"","maxUpdatedAt":null}"#.utf8) : Data("null".utf8)
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var online: Bool {
        get { locked { _online } }
        set {
            let all = locked { _online = newValue; return Array(connection.values) }
            for c in all { c.yield(newValue) }
        }
    }
    var rejects: Set<String> { get { locked { _rejects } } set { locked { _rejects = newValue } } }
    /// Fail this many upcoming mutations with a network error, then succeed.
    var failNext: Int { get { locked { _failNext } } set { locked { _failNext = newValue } } }
    var mutations: [Call] { locked { _mutations } }
    var queries: [Call] { locked { _queries } }
    var actions: [Call] { locked { _actions } }

    func query(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        guard online else { throw TransportError.network("offline") }
        locked { _queries.append(Call(name: name, args: args)) }
        return respond(name, args)
    }

    func mutation(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        let outcome: TransportError? = locked {
            if !_online { return .network("offline") }
            if _failNext > 0 { _failNext -= 1; return .network("flaky") }
            if _rejects.contains(name) { return .server("\(name) rejected") }
            _mutations.append(Call(name: name, args: args))
            return nil
        }
        if let outcome { throw outcome }
        return name == "podcasts:subscribe" ? Data(#""pod_new""#.utf8) : Data("true".utf8)
    }

    func action(_ name: String, _ args: [String: JSONValue]) async throws -> Data {
        guard online else { throw TransportError.network("offline") }
        locked { _actions.append(Call(name: name, args: args)) }
        return respond(name, args)
    }

    func subscribe(_ name: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let last = locked { subscribers[name, default: []].append(continuation); return latest[name] }
        if let last { continuation.yield(last) }
        return stream
    }

    /// Sends a new result to every subscriber of `name` (and to later ones).
    func push(_ name: String, _ json: String) {
        let data = Data(json.utf8)
        let subs = locked { latest[name] = data; return subscribers[name] ?? [] }
        for s in subs { s.yield(data) }
    }

    func connectionStates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        let up = locked { connection[UUID()] = continuation; return _online }
        continuation.yield(up)
        return stream
    }

    func upload(to url: URL, data: Data, contentType: String) async throws -> Data {
        Data(#"{"storageId":"kg_1"}"#.utf8)
    }
}

/// A clock that ticks one second each time it's read, so every action gets its own `at`.
final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(start: TimeInterval = 1_790_000_000) { t = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; t += 1; return Date(timeIntervalSince1970: t) }
}

/// Polls until `condition` holds (or two seconds pass).
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

func tempDisk() -> LiveDisk {
    LiveDisk(directory: FileManager.default.temporaryDirectory.appending(path: "poddle-tests-\(UUID().uuidString)"))
}
