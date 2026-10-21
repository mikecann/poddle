import Foundation

public struct SegmentContext: Sendable, Equatable {
    public var episodeID: String
    public var rate: Double
    public var smartSpeed: Bool
    public var voiceBoost: Bool
    public var route: AudioRoute

    public init(episodeID: String, rate: Double, smartSpeed: Bool, voiceBoost: Bool, route: AudioRoute) {
        self.episodeID = episodeID
        self.rate = rate
        self.smartSpeed = smartSpeed
        self.voiceBoost = voiceBoost
        self.route = route
    }
}

/// Turns playback events into listening segments for stats. Pure logic; the engine feeds it.
///
/// A segment opens on play and closes on pause/stop, episode end, a context change (rate, route,
/// Smart Speed or Voice Boost) or a seek over 30 s. While open it's re-emitted every 30 s as a
/// checkpoint with the same id and `isFinal == false`.
public struct ListeningSegmentRecorder: Sendable {
    public static let checkpointInterval = 30.0
    public static let seekSplitThreshold = 30.0
    /// Segments shorter than this (wall clock) are dropped.
    public static let minimumDuration = 1.0

    public private(set) var open: ListeningSegment?
    private var removedAtOpen = 0.0
    private var lastCheckpointWall = 0.0

    public init() {}

    public var isOpen: Bool { open != nil }

    /// - Parameters: `wall` in ms since the epoch; `removedTotal` is a running Smart Speed total in content seconds.
    public mutating func begin(wall: Double, content: Double, removedTotal: Double, context: SegmentContext) {
        open = ListeningSegment(
            id: UUID(), episodeID: context.episodeID, wallStart: wall, wallEnd: wall,
            contentStart: content, contentEnd: content, rate: context.rate, smartSpeed: context.smartSpeed,
            smartRemovedContent: 0, voiceBoost: context.voiceBoost, route: context.route, isFinal: false)
        removedAtOpen = removedTotal
        lastCheckpointWall = wall
    }

    /// Call regularly while playing. Returns a checkpoint every 30 s.
    public mutating func tick(wall: Double, content: Double, removedTotal: Double) -> ListeningSegment? {
        guard var segment = open else { return nil }
        update(&segment, wall: wall, content: content, removedTotal: removedTotal)
        open = segment
        guard wall - lastCheckpointWall >= Self.checkpointInterval * 1_000 else { return nil }
        lastCheckpointWall = wall
        return segment
    }

    /// Closes the open segment and returns it, final.
    public mutating func end(wall: Double, content: Double, removedTotal: Double) -> ListeningSegment? {
        guard var segment = open else { return nil }
        open = nil
        update(&segment, wall: wall, content: content, removedTotal: removedTotal)
        segment.isFinal = true
        return segment.wallEnd - segment.wallStart >= Self.minimumDuration * 1_000 ? segment : nil
    }

    /// Closes the open segment and opens a new one with a different context.
    public mutating func split(wall: Double, content: Double, removedTotal: Double, context: SegmentContext) -> ListeningSegment? {
        guard open != nil else { return nil }
        let closed = end(wall: wall, content: content, removedTotal: removedTotal)
        begin(wall: wall, content: content, removedTotal: removedTotal, context: context)
        return closed
    }

    /// A seek of more than 30 s closes the segment at `from` and opens one at `to`.
    public mutating func seek(from: Double, to: Double, wall: Double, removedTotal: Double) -> ListeningSegment? {
        guard let segment = open, abs(to - from) > Self.seekSplitThreshold else { return nil }
        let context = SegmentContext(
            episodeID: segment.episodeID, rate: segment.rate, smartSpeed: segment.smartSpeed,
            voiceBoost: segment.voiceBoost, route: segment.route)
        let closed = end(wall: wall, content: from, removedTotal: removedTotal)
        begin(wall: wall, content: to, removedTotal: removedTotal, context: context)
        return closed
    }

    private func update(_ segment: inout ListeningSegment, wall: Double, content: Double, removedTotal: Double) {
        segment.wallEnd = wall
        segment.contentEnd = content
        segment.smartRemovedContent = max(0, removedTotal - removedAtOpen)
    }
}
