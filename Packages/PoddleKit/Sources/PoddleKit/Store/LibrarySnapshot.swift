import Foundation

/// Everything synced, as plain values. The live backend pushes these and the app applies
/// mutations to its local copy optimistically, so every mutation here is idempotent: applying one
/// twice (once locally, once again on top of a server snapshot) gives the same result.
public struct LibrarySnapshot: Codable, Sendable, Hashable {
    public var podcasts: [String: Podcast]
    public var episodes: [String: Episode]
    public var states: [String: EpisodeState]
    public var queue: [QueueItem]
    public var global: GlobalSettings
    public var podcastSettings: [String: PodcastSettings]
    /// The server's "Past shows" (`podcasts:pastShows`): unsubscribed shows it knows have history.
    /// Their episodes aren't synced, so the history can't be seen here. Nil until it arrives.
    public var pastShowIds: Set<String>? = nil
    /// Set once the person's own global settings have come from the server. Until then `global`
    /// is the defaults, which mustn't drive anything they'd notice (auto-downloads).
    public var settingsSynced: Bool? = nil

    public init(
        podcasts: [String: Podcast] = [:], episodes: [String: Episode] = [:], states: [String: EpisodeState] = [:],
        queue: [QueueItem] = [], global: GlobalSettings = .defaults, podcastSettings: [String: PodcastSettings] = [:]
    ) {
        self.podcasts = podcasts; self.episodes = episodes; self.states = states
        self.queue = queue.sorted { $0.orderKey < $1.orderKey }
        self.global = global; self.podcastSettings = podcastSettings
    }

    public func state(_ episodeId: String) -> EpisodeState {
        states[episodeId] ?? EpisodeState(episodeId: episodeId)
    }

    public func resolved(_ podcastId: String) -> ResolvedSettings {
        ResolvedSettings(global: global, override: podcastSettings[podcastId])
    }

    public func isQueued(_ episodeId: String) -> Bool { queue.contains { $0.episodeId == episodeId } }

    public func isInInbox(_ episodeId: String) -> Bool {
        let s = state(episodeId)
        return s.inboxAt != nil && !s.archived && !s.played && !isQueued(episodeId)
    }
}

public enum QueuePosition: String, Codable, Sendable, Hashable {
    /// Before everything, including whatever is playing. Used by "play now" and "move to top".
    case top
    /// Straight after the item that's playing (the head of the queue).
    case next
    case last
}

public enum Mutation: Codable, Sendable, Hashable {
    case enqueue(episodeId: String, position: QueuePosition)
    /// Puts an episode between two neighbours (either may be nil for an end).
    case moveQueueItem(episodeId: String, after: String?, before: String?)
    case removeFromQueue(episodeId: String)
    case clearQueue(keeping: String?)
    case setArchived(episodeId: String, Bool)
    case setPlayed(episodeId: String, Bool)
    case setStarred(episodeId: String, Bool)
    case savePosition(episodeId: String, position: Double, device: String)
    case markOlderPlayed(episodeId: String)
    case archiveOlder(episodeId: String)
    case markAllPlayed(podcastId: String)
    case subscribe(SubscribeRequest)
    case unsubscribe(podcastId: String)
    case setSpeed(Double, scope: SpeedScope)
    case updatePodcastSettings(PodcastSettings)
    case updateGlobalSettings(GlobalSettings)
    // Device-side records that ride the live outbox but don't change the library.
    /// Listening sessions for stats (`sessions:record`).
    case recordSessions([SessionInput])
    /// This device's APNs token (`devices:register`).
    case registerDevice(apnsToken: String, environment: APNsEnvironment)
}

