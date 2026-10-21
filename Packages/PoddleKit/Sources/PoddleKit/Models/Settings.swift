import Foundation

public enum AutoAdd: String, Codable, Sendable, Hashable, CaseIterable {
    case inbox, upNextTop, upNextBottom, dontAdd

    /// Shows set to an Up Next option are the "priority" shows.
    public var isPriority: Bool { self == .upNextTop || self == .upNextBottom }

    public var label: String {
        switch self {
        case .inbox: "Inbox"
        case .upNextTop: "Top of queue"
        case .upNextBottom: "Bottom of queue"
        case .dontAdd: "Don't add"
        }
    }
}

public enum TimePitchAlgorithm: String, Codable, Sendable, Hashable, CaseIterable {
    case spectral, timeDomain
    public var label: String { self == .spectral ? "Spectral" : "Time domain" }
}

public enum EpisodeOrder: String, Codable, Sendable, Hashable, CaseIterable {
    case newestFirst, oldestFirst
    public var label: String { self == .newestFirst ? "Newest first" : "Oldest first" }
}

public enum AutoArchive: String, Codable, Sendable, Hashable, CaseIterable {
    case never, afterWeek, afterTwoWeeks, afterMonth
    public var label: String {
        switch self {
        case .never: "Never"
        case .afterWeek: "After 1 week"
        case .afterTwoWeeks: "After 2 weeks"
        case .afterMonth: "After 1 month"
        }
    }
}

public enum HeadphoneMapping: String, Codable, Sendable, Hashable, CaseIterable {
    case skip, chapters
    public var label: String { self == .skip ? "Skip" : "Chapters" }
}

public enum CellularDownloads: String, Codable, Sendable, Hashable, CaseIterable {
    case wifiOnly, allow, ask
    public var label: String {
        switch self {
        case .wifiOnly: "Wi-Fi only"
        case .allow: "Allow cellular"
        case .ask: "Ask"
        }
    }
}

public enum DeletePlayed: String, Codable, Sendable, Hashable, CaseIterable {
    case immediately, after24h, afterWeek, never
    public var label: String {
        switch self {
        case .immediately: "Immediately"
        case .after24h: "After 24 hours"
        case .afterWeek: "After 1 week"
        case .never: "Never"
        }
    }
}

/// One row with every default. Per-show values fall back to these live.
public struct GlobalSettings: Codable, Sendable, Hashable {
    public var speed: Double
    public var smartSpeed: Bool
    public var voiceBoost: Bool
    public var timePitch: TimePitchAlgorithm
    public var skipIntro: Double
    public var skipOutro: Double
    public var autoAdd: AutoAdd
    public var autoDownload: Bool
    public var keepLatest: Int
    public var notifications: Bool
    public var episodeOrder: EpisodeOrder
    public var autoArchive: AutoArchive
    // Global-only
    public var skipBack: Double
    public var skipForward: Double
    public var headphoneMapping: HeadphoneMapping
    public var autoRewind: Bool
    public var autoAdvance: Bool
    public var sleepFadeOut: Bool
    public var shakeToRestartSleep: Bool
    public var cellularDownloads: CellularDownloads
    public var deletePlayed: DeletePlayed
    public var storageCapGB: Double

    public init(
        speed: Double = 1.0, smartSpeed: Bool = true, voiceBoost: Bool = true, timePitch: TimePitchAlgorithm = .spectral,
        skipIntro: Double = 0, skipOutro: Double = 0, autoAdd: AutoAdd = .inbox, autoDownload: Bool = true,
        keepLatest: Int = 3, notifications: Bool = false, episodeOrder: EpisodeOrder = .newestFirst,
        autoArchive: AutoArchive = .never, skipBack: Double = 15, skipForward: Double = 30,
        headphoneMapping: HeadphoneMapping = .skip, autoRewind: Bool = true, autoAdvance: Bool = true,
        sleepFadeOut: Bool = true, shakeToRestartSleep: Bool = true, cellularDownloads: CellularDownloads = .wifiOnly,
        deletePlayed: DeletePlayed = .after24h, storageCapGB: Double = 5
    ) {
        self.speed = speed; self.smartSpeed = smartSpeed; self.voiceBoost = voiceBoost; self.timePitch = timePitch
        self.skipIntro = skipIntro; self.skipOutro = skipOutro; self.autoAdd = autoAdd; self.autoDownload = autoDownload
        self.keepLatest = keepLatest; self.notifications = notifications; self.episodeOrder = episodeOrder
        self.autoArchive = autoArchive; self.skipBack = skipBack; self.skipForward = skipForward
        self.headphoneMapping = headphoneMapping; self.autoRewind = autoRewind; self.autoAdvance = autoAdvance
        self.sleepFadeOut = sleepFadeOut; self.shakeToRestartSleep = shakeToRestartSleep
        self.cellularDownloads = cellularDownloads; self.deletePlayed = deletePlayed; self.storageCapGB = storageCapGB
    }

    public static let defaults = GlobalSettings()
}

