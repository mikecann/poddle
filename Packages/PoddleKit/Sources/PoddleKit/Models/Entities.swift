import Foundation

// Synced entities from product-spec §3. IDs are Convex document ID strings.
// Wall-clock timestamps are milliseconds since the epoch, times are content seconds.

public typealias Millis = Double

public struct Podcast: Codable, Sendable, Hashable, Identifiable {
    public struct ImportRefs: Codable, Sendable, Hashable {
        public var overcastId: String?
        public init(overcastId: String? = nil) { self.overcastId = overcastId }
    }

    public var id: String
    public var feedURL: String
    public var isPrivate: Bool
    /// Keychain key for feed credentials. Never synced in plain text.
    public var credentialRef: String?
    public var title: String
    public var author: String
    public var artworkURL: String?
    public var description: String
    /// From `itunes:category`. Not in the spec's sketch, but the podcast page shows it.
    public var category: String?
    public var appleId: String?
    public var importRefs: ImportRefs
    public var subscribed: Bool
    public var subscribedAt: Millis?
    public var lastFetchedAt: Millis?
    public var etag: String?
    public var lastModified: String?

    public init(
        id: String, feedURL: String, isPrivate: Bool = false, credentialRef: String? = nil,
        title: String, author: String, artworkURL: String? = nil, description: String = "",
        category: String? = nil, appleId: String? = nil, importRefs: ImportRefs = .init(),
        subscribed: Bool = true, subscribedAt: Millis? = nil, lastFetchedAt: Millis? = nil,
        etag: String? = nil, lastModified: String? = nil
    ) {
        self.id = id; self.feedURL = feedURL; self.isPrivate = isPrivate; self.credentialRef = credentialRef
        self.title = title; self.author = author; self.artworkURL = artworkURL; self.description = description
        self.category = category; self.appleId = appleId; self.importRefs = importRefs
        self.subscribed = subscribed; self.subscribedAt = subscribedAt; self.lastFetchedAt = lastFetchedAt
        self.etag = etag; self.lastModified = lastModified
    }
}

public struct TranscriptRef: Codable, Sendable, Hashable {
    public var url: String
    public var type: String
    public var lang: String?
    public var rel: String?
    public init(url: String, type: String, lang: String? = nil, rel: String? = nil) {
        self.url = url; self.type = type; self.lang = lang; self.rel = rel
    }
}

public struct Episode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var podcastId: String
    public var guid: String
    public var enclosureURL: String
    public var enclosureType: String
    public var enclosureLength: Double?
    public var title: String
    public var pubDate: Millis
    public var duration: Double?
    public var showNotesHTML: String
    public var chaptersURL: String?
    public var transcripts: [TranscriptRef]
    public var artworkURL: String?
    public var isGhost: Bool

    public init(
        id: String, podcastId: String, guid: String? = nil, enclosureURL: String,
        enclosureType: String = "audio/mpeg", enclosureLength: Double? = nil, title: String,
        pubDate: Millis, duration: Double?, showNotesHTML: String = "", chaptersURL: String? = nil,
        transcripts: [TranscriptRef] = [], artworkURL: String? = nil, isGhost: Bool = false
    ) {
        self.id = id; self.podcastId = podcastId; self.guid = guid ?? id; self.enclosureURL = enclosureURL
        self.enclosureType = enclosureType; self.enclosureLength = enclosureLength; self.title = title
        self.pubDate = pubDate; self.duration = duration; self.showNotesHTML = showNotesHTML
        self.chaptersURL = chaptersURL; self.transcripts = transcripts; self.artworkURL = artworkURL
        self.isGhost = isGhost
    }
}

/// User state, kept apart from feed data so a feed refresh never clobbers it.
public struct EpisodeState: Codable, Sendable, Hashable {
    public var episodeId: String
    public var position: Double
    public var positionUpdatedAt: Millis
    public var positionDevice: String?
    public var played: Bool
    public var playedAt: Millis?
    public var starredAt: Millis?
    public var archived: Bool
    public var inboxAt: Millis?
    public var updatedAt: Millis

    public init(
        episodeId: String, position: Double = 0, positionUpdatedAt: Millis = 0, positionDevice: String? = nil,
        played: Bool = false, playedAt: Millis? = nil, starredAt: Millis? = nil, archived: Bool = false,
        inboxAt: Millis? = nil, updatedAt: Millis = 0
    ) {
        self.episodeId = episodeId; self.position = position; self.positionUpdatedAt = positionUpdatedAt
        self.positionDevice = positionDevice; self.played = played; self.playedAt = playedAt
        self.starredAt = starredAt; self.archived = archived; self.inboxAt = inboxAt; self.updatedAt = updatedAt
    }

