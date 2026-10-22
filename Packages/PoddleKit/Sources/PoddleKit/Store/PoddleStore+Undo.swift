import Foundation

/// How some episodes stood before a destructive action (archive, mark played, remove from Up Next,
/// unsubscribe, clear the queue…), so the Undo toast can put them back where they were.
public struct RestorePoint: Sendable, Hashable {
    /// Each episode's state beforehand.
    public let states: [String: EpisodeState]
    /// The whole queue's order beforehand, so removed items go back between the same neighbours.
    public let queue: [String]
}

extension PoddleStore {
    // MARK: - Undo

    /// Remembers these episodes' state and the queue order, before changing them.
    public func restorePoint(_ episodeIds: some Sequence<String>) -> RestorePoint {
        RestorePoint(
            states: Dictionary(episodeIds.map { ($0, snapshot.state($0)) }, uniquingKeysWith: { a, _ in a }),
            queue: snapshot.queue.map(\.episodeId)
        )
    }

    /// Every episode of a show (for unsubscribe and "mark all played").
    public func restorePoint(podcastId: String) -> RestorePoint {
        restorePoint(snapshot.episodes.values.filter { $0.podcastId == podcastId }.map(\.id))
    }

    /// Everything in the queue (for "clear queue").
    public func queueRestorePoint() -> RestorePoint { restorePoint(snapshot.queue.map(\.episodeId)) }

    /// Puts episodes back the way `point` found them: archived and played flags, the listening
    /// position, and their place in Up Next (between the nearest neighbours that are still queued).
    /// Uses the ordinary mutations, so it syncs like any other edit.
    public func restore(_ point: RestorePoint) {
        for (id, old) in point.states.sorted(by: { $0.key < $1.key }) {
            let current = snapshot.state(id)
            if old.archived != current.archived { perform(.setArchived(episodeId: id, old.archived)) }
            if old.played != current.played { perform(.setPlayed(episodeId: id, old.played)) }
            if !old.played, abs(old.position - snapshot.state(id).position) > 0.5 {
                perform(.savePosition(episodeId: id, position: old.position, device: old.positionDevice ?? deviceId))
            }
        }
        for (index, id) in point.queue.enumerated() where point.states[id] != nil && !snapshot.isQueued(id) {
            reinsert(id, at: index, in: point.queue)
        }
    }

    /// Queues an episode again at the place it had in `order`: straight after the nearest earlier
    /// item that's still queued and before the nearest later one.
    public func reinsert(_ episodeId: String, at index: Int, in order: [String]) {
        let present = Set(snapshot.queue.map(\.episodeId))
        let after = order[..<min(index, order.count)].last { present.contains($0) }
        let before = index + 1 < order.count ? order[(index + 1)...].first { present.contains($0) } : nil
        perform(.enqueue(episodeId: episodeId, position: .last))
        if before != nil { perform(.moveQueueItem(episodeId: episodeId, after: after, before: before)) }
    }

    /// Undo for unsubscribe: follow the show again, with the same privacy.
    public func resubscribe(_ podcastId: String) {
        guard let p = podcast(podcastId) else { return }
        perform(.subscribe(SubscribeRequest(
            feedURL: p.feedURL, title: p.title, author: p.author, appleId: p.appleId, artworkURL: p.artworkURL, isPrivate: p.isPrivate)))
    }

    // MARK: - Delayed download removal

    /// Hides a download straight away but keeps the file until `commitDownloadRemoval`, so undoing
    /// costs nothing.
    public func removeDownloadLater(_ episodeId: String) { pendingDownloadRemovals.insert(episodeId) }

    /// Undo: the download comes back as it was.
    public func cancelDownloadRemoval(_ episodeId: String) { pendingDownloadRemovals.remove(episodeId) }

    /// The toast expired: delete the file (or cancel the download) for real.
    public func commitDownloadRemoval(_ episodeId: String) {
        guard pendingDownloadRemovals.remove(episodeId) != nil else { return }
        removeDownload(episodeId)
    }

    // MARK: - "Customize for <show>"

    /// The Now Playing settings page's toggle (decisions.md): on when the show has its own value
    /// for any playback setting.
    public func customizesPlayback(_ podcastId: String) -> Bool { settings(for: podcastId).hasPlaybackOverrides }

    /// On: the show takes its own copy of every playback setting, starting from what it uses now.
    /// Off: those go back to "Use default". Other per-show settings are left alone.
    public func setCustomizesPlayback(_ podcastId: String, _ on: Bool) {
        let r = resolved(podcastId)
        updateSettings(podcastId) { s in
            if on {
                s.speed = r.speed.value
                s.smartSpeed = r.smartSpeed.value
                s.voiceBoost = r.voiceBoost.value
                s.timePitch = r.timePitch.value
                s.skipIntro = r.skipIntro.value
                s.skipOutro = r.skipOutro.value
            } else {
                s.clearPlaybackOverrides()
            }
        }
    }

    /// Where an edit on the settings page goes: the show when it's customized, otherwise the defaults.
    public func editPlayback(_ podcastId: String, show: (inout PodcastSettings) -> Void, global: (inout GlobalSettings) -> Void) {
        if customizesPlayback(podcastId) { updateSettings(podcastId, show) } else { updateGlobal(global) }
    }

    /// The speed for the Now Playing page, following the customize toggle.
    public func setPlaybackSpeed(_ value: Double, podcastId: String) {
        setSpeed(value, scope: customizesPlayback(podcastId) ? .show(podcastId) : .allPodcasts)
    }
}

extension PodcastSettings {
    /// Speed, Smart Speed, Voice Boost, speed-up method, skip intro and skip outro: what the
    /// Now Playing settings page covers.
    public var hasPlaybackOverrides: Bool {
        speed != nil || smartSpeed != nil || voiceBoost != nil || timePitch != nil || skipIntro != nil || skipOutro != nil
    }

    public mutating func clearPlaybackOverrides() {
        speed = nil; smartSpeed = nil; voiceBoost = nil; timePitch = nil; skipIntro = nil; skipOutro = nil
    }
}