/// Per-show overrides (spec §2.5). `nil` means "Use default", inheriting the global value live.
public struct PodcastSettings: Codable, Sendable, Hashable {
    public var podcastId: String
    public var speed: Double?
    public var smartSpeed: Bool?
    public var voiceBoost: Bool?
    public var timePitch: TimePitchAlgorithm?
    public var skipIntro: Double?
    public var skipOutro: Double?
    public var autoAdd: AutoAdd?
    public var autoDownload: Bool?
    public var keepLatest: Int?
    public var notifications: Bool?
    public var episodeOrder: EpisodeOrder?
    public var autoArchive: AutoArchive?
    public var skipChapterRules: [String]?

    public init(
        podcastId: String, speed: Double? = nil, smartSpeed: Bool? = nil, voiceBoost: Bool? = nil,
        timePitch: TimePitchAlgorithm? = nil, skipIntro: Double? = nil, skipOutro: Double? = nil,
        autoAdd: AutoAdd? = nil, autoDownload: Bool? = nil, keepLatest: Int? = nil, notifications: Bool? = nil,
        episodeOrder: EpisodeOrder? = nil, autoArchive: AutoArchive? = nil, skipChapterRules: [String]? = nil
    ) {
        self.podcastId = podcastId; self.speed = speed; self.smartSpeed = smartSpeed; self.voiceBoost = voiceBoost
        self.timePitch = timePitch; self.skipIntro = skipIntro; self.skipOutro = skipOutro; self.autoAdd = autoAdd
        self.autoDownload = autoDownload; self.keepLatest = keepLatest; self.notifications = notifications
        self.episodeOrder = episodeOrder; self.autoArchive = autoArchive; self.skipChapterRules = skipChapterRules
    }

    public var hasOverrides: Bool {
        speed != nil || smartSpeed != nil || voiceBoost != nil || timePitch != nil || skipIntro != nil
            || skipOutro != nil || autoAdd != nil || autoDownload != nil || keepLatest != nil
            || notifications != nil || episodeOrder != nil || autoArchive != nil || skipChapterRules != nil
    }
}

/// A value plus whether it came from the show's own override.
public struct Resolved<Value: Sendable & Hashable>: Sendable, Hashable {
    public var value: Value
    public var isOverride: Bool
    public init(_ value: Value, isOverride: Bool) { self.value = value; self.isOverride = isOverride }

    static func pick(_ override: Value?, _ global: Value) -> Resolved {
        if let override { return Resolved(override, isOverride: true) }
        return Resolved(global, isOverride: false)
    }
}

/// Effective settings for one show: `override ?? global`, worked out at the point of use so a
/// change to a global default reaches every show still set to inherit.
public struct ResolvedSettings: Sendable, Hashable {
    public var speed: Resolved<Double>
    public var smartSpeed: Resolved<Bool>
    public var voiceBoost: Resolved<Bool>
    public var timePitch: Resolved<TimePitchAlgorithm>
    public var skipIntro: Resolved<Double>
    public var skipOutro: Resolved<Double>
    public var autoAdd: Resolved<AutoAdd>
    public var autoDownload: Resolved<Bool>
    public var keepLatest: Resolved<Int>
    public var notifications: Resolved<Bool>
    public var episodeOrder: Resolved<EpisodeOrder>
    public var autoArchive: Resolved<AutoArchive>
    public var skipChapterRules: Resolved<[String]>

    public init(global: GlobalSettings, override o: PodcastSettings?) {
        speed = .pick(o?.speed, global.speed)
        smartSpeed = .pick(o?.smartSpeed, global.smartSpeed)
        voiceBoost = .pick(o?.voiceBoost, global.voiceBoost)
        timePitch = .pick(o?.timePitch, global.timePitch)
        skipIntro = .pick(o?.skipIntro, global.skipIntro)
        skipOutro = .pick(o?.skipOutro, global.skipOutro)
        autoAdd = .pick(o?.autoAdd, global.autoAdd)
        autoDownload = .pick(o?.autoDownload, global.autoDownload)
        keepLatest = .pick(o?.keepLatest, global.keepLatest)
        notifications = .pick(o?.notifications, global.notifications)
        episodeOrder = .pick(o?.episodeOrder, global.episodeOrder)
        autoArchive = .pick(o?.autoArchive, global.autoArchive)
        skipChapterRules = .pick(o?.skipChapterRules, [])
    }

    public var isPriority: Bool { autoAdd.value.isPriority }
}

public enum SpeedScope: Codable, Sendable, Hashable {
    case allPodcasts
    case show(String)

    /// The speed sheet's default scope (decisions.md): "Just this show" if the show already has its
    /// own speed, otherwise "All podcasts".
    public static func defaultScope(podcastId: String, override: PodcastSettings?) -> SpeedScope {
        override?.speed != nil ? .show(podcastId) : .allPodcasts
    }
}

public enum Speed {
    public static let range: ClosedRange<Double> = 0.5...3.0
    public static let step = 0.05
    public static let presets: [Double] = [1.0, 1.25, 1.4, 1.6, 1.8, 2.0, 2.5]

    /// Clamps to 0.5–3.0 and snaps to the nearest 0.05.
    public static func snap(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return Double(Int((clamped / step).rounded()) * 5) / 100
    }

    /// Index of a speed on the 0.05 grid (0.5 is 0, 3.0 is 50).
    public static func detent(_ value: Double) -> Int { Int(((snap(value) - range.lowerBound) / step).rounded()) }
}
