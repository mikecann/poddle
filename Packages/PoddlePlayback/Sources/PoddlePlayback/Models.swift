import Foundation

public enum TimePitchAlgorithm: String, Sendable, Codable, CaseIterable {
    /// Apple's phase-vocoder time-pitch unit (`AVAudioUnitTimePitch`). Smoothest on music beds.
    case spectral
    /// Poddle's pitch-synchronous speech stretcher. Most natural on voices at high speeds.
    case timeDomain
}

public enum PlaybackSource: Sendable, Equatable {
    /// A downloaded file. Plays through the engine with Smart Speed and Voice Boost.
    case local(URL)
    /// Not downloaded yet. Streams through AVPlayer, speed only.
    case remote(URL)
}

public struct Chapter: Sendable, Equatable, Codable {
    public var title: String
    /// Content seconds.
    public var start: Double
    public var end: Double?
    public var artwork: Data?

    public init(title: String, start: Double, end: Double? = nil, artwork: Data? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.artwork = artwork
    }
}

public struct PlaybackItem: Sendable, Equatable {
    /// Opaque episode ID (the Convex document ID), echoed back in segments and events.
    public var id: String
    public var source: PlaybackSource
    public var title: String
    public var showTitle: String
    /// Encoded image data (PNG/JPEG) for Now Playing.
    public var artwork: Data?
    /// Known duration in content seconds, used until the media reports its own.
    public var duration: Double?
    public var chapters: [Chapter]
    /// Integrated loudness (LUFS, as returned by `LoudnessMeter`). Measured in the background when nil.
    public var loudness: Double?

    public init(id: String, source: PlaybackSource, title: String, showTitle: String, artwork: Data? = nil,
                duration: Double? = nil, chapters: [Chapter] = [], loudness: Double? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.showTitle = showTitle
        self.artwork = artwork
        self.duration = duration
        self.chapters = chapters.sorted { $0.start < $1.start }
        self.loudness = loudness
    }
}

public enum AudioRoute: String, Sendable, Codable {
    case speaker, headphones, airPods, bluetooth, carPlay, airPlay, unknown
}

/// A stretch of listening, for stats. Checkpoints are emitted every 30 s with `isFinal == false`
/// and the same `id`, so the app can upsert by id and a crash loses at most 30 s.
public struct ListeningSegment: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var episodeID: String
    /// Milliseconds since the epoch.
    public var wallStart: Double
    public var wallEnd: Double
    /// Content seconds.
    public var contentStart: Double
    public var contentEnd: Double
    public var rate: Double
    public var smartSpeed: Bool
    /// Content seconds Smart Speed removed during this segment.
    public var smartRemovedContent: Double
    public var voiceBoost: Bool
    public var route: AudioRoute
    public var isFinal: Bool
}

public enum PlaybackEvent: Sendable, Equatable {
    /// The position crossed the played threshold (within 30 s of the end, or 98%). Fires once per load.
    case reachedPlayedThreshold(episodeID: String)
    /// Audio ran out. `shouldAdvance` is false when an end-of-episode sleep timer stopped playback.
    case finished(episodeID: String, shouldAdvance: Bool)
    case sleepTimerFired
    case failed(episodeID: String, message: String)
}

public enum PlaybackError: Error, Sendable {
    case unsupportedFormat
    case noItem
}

public enum NextPreviousAction: String, Sendable, Codable {
    case skip
    case chapter
}

public struct RemoteCommandConfiguration: Sendable, Equatable {
    public var skipBackwardInterval: Double
    public var skipForwardInterval: Double
    /// What headphone / AirPods next and previous do.
    public var nextPrevious: NextPreviousAction

    public init(skipBackwardInterval: Double = 15, skipForwardInterval: Double = 30, nextPrevious: NextPreviousAction = .skip) {
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.nextPrevious = nextPrevious
    }
}

public enum PlayedThreshold {
    /// Played = within 30 s of the end, or at 98%.
    public static func isPlayed(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return duration - position <= 30 || position >= duration * 0.98
    }
}

public enum AutoRewind {
    /// Seconds to rewind when resuming after a pause of `pausedFor` seconds.
    public static func amount(pausedFor: Double) -> Double {
        if pausedFor > 3_600 { return 10 }
        if pausedFor > 300 { return 3 }
        return 0
    }
}
