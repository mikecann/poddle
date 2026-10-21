import Foundation
import Testing
@testable import PoddleKit

/// Records every batch, and can be told to fail.
private actor RecordingSource: PoddleDataSource {
    var batches: [[SessionInput]] = []
    var failuresLeft = 0
    var token: (String, APNsEnvironment)?

    func failNext(_ n: Int) { failuresLeft = n }

    func recordSessions(_ sessions: [SessionInput]) async throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw URLError(.notConnectedToInternet)
        }
        batches.append(sessions)
    }

    func registerDevice(apnsToken: String, environment: APNsEnvironment) async throws { token = (apnsToken, environment) }

    func snapshots() async -> AsyncStream<LibrarySnapshot> { AsyncStream { $0.finish() } }
    func send(_ mutation: Mutation) async throws {}
    func stats(year: Int) async throws -> StatsSummary { throw URLError(.unsupportedURL) }
    func availableYears() async throws -> [Int] { [] }
    func yearInReview(year: Int) async throws -> YearInReview { throw URLError(.unsupportedURL) }
    func search(_ term: String) async throws -> SearchResponse { throw URLError(.unsupportedURL) }
    func resolve(url: String) async throws -> SearchResult? { nil }
    func importOvercast(fileName: String, data: Data, assumedSpeed: Double) async -> AsyncThrowingStream<ImportProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func chapters(for episode: Episode) async -> [Chapter] { [] }
}

@MainActor
@Suite struct SessionForwarderTests {
    let start: Millis = 1_792_000_000_000
    let id = UUID()
    let sydney = TimeZone(identifier: "Australia/Sydney")!

    func checkpoint(after seconds: Double, final: Bool = false) -> ListeningCheckpoint {
        ListeningCheckpoint(
            id: id, episodeId: "ep1", wallStart: start, wallEnd: start + seconds * 1000,
            contentStart: 100, contentEnd: 100 + seconds * 1.8, rate: 1.8, smartSpeed: true,
            smartRemovedContent: seconds * 0.05, voiceBoost: true, route: "airPods", isFinal: final)
    }

    @Test func mapsToTheApiShape() {
        let f = SessionForwarder(dataSource: RecordingSource(), deviceId: "dev1", timeZone: sydney)
        let s = f.input(for: checkpoint(after: 30))
        #expect(s.sessionId == id.uuidString.lowercased())
        #expect(s.episodeId == "ep1" && s.deviceId == "dev1")
        #expect(s.startedAt == start && s.endedAt == start + 30_000)
        #expect(s.contentStart == 100 && s.contentEnd == 154)
        #expect(s.rate == 1.8 && s.smartSpeed && s.voiceBoost && s.route == "airPods")
        #expect(s.smartRemovedContent == 1.5)
        // October in Sydney is daylight time, +11 h.
        #expect(s.utcOffsetMinutes == 660)
    }

    @Test func resendsTheSameSessionWithALaterEnd() async {
        let source = RecordingSource()
        let f = SessionForwarder(dataSource: source, deviceId: "dev1", timeZone: sydney)
        f.record(checkpoint(after: 30))
        await f.flush()
        f.record(checkpoint(after: 60))
        await f.flush()
        f.record(checkpoint(after: 75, final: true))
        await f.flush()

        let batches = await source.batches
        #expect(batches.count == 3)
        #expect(Set(batches.flatMap { $0 }.map(\.sessionId)).count == 1)
        #expect(batches.map { $0[0].endedAt } == [start + 30_000, start + 60_000, start + 75_000])
        #expect(f.pending.isEmpty)

        // MockStore keeps one copy per session, the newest.
        let mock = MockStore(latency: 0)
        for b in batches.reversed() { try? await mock.recordSessions(b) }
        let kept = await mock.sessions
        #expect(kept.count == 1)
        #expect(kept.values.first?.endedAt == start + 75_000)
    }

    @Test func keepsFailedSessionsAndCoalescesThem() async {
        let source = RecordingSource()
        await source.failNext(1)
        let f = SessionForwarder(dataSource: source, deviceId: "dev1", timeZone: sydney, retryAfter: .seconds(3600))
        f.record(checkpoint(after: 30))
        await f.flush()
        #expect(f.pending.count == 1)
        #expect(f.lastError != nil)
        // A later checkpoint replaces the pending copy; an older one doesn't.
        f.record(checkpoint(after: 60))
        f.record(checkpoint(after: 45))
        await f.flush()
        let batches = await source.batches
        #expect(batches.last?.count == 1)
        #expect(batches.last?.first?.endedAt == start + 60_000)
        #expect(f.pending.isEmpty)
    }

    @Test func pendingSurvivesARelaunch() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "poddle-sessions-\(UUID().uuidString).json")
        let source = RecordingSource()
        await source.failNext(5)
        let f = SessionForwarder(dataSource: source, deviceId: "dev1", persistURL: file, retryAfter: .seconds(3600))
        f.record(checkpoint(after: 30))
        await f.flush()
        #expect(f.pending.count == 1)

        let online = RecordingSource()
        let relaunched = SessionForwarder(dataSource: online, deviceId: "dev1", persistURL: file)
        #expect(relaunched.pending.count == 1)
        await relaunched.flush()
        #expect(await online.batches.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func dropsEmptySessions() async {
        let source = RecordingSource()
        let f = SessionForwarder(dataSource: source, deviceId: "dev1")
        f.record(checkpoint(after: 0.2))
        await f.flush()
        #expect(f.pending.isEmpty)
        #expect(await source.batches.isEmpty)
    }

    @Test func mockStoreRegistersTheDevice() async throws {
        let mock = MockStore(latency: 0)
        try await mock.registerDevice(apnsToken: "abc123", environment: .sandbox)
        let token = await mock.apnsToken
        #expect(token?.token == "abc123" && token?.environment == .sandbox)
    }
}