extension LibrarySnapshot {
    /// Applies one mutation. `newId` makes IDs for things created locally before the server
    /// assigns real ones.
    public mutating func apply(_ m: Mutation, now: Millis, newId: () -> String = { UUID().uuidString }) {
        switch m {
        case let .enqueue(episodeId, position):
            enqueue(episodeId, position, now: now, newId: newId)

        case let .moveQueueItem(episodeId, after, before):
            guard let idx = queue.firstIndex(where: { $0.episodeId == episodeId }) else { return }
            var item = queue.remove(at: idx)
            let lo = after.flatMap { a in queue.first { $0.episodeId == a }?.orderKey }
            let hi = before.flatMap { b in queue.first { $0.episodeId == b }?.orderKey }
            if let lo, let hi, lo >= hi {
                queue.insert(item, at: idx) // stale neighbours, leave it alone
                return
            }
            // Already sitting between them: keep the key so re-applying is a no-op.
            if (lo.map { item.orderKey > $0 } ?? true) && (hi.map { item.orderKey < $0 } ?? true),
               neighbours(of: item.orderKey) == (after, before) {
                queue.insert(item, at: idx)
                return
            }
            item.orderKey = OrderKey.between(lo, hi)
            insertSorted(item)

        case let .removeFromQueue(episodeId):
            queue.removeAll { $0.episodeId == episodeId }

        case let .clearQueue(keeping):
            queue.removeAll { $0.episodeId != keeping }

        case let .setArchived(episodeId, archived):
            update(episodeId, now: now) {
                $0.archived = archived
                if archived { $0.inboxAt = nil }
            }
            if archived { queue.removeAll { $0.episodeId == episodeId } }

        case let .setPlayed(episodeId, played):
            setPlayed(episodeId, played, now: now)

        case let .setStarred(episodeId, starred):
            update(episodeId, now: now) {
                if starred { $0.starredAt = $0.starredAt ?? now } else { $0.starredAt = nil }
            }

        case let .savePosition(episodeId, position, device):
            update(episodeId, now: now) {
                $0.position = max(0, position)
                $0.positionUpdatedAt = now
                $0.positionDevice = device
            }

        case let .markOlderPlayed(episodeId):
            guard let ep = episodes[episodeId] else { return }
            for other in episodes.values where other.podcastId == ep.podcastId && other.pubDate < ep.pubDate {
                setPlayed(other.id, true, now: now)
            }

        case let .archiveOlder(episodeId):
            guard let ep = episodes[episodeId] else { return }
            for other in episodes.values where other.podcastId == ep.podcastId && other.pubDate < ep.pubDate {
                guard isInInbox(other.id) else { continue }
                update(other.id, now: now) { $0.archived = true; $0.inboxAt = nil }
            }

        case let .markAllPlayed(podcastId):
            for ep in episodes.values where ep.podcastId == podcastId { setPlayed(ep.id, true, now: now) }

        case let .subscribe(request):
            if let id = podcasts.values.first(where: { $0.feedURL == request.feedURL })?.id {
                var p = podcasts[id]!
                p.subscribed = true
                p.subscribedAt = p.subscribedAt ?? now
                podcasts[id] = p
            } else {
                let id = "local-" + newId()
                podcasts[id] = Podcast(
                    id: id, feedURL: request.feedURL, isPrivate: request.isPrivate,
                    title: request.title ?? URL(string: request.feedURL)?.host() ?? request.feedURL,
                    author: request.author ?? "", artworkURL: request.artworkURL, appleId: request.appleId,
                    subscribed: true, subscribedAt: now
                )
            }

        case let .unsubscribe(podcastId):
            podcasts[podcastId]?.subscribed = false
            let ids = Set(episodes.values.filter { $0.podcastId == podcastId }.map(\.id))
            queue.removeAll { ids.contains($0.episodeId) }
            for id in ids where states[id]?.inboxAt != nil { states[id]?.inboxAt = nil }

        case let .setSpeed(value, scope):
            let speed = Speed.snap(value)
            switch scope {
            case .allPodcasts: global.speed = speed
            case let .show(podcastId):
                var s = podcastSettings[podcastId] ?? PodcastSettings(podcastId: podcastId)
                s.speed = speed
                podcastSettings[podcastId] = s
            }

        case let .updatePodcastSettings(settings):
            podcastSettings[settings.podcastId] = settings

        case let .updateGlobalSettings(settings):
            global = settings

        case .recordSessions, .registerDevice:
            break
        }
    }

    // MARK: helpers

    private mutating func update(_ episodeId: String, now: Millis, _ change: (inout EpisodeState) -> Void) {
        var s = state(episodeId)
        change(&s)
        s.updatedAt = now
        states[episodeId] = s
    }

    private mutating func setPlayed(_ episodeId: String, _ played: Bool, now: Millis) {
        update(episodeId, now: now) {
            if played {
                if !$0.played { $0.playedAt = now }
                $0.played = true
                $0.inboxAt = nil
                $0.position = 0
            } else {
                $0.played = false
                $0.playedAt = nil
            }
        }
        if played { queue.removeAll { $0.episodeId == episodeId } }
    }

    private mutating func insertSorted(_ item: QueueItem) {
        let i = queue.firstIndex { $0.orderKey > item.orderKey } ?? queue.endIndex
        queue.insert(item, at: i)
    }

    private func neighbours(of key: String) -> (String?, String?) {
        let before = queue.last { $0.orderKey < key }?.episodeId
        let after = queue.first { $0.orderKey > key }?.episodeId
        return (before, after)
    }

    private mutating func enqueue(_ episodeId: String, _ position: QueuePosition, now: Millis, newId: () -> String) {
        let existing = queue.firstIndex { $0.episodeId == episodeId }
        // Already where it was asked to go: nothing to do.
        switch position {
        case .top where existing == 0: return
        case .next where existing == 1 || (existing == 0 && queue.count == 1): return
        case .last where existing == queue.count - 1 && existing != nil: return
        default: break
        }
        var item = existing.map { queue.remove(at: $0) }
            ?? QueueItem(id: newId(), episodeId: episodeId, orderKey: "", addedAt: now, addedBy: .manual)
        switch position {
        case .top: item.orderKey = OrderKey.between(nil, queue.first?.orderKey)
        case .next:
            if queue.isEmpty { item.orderKey = OrderKey.between(nil, nil) }
            else { item.orderKey = OrderKey.between(queue[0].orderKey, queue.count > 1 ? queue[1].orderKey : nil) }
        case .last: item.orderKey = OrderKey.between(queue.last?.orderKey, nil)
        }
        insertSorted(item)
        update(episodeId, now: now) {
            $0.inboxAt = nil
            $0.archived = false
            if $0.played { $0.played = false; $0.playedAt = nil; $0.position = 0 }
        }
    }
}
