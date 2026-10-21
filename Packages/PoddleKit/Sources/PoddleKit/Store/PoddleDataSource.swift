import Foundation

/// The backend behind `PoddleStore`. `MockStore` is in-memory sample data, `LiveStore` will talk
/// to Convex. The store applies mutations to its local copy straight away and sends them here in
/// order (the outbox), and the data source pushes fresh snapshots back.
public protocol PoddleDataSource: Sendable {
    /// Pushes a new snapshot whenever the synced state changes on the server.
    func snapshots() async -> AsyncStream<LibrarySnapshot>
    func send(_ mutation: Mutation) async throws

    func stats(year: Int) async throws -> StatsSummary
    func availableYears() async throws -> [Int]
    func yearInReview(year: Int) async throws -> YearInReview

    /// Apple Podcasts directory search.
    func search(_ term: String) async throws -> SearchResponse
    /// Resolves a pasted URL (RSS, podcasts.apple.com, overcast.fm, or a website) to a show.
    func resolve(url: String) async throws -> SearchResult?

    /// Uploads an Overcast "All data" OPML export and streams progress as the backend matches it.
    func importOvercast(fileName: String, data: Data, assumedSpeed: Double) async -> AsyncThrowingStream<ImportProgress, Error>

    /// Chapters for an episode (JSON chapters first, then embedded). Local only.
    func chapters(for episode: Episode) async -> [Chapter]
}
