import Foundation

/// A downloaded file, with what the cleanup rules need to know about its episode.
public struct DownloadedFile: Sendable, Hashable {
    public var episodeId: String
    public var podcastId: String
    public var bytes: Int64
    public var pubDate: Millis
    /// When it was marked played, if it has been.
    public var playedAt: Millis?

    public init(episodeId: String, podcastId: String, bytes: Int64, pubDate: Millis, playedAt: Millis? = nil) {
        self.episodeId = episodeId; self.podcastId = podcastId; self.bytes = bytes
        self.pubDate = pubDate; self.playedAt = playedAt
    }
}

/// Which episodes to download and which files to delete. Pure, so it's tested without a network.
public enum DownloadPlanner {
    /// Up Next items never deleted to meet the storage cap.
    public static let protectedQueueCount = 3
    /// How recent a priority show's episode has to be to count as new.
    public static let newEpisodeWindow: TimeInterval = 7 * 86_400

    // MARK: Auto-download

    public struct Candidate: Sendable, Hashable {
        public var episodeId: String
        public var podcastId: String
        public var pubDate: Millis
        public var played: Bool
        public var archived: Bool
        public var hasEnclosure: Bool

        public init(episodeId: String, podcastId: String, pubDate: Millis, played: Bool = false, archived: Bool = false, hasEnclosure: Bool = true) {
            self.episodeId = episodeId; self.podcastId = podcastId; self.pubDate = pubDate
            self.played = played; self.archived = archived; self.hasEnclosure = hasEnclosure
        }
    }

    /// The first `upNextCount` Up Next items, then new episodes from priority shows (the show's
    /// newest `keepLatest`, published in the last week). Only shows with auto-download on.
    public static func autoDownloads(
        queue: [Candidate], episodes: [Candidate], upNextCount: Int = 10,
        autoDownload: (String) -> Bool, isPriority: (String) -> Bool, keepLatest: (String) -> Int, now: Millis
    ) -> [String] {
        var wanted: [String] = []
        var seen = Set<String>()
        func add(_ c: Candidate) {
            guard c.hasEnclosure, !seen.contains(c.episodeId) else { return }
            seen.insert(c.episodeId)
            wanted.append(c.episodeId)
        }
        for c in queue.prefix(upNextCount) where autoDownload(c.podcastId) { add(c) }

        let cutoff = now - newEpisodeWindow * 1000
        let fresh = episodes.filter { c in
            c.hasEnclosure && !c.played && !c.archived && c.pubDate >= cutoff && isPriority(c.podcastId) && autoDownload(c.podcastId)
        }
        for (podcastId, eps) in Dictionary(grouping: fresh, by: \.podcastId).sorted(by: { $0.key < $1.key }) {
            for c in eps.sorted(by: { $0.pubDate > $1.pubDate }).prefix(max(0, keepLatest(podcastId))) { add(c) }
        }
        return wanted
    }

    // MARK: Cleanup

    /// Files to delete, in the order the rules pick them:
    /// 1. Played episodes, `deletePlayedAfter` seconds after they were played (nil = never).
    /// 2. Per show, everything beyond its `keepLatest` newest. Up Next items don't count and are kept.
    /// 3. If still over `capBytes`: files not in Up Next (played first, then oldest), then Up Next
    ///    from the bottom. The top `protectedQueueCount` items and whatever's playing are never deleted.
    public static func filesToDelete(
        files: [DownloadedFile], queue: [String], playing: String?, keepLatest: (String) -> Int,
        deletePlayedAfter: TimeInterval?, capBytes: Int64, now: Millis
    ) -> [String] {
        let queuePosition = Dictionary(queue.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func isKept(_ f: DownloadedFile) -> Bool { f.episodeId == playing }
        var doomed: [String] = []
        var doomedSet = Set<String>()
        func delete(_ f: DownloadedFile) {
            guard !doomedSet.contains(f.episodeId), !isKept(f) else { return }
            doomedSet.insert(f.episodeId)
            doomed.append(f.episodeId)
        }

        if let after = deletePlayedAfter {
            for f in files where queuePosition[f.episodeId] == nil {
                if let playedAt = f.playedAt, now - playedAt >= after * 1000 { delete(f) }
            }
        }

        let loose = files.filter { queuePosition[$0.episodeId] == nil && !doomedSet.contains($0.episodeId) }
        for (podcastId, showFiles) in Dictionary(grouping: loose, by: \.podcastId) {
            for f in showFiles.sorted(by: { $0.pubDate > $1.pubDate }).dropFirst(max(0, keepLatest(podcastId))) { delete(f) }
        }

        var used = files.filter { !doomedSet.contains($0.episodeId) }.reduce(Int64(0)) { $0 + $1.bytes }
        guard used > capBytes else { return doomed }
        let notQueued = files
            .filter { queuePosition[$0.episodeId] == nil && !doomedSet.contains($0.episodeId) }
            .sorted { a, b in
                if (a.playedAt != nil) != (b.playedAt != nil) { return a.playedAt != nil }
                return a.pubDate < b.pubDate
            }
        let queuedFromBottom = files
            .filter { (queuePosition[$0.episodeId] ?? 0) >= protectedQueueCount }
            .sorted { queuePosition[$0.episodeId]! > queuePosition[$1.episodeId]! }
        for f in notQueued + queuedFromBottom where used > capBytes && !isKept(f) {
            delete(f)
            used -= f.bytes
        }
        return doomed
    }
}

extension DeletePlayed {
    /// Seconds after playing that the file goes. Nil = keep.
    public var interval: TimeInterval? {
        switch self {
        case .immediately: 0
        case .after24h: 86_400
        case .afterWeek: 7 * 86_400
        case .never: nil
        }
    }
}
