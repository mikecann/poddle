import Foundation

/// An episode with everything a row needs: its show, user state, queue status, effective speed
/// and download.
public struct EpisodeItem: Sendable, Hashable, Identifiable {
    public var episode: Episode
    public var podcast: Podcast
    public var state: EpisodeState
    public var isQueued: Bool
    public var speed: Resolved<Double>
    public var download: Download?

    public var id: String { episode.id }
    public var duration: Double { episode.duration ?? 0 }
    public var position: Double { state.played ? 0 : min(state.position, duration) }
    public var remaining: Double { max(0, duration - position) }
    /// Time left on the clock at this show's speed.
    public var wallRemaining: Double { remaining / speed.value }
    public var progress: Double { duration > 0 ? position / duration : 0 }
    public var isInProgress: Bool { !state.played && state.position > 1 }
    public var isNew: Bool { state.inboxAt != nil && !state.played && !isInProgress }
    public var isDownloaded: Bool { download?.state == .done }
    public var isDownloading: Bool { download?.state == .downloading || download?.state == .queued || isWaitingForWifi }
    public var isWaitingForWifi: Bool { download?.state == .waitingForWifi }
    public var isStarred: Bool { state.starredAt != nil }

    /// "1h 8m left" for something started, "1h 14m" otherwise: the episode's real length, not sped up.
    /// Episode rows show this with no speed (Mike, 27 Oct 2026); Up Next's sped-up total sits at the end
    /// of the list, and Now Playing keeps "52m left at 1.4×".
    public var lengthLabel: String {
        isInProgress ? "\(Format.duration(remaining)) left" : Format.duration(remaining)
    }
}
