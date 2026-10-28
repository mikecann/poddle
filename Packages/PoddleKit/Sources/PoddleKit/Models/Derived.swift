import Foundation

// Values the backend works out (stats, year in review, search, import progress).

public struct TopShow: Codable, Sendable, Hashable, Identifiable {
    public var podcastId: String
    public var title: String
    public var seconds: Double
    public var isPrivate: Bool
    public var id: String { podcastId }
    public init(podcastId: String, title: String, seconds: Double, isPrivate: Bool = false) {
        self.podcastId = podcastId; self.title = title; self.seconds = seconds; self.isPrivate = isPrivate
    }
}

public struct StatsSummary: Codable, Sendable, Hashable {
    public var year: Int
    /// Wall-clock listening.
    public var listenedSeconds: Double
    public var savedBySpeedSeconds: Double
    public var savedBySmartSpeedSeconds: Double
    public var currentStreakDays: Int
    public var bestStreakDays: Int
    /// The best streak before the current one.
    public var previousBestStreakDays: Int
    /// Minutes listened on each of the last 10 days, oldest first.
    public var recentDays: [Double]
    /// 7 rows (Mon–Sun) by 24 hours, 0...1. Live sessions only.
    public var heatmap: [[Double]]
    public var peakLabel: String
    public var topShows: [TopShow]
    public var showCount: Int
    public var episodesCompleted: Int
    public var averageSpeed: Double
    /// Set when the totals include estimated Overcast history from before this date.
    public var estimatedBefore: Millis?

    public init(
        year: Int, listenedSeconds: Double, savedBySpeedSeconds: Double, savedBySmartSpeedSeconds: Double,
        currentStreakDays: Int, bestStreakDays: Int, previousBestStreakDays: Int, recentDays: [Double],
        heatmap: [[Double]], peakLabel: String, topShows: [TopShow], showCount: Int, episodesCompleted: Int,
        averageSpeed: Double, estimatedBefore: Millis? = nil
    ) {
        self.year = year; self.listenedSeconds = listenedSeconds; self.savedBySpeedSeconds = savedBySpeedSeconds
        self.savedBySmartSpeedSeconds = savedBySmartSpeedSeconds; self.currentStreakDays = currentStreakDays
        self.bestStreakDays = bestStreakDays; self.previousBestStreakDays = previousBestStreakDays
        self.recentDays = recentDays; self.heatmap = heatmap; self.peakLabel = peakLabel; self.topShows = topShows
        self.showCount = showCount; self.episodesCompleted = episodesCompleted; self.averageSpeed = averageSpeed
        self.estimatedBefore = estimatedBefore
    }

    public var savedSeconds: Double { savedBySpeedSeconds + savedBySmartSpeedSeconds }
    public var isBestStreak: Bool { currentStreakDays >= bestStreakDays }
}

public struct YearInReview: Codable, Sendable, Hashable {
    public var year: Int
    public var listenerName: String
    public var serial: Int
    public var listenedSeconds: Double
    public var savedBySpeedSeconds: Double
    public var savedBySmartSpeedSeconds: Double
    public var topShows: [TopShow]
    public var otherShowCount: Int
    public var otherShowsSeconds: Double
    public var usualSpeed: Double
    public var peakHourLabel: String
    public var longestStreakDays: Int
    public var episodesCompleted: Int
    public var biggestDayLabel: String
    public var busiestMonth: String
    public var personality: String
    public var newShows: Int
    public var includesEstimates: Bool

    public init(
        year: Int, listenerName: String, serial: Int, listenedSeconds: Double, savedBySpeedSeconds: Double,
        savedBySmartSpeedSeconds: Double, topShows: [TopShow], otherShowCount: Int, otherShowsSeconds: Double,
        usualSpeed: Double, peakHourLabel: String, longestStreakDays: Int, episodesCompleted: Int,
        biggestDayLabel: String, busiestMonth: String, personality: String, newShows: Int, includesEstimates: Bool
    ) {
        self.year = year; self.listenerName = listenerName; self.serial = serial; self.listenedSeconds = listenedSeconds
        self.savedBySpeedSeconds = savedBySpeedSeconds; self.savedBySmartSpeedSeconds = savedBySmartSpeedSeconds
        self.topShows = topShows; self.otherShowCount = otherShowCount; self.otherShowsSeconds = otherShowsSeconds
        self.usualSpeed = usualSpeed; self.peakHourLabel = peakHourLabel; self.longestStreakDays = longestStreakDays
        self.episodesCompleted = episodesCompleted; self.biggestDayLabel = biggestDayLabel
        self.busiestMonth = busiestMonth; self.personality = personality; self.newShows = newShows
        self.includesEstimates = includesEstimates
    }

