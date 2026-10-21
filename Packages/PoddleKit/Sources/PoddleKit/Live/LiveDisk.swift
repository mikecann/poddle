import Foundation

/// One backend call an outbox entry still has to make. `args` never holds the token; it's added
/// at send time so a token change doesn't strand queued work.
public struct OutboxCall: Codable, Sendable, Hashable {
    public var name: String
    public var args: [String: JSONValue]
    /// Fill this arg with the previous call's result (the new podcast ID for `setPrivate`).
    public var resultArg: String?

    public init(_ name: String, _ args: [String: JSONValue], resultArg: String? = nil) {
        self.name = name; self.args = args; self.resultArg = resultArg
    }
}

/// A user action waiting for the server. `at` is when the user did it and is never re-stamped,
/// so replays stay last-writer-wins correct.
public struct OutboxEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var mutation: Mutation
    public var at: Millis
    public var calls: [OutboxCall]
    /// How many of `calls` the server has accepted.
    public var done: Int = 0
    public var lastResult: JSONValue?
    public var attempts: Int = 0
    public var error: String?

    public init(id: UUID = UUID(), mutation: Mutation, at: Millis, calls: [OutboxCall]) {
        self.id = id; self.mutation = mutation; self.at = at; self.calls = calls
    }
}

/// Everything LiveStore keeps on disk for one deployment: the last synced state (so the app opens
/// instantly and works offline), the `sync:changes` cursors and the last stats it saw.
public struct LiveCache: Codable, Sendable, Hashable {
    public var snapshot = LibrarySnapshot()
    /// `since` per synced table.
    public var since: [String: Millis] = [:]
    /// Device time of the last finished catch-up.
    public var syncedAt: Millis?
    public var stats: [String: StatsSummary] = [:]
    public var years: [Int] = []
    public var yearInReview: [String: YearInReview] = [:]

    public init() {}
}

/// The outbox file: queued actions in order, plus ones the server rejected outright. Rejected
/// ones are kept (never silently dropped) until they're retried or discarded.
public struct OutboxFile: Codable, Sendable, Hashable {
    public var pending: [OutboxEntry] = []
    public var failed: [OutboxEntry] = []
    public init(pending: [OutboxEntry] = [], failed: [OutboxEntry] = []) { self.pending = pending; self.failed = failed }
}

/// JSON files under Application Support/Poddle/<deployment>/.
public struct LiveDisk: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The default folder for a deployment, e.g. `…/Application Support/Poddle/qualified-hedgehog-912`.
    public static func forDeployment(_ url: URL) -> LiveDisk {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = url.host()?.split(separator: ".").first.map(String.init) ?? "default"
        return LiveDisk(directory: base.appending(path: "Poddle", directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory))
    }

    var cacheURL: URL { directory.appending(path: "cache.json") }
    var outboxURL: URL { directory.appending(path: "outbox.json") }

    public func loadCache() -> LiveCache? { load(LiveCache.self, from: cacheURL) }
    public func loadOutbox() -> OutboxFile { load(OutboxFile.self, from: outboxURL) ?? OutboxFile() }

    public func save(_ cache: LiveCache) throws { try write(cache, to: cacheURL) }
    public func save(_ outbox: OutboxFile) throws { try write(outbox, to: outboxURL) }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }

    public func erase() { try? FileManager.default.removeItem(at: directory) }
}
