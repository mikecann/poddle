#if canImport(ChefKit)
import ChefKit
import Combine
import Foundation
import PoddleKit

/// Lets Chef (Seth's feedback board, `ChefKit`) talk to Convex through Poddle's own connection
/// and sign-in (`LiveStore`), so there's no second client to keep signed in. iOS only: ChefKit
/// doesn't build for the Mac.
nonisolated final class ChefConnection: ChefBackend {
    private let live: LiveStore

    /// How long a live query that dropped (offline, signed out, a new account) waits to ask again.
    static let retryAfter = Duration.seconds(4)

    init(live: LiveStore) {
        self.live = live
    }

    func chefMutation<T: Decodable & Sendable>(_ name: String, args: [String: ChefValue]) async throws -> T {
        let data = try await live.rawMutation(name, args.mapValues(\.json))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func chefSubscribe<T: Decodable & Sendable>(_ name: String, args: [String: ChefValue], as type: T.Type)
        -> AnyPublisher<T, Error> {
        let subject = Box(PassthroughSubject<T, Error>())
        let task = Self.pump(live: live, name: name, args: args.mapValues(\.json)) { data in
            // A result Chef can't read is skipped, like a miss.
            if let value = try? JSONDecoder().decode(T.self, from: data) { subject.value.send(value) }
        }
        return subject.value
            .handleEvents(receiveCancel: { task.cancel() })
            .eraseToAnyPublisher()
    }

    /// Keeps a live query running until cancelled, asking again after a drop. Kept non-generic and
    /// out of `chefSubscribe`: Swift 6.3's region-based isolation checker (tinker-desk's Xcode 26.6)
    /// can't check a generic task closure that awaits the store.
    private static func pump(live: LiveStore, name: String, args: [String: JSONValue],
                             onData: @escaping @Sendable (Data) -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    for try await data in await live.rawSubscribe(name, args) { onData(data) }
                } catch {
                    // Dropped or refused: ask again in a moment.
                }
                try? await Task.sleep(for: retryAfter)
            }
        }
    }

    /// Only ever sent to from the subscription's task, one value at a time.
    private struct Box<V>: @unchecked Sendable {
        let value: V
        init(_ value: V) { self.value = value }
    }
}

private extension ChefValue {
    nonisolated var json: JSONValue {
        switch self {
        case let .string(s): .string(s)
        case let .number(n): .number(n)
        case let .bool(b): .bool(b)
        case let .array(a): .array(a.map(\.json))
        case let .object(o): .object(o.mapValues(\.json))
        case .null: .null
        }
    }
}
#endif