    public var savedSeconds: Double { savedBySpeedSeconds + savedBySmartSpeedSeconds }
}

public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var genre: String
    public var feedURL: String
    public var appleId: String?
    public var artworkURL: String?
    public init(id: String, title: String, author: String, genre: String, feedURL: String, appleId: String? = nil, artworkURL: String? = nil) {
        self.id = id; self.title = title; self.author = author; self.genre = genre; self.feedURL = feedURL
        self.appleId = appleId; self.artworkURL = artworkURL
    }
}

public struct SearchResponse: Codable, Sendable, Hashable {
    public var results: [SearchResult]
    public var totalCount: Int
    /// Episodes whose names match (Apple's episode search), shown under the shows.
    public var episodes: [EpisodeSearchResult]
    public init(results: [SearchResult], totalCount: Int, episodes: [EpisodeSearchResult] = []) {
        self.results = results; self.totalCount = totalCount; self.episodes = episodes
    }
}

/// One episode from Apple's episode search (`directory:searchEpisodes`), from any show, followed or not.
public struct EpisodeSearchResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var showTitle: String
    public var author: String
    public var feedURL: String
    /// The feed item's guid as Apple saw it, which finds our copy of the episode.
    public var guid: String?
    public var audioURL: String?
    public var pubDate: Millis?
    public var duration: Double?
    public var artworkURL: String?
    public init(
        id: String, title: String, showTitle: String, author: String = "", feedURL: String, guid: String? = nil,
        audioURL: String? = nil, pubDate: Millis? = nil, duration: Double? = nil, artworkURL: String? = nil
    ) {
        self.id = id; self.title = title; self.showTitle = showTitle; self.author = author; self.feedURL = feedURL
        self.guid = guid; self.audioURL = audioURL; self.pubDate = pubDate; self.duration = duration; self.artworkURL = artworkURL
    }
}

/// A Discover result to open without following its show (decisions.md, 27 Oct 2026).
public enum DiscoverTarget: Sendable, Hashable {
    case show(SearchResult)
    case episode(EpisodeSearchResult)
}

/// What opening a `DiscoverTarget` found: the show, and the episode when one was asked for and is in the feed.
public struct OpenedFeed: Sendable, Hashable {
    public var podcastId: String
    public var episodeId: String?
    public init(podcastId: String, episodeId: String? = nil) { self.podcastId = podcastId; self.episodeId = episodeId }
}

public struct ImportProgress: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable { case reading, matching, done, failed }
    public var phase: Phase
    public var fileName: String
    public var podcasts: Int
    public var playedEpisodes: Int
    public var hours: Double
    public var halfFinished: Int
    /// 0...1
    public var fraction: Double
    public var earliest: Millis?
    public var importedAt: Millis
    public var message: String?

    public init(
        phase: Phase, fileName: String, podcasts: Int = 0, playedEpisodes: Int = 0, hours: Double = 0,
        halfFinished: Int = 0, fraction: Double = 0, earliest: Millis? = nil, importedAt: Millis, message: String? = nil
    ) {
        self.phase = phase; self.fileName = fileName; self.podcasts = podcasts; self.playedEpisodes = playedEpisodes
        self.hours = hours; self.halfFinished = halfFinished; self.fraction = fraction; self.earliest = earliest
        self.importedAt = importedAt; self.message = message
    }
}

public struct SubscribeRequest: Codable, Sendable, Hashable {
    public var feedURL: String
    public var title: String?
    public var author: String?
    public var appleId: String?
    public var artworkURL: String?
    public var isPrivate: Bool
    public init(feedURL: String, title: String? = nil, author: String? = nil, appleId: String? = nil, artworkURL: String? = nil, isPrivate: Bool = false) {
        self.feedURL = feedURL; self.title = title; self.author = author; self.appleId = appleId
        self.artworkURL = artworkURL; self.isPrivate = isPrivate
    }

    public init(_ result: SearchResult) {
        self.init(feedURL: result.feedURL, title: result.title, author: result.author, appleId: result.appleId, artworkURL: result.artworkURL)
    }
}