    public var isStarred: Bool { starredAt != nil }
}

public enum QueueAddedBy: String, Codable, Sendable, Hashable {
    case manual, priority, auto
}

public struct QueueItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var episodeId: String
    /// Fractional order key. Sorts as a plain string.
    public var orderKey: String
    public var addedAt: Millis
    public var addedBy: QueueAddedBy

    public init(id: String, episodeId: String, orderKey: String, addedAt: Millis, addedBy: QueueAddedBy = .manual) {
        self.id = id; self.episodeId = episodeId; self.orderKey = orderKey; self.addedAt = addedAt; self.addedBy = addedBy
    }
}

public struct ListeningSession: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable { case live, overcastImport }
    public enum Route: String, Codable, Sendable { case airpods, speaker, carBluetooth, airplay, headphones, other }

    public var id: String
    public var episodeId: String
    public var podcastId: String
    public var deviceId: String
    public var startedAt: Millis
    public var endedAt: Millis
    public var contentStart: Double
    public var contentEnd: Double
    public var rate: Double
    public var smartSpeed: Bool
    public var smartRemovedContent: Double
    public var voiceBoost: Bool
    public var route: Route
    public var source: Source
    public var isEstimated: Bool

    public init(
        id: String, episodeId: String, podcastId: String, deviceId: String, startedAt: Millis, endedAt: Millis,
        contentStart: Double, contentEnd: Double, rate: Double, smartSpeed: Bool, smartRemovedContent: Double,
        voiceBoost: Bool, route: Route, source: Source, isEstimated: Bool
    ) {
        self.id = id; self.episodeId = episodeId; self.podcastId = podcastId; self.deviceId = deviceId
        self.startedAt = startedAt; self.endedAt = endedAt; self.contentStart = contentStart
        self.contentEnd = contentEnd; self.rate = rate; self.smartSpeed = smartSpeed
        self.smartRemovedContent = smartRemovedContent; self.voiceBoost = voiceBoost; self.route = route
        self.source = source; self.isEstimated = isEstimated
    }
}

public struct LibraryEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case subscribed, unsubscribed, starred, completed, skipped }
    public var id: String
    public var type: Kind
    public var podcastId: String?
    public var episodeId: String?
    public var at: Millis
    public init(id: String, type: Kind, podcastId: String? = nil, episodeId: String? = nil, at: Millis) {
        self.id = id; self.type = type; self.podcastId = podcastId; self.episodeId = episodeId; self.at = at
    }
}

public struct Device: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var apnsToken: String?
    public var lastSeenAt: Millis
    public init(id: String, name: String, platform: String, apnsToken: String? = nil, lastSeenAt: Millis) {
        self.id = id; self.name = name; self.platform = platform; self.apnsToken = apnsToken; self.lastSeenAt = lastSeenAt
    }
}

public struct ImportBatch: Codable, Sendable, Hashable, Identifiable {
    public struct Counts: Codable, Sendable, Hashable {
        public var podcasts: Int
        public var episodes: Int
        public var played: Int
        public var inProgress: Int
        public var sessions: Int
        public init(podcasts: Int = 0, episodes: Int = 0, played: Int = 0, inProgress: Int = 0, sessions: Int = 0) {
            self.podcasts = podcasts; self.episodes = episodes; self.played = played
            self.inProgress = inProgress; self.sessions = sessions
        }
    }
    public var id: String
    public var source: String
    public var importedAt: Millis
    public var assumedSpeed: Double
    public var counts: Counts
    public init(id: String, source: String, importedAt: Millis, assumedSpeed: Double, counts: Counts) {
        self.id = id; self.source = source; self.importedAt = importedAt; self.assumedSpeed = assumedSpeed; self.counts = counts
    }
}

/// Local only (ChapterCache in the spec).
public struct Chapter: Codable, Sendable, Hashable, Identifiable {
    public var start: Double
    public var end: Double?
    public var title: String
    public var img: String?
    public var url: String?
    public var toc: Bool
    public var id: Double { start }
    public init(start: Double, end: Double? = nil, title: String, img: String? = nil, url: String? = nil, toc: Bool = true) {
        self.start = start; self.end = end; self.title = title; self.img = img; self.url = url; self.toc = toc
    }
}

/// Local only. Downloads are per device and never synced.
public struct Download: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case queued, downloading, done, failed }
    public var episodeId: String
    public var state: State
    public var progress: Double
    public var bytes: Double?
    public init(episodeId: String, state: State, progress: Double = 1, bytes: Double? = nil) {
        self.episodeId = episodeId; self.state = state; self.progress = progress; self.bytes = bytes
    }
}
