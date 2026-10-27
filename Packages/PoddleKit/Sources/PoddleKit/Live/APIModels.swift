import Foundation

// The backend's documents and return shapes (docs/api.md), and how they map onto PoddleKit's
// models. Optional fields are absent rather than null, so they decode as Swift optionals.

struct PodcastDoc: Decodable, Sendable {
    var _id: String
    var feedUrl: String
    var title: String
    var author: String?
    var description: String?
    var artworkUrl: String?
    var appleId: Double?
    var overcastId: Double?
    var isPrivate: Bool
    var subscribed: Bool
    var subscribedAt: Double?
    var lastFetchedAt: Double?
    var latestEpisodeAt: Double?

    var model: Podcast {
        Podcast(
            id: _id, feedURL: feedUrl, isPrivate: isPrivate, title: title, author: author ?? "",
            artworkURL: artworkUrl, description: description ?? "", appleId: appleId.map { String(Int($0)) },
            importRefs: .init(overcastId: overcastId.map { String(Int($0)) }), subscribed: subscribed,
            subscribedAt: subscribedAt, lastFetchedAt: lastFetchedAt
        )
    }
}

struct PodcastSummaryDoc: Decodable, Sendable {
    var _id: String
    var title: String
    var author: String?
    var artworkUrl: String?
    var isPrivate: Bool
}

struct EpisodeDoc: Decodable, Sendable {
    struct Transcript: Decodable, Sendable { var url: String; var type: String; var language: String?; var rel: String? }
    var _id: String
    var podcastId: String
    var guid: String?
    var enclosureUrl: String?
    var enclosureType: String?
    var enclosureLength: Double?
    var title: String
    var summary: String?
    var pubDate: Double?
    var duration: Double?
    var chaptersUrl: String?
    var transcripts: [Transcript]?
    var artworkUrl: String?
    var isGhost: Bool?
    var firstSeenAt: Double?

    var model: Episode {
        Episode(
            id: _id, podcastId: podcastId, guid: guid, enclosureURL: enclosureUrl ?? "",
            enclosureType: enclosureType ?? "audio/mpeg", enclosureLength: enclosureLength, title: title,
            pubDate: pubDate ?? firstSeenAt ?? 0, duration: duration, showNotesHTML: summary ?? "",
            chaptersURL: chaptersUrl,
            transcripts: (transcripts ?? []).map { TranscriptRef(url: $0.url, type: $0.type, lang: $0.language, rel: $0.rel) },
            artworkURL: artworkUrl, isGhost: isGhost ?? false
        )
    }
}

struct EpisodeStateDoc: Decodable, Sendable {
    var episodeId: String
    var podcastId: String?
    var position: Double
    var positionUpdatedAt: Double
    var positionDeviceId: String?
    var played: Bool
    var playedAt: Double?
    var starred: Bool
    var starredAt: Double?
    var starredUpdatedAt: Double?
    var archived: Bool
    var inInbox: Bool
    var inboxAt: Double?
    var inboxUpdatedAt: Double?
    var updatedAt: Double

    var model: EpisodeState {
        EpisodeState(
            episodeId: episodeId, position: position, positionUpdatedAt: positionUpdatedAt,
            positionDevice: positionDeviceId, played: played, playedAt: played ? playedAt : nil,
            starredAt: starred ? (starredAt ?? starredUpdatedAt ?? updatedAt) : nil, archived: archived,
            inboxAt: inInbox ? (inboxAt ?? inboxUpdatedAt ?? updatedAt) : nil, updatedAt: updatedAt
        )
    }
}

struct QueueItemDoc: Decodable, Sendable {
    var _id: String
    var episodeId: String
    var orderKey: String
    var addedAt: Double
    var addedBy: String

    var model: QueueItem {
        QueueItem(id: _id, episodeId: episodeId, orderKey: orderKey, addedAt: addedAt, addedBy: QueueAddedBy(rawValue: addedBy) ?? .manual)
    }
}

struct EpisodeRowDoc: Decodable, Sendable {
    var episode: EpisodeDoc
    var state: EpisodeStateDoc?
    var podcast: PodcastSummaryDoc
}

/// `episodes:get`.
struct EpisodeGetDoc: Decodable, Sendable {
    var row: EpisodeRowDoc
}

/// `podcasts:get`.
struct PodcastGetDoc: Decodable, Sendable {
    var podcast: PodcastDoc
}

struct UpNextEntryDoc: Decodable, Sendable {
    var item: QueueItemDoc
    var row: EpisodeRowDoc
}

struct DeletionDoc: Decodable, Sendable {
    var table: String
    var docId: String
    var episodeId: String?
}

struct SyncPage: Decodable, Sendable {
    var page: [JSONValue]
    var isDone: Bool
    var continueCursor: String
    var maxUpdatedAt: Double?
}

struct Paginated<T: Decodable & Sendable>: Decodable, Sendable {
    var page: [T]
    var isDone: Bool
    var continueCursor: String
}

struct PodcastSettingsResponse: Decodable, Sendable {
    var overrides: [String: JSONValue]
}

struct DirectoryResultDoc: Decodable, Sendable {
    var appleId: Double?
    var title: String
    var author: String?
    var artworkUrl: String?
    var feedUrl: String?
    var genre: String?
    var episodeCount: Double?
    var podcastId: String?
    var subscribed: Bool

    var model: SearchResult? {
        guard let feedUrl else { return nil }
        let apple = appleId.map { String(Int($0)) }
        return SearchResult(
            id: apple ?? feedUrl, title: title, author: author ?? "", genre: genre ?? "Podcast",
            feedURL: feedUrl, appleId: apple, artworkURL: artworkUrl
        )
    }
}

struct DirectoryEpisodeDoc: Decodable, Sendable {
    var appleId: Double?
    var title: String
    var showTitle: String
    var author: String?
    var artworkUrl: String?
    var feedUrl: String
    var guid: String?
    var audioUrl: String?
    var pubDate: Double?
    var duration: Double?

    var model: EpisodeSearchResult {
        EpisodeSearchResult(
            id: appleId.map { String(Int($0)) } ?? guid ?? "\(feedUrl)#\(title)", title: title, showTitle: showTitle,
            author: author ?? "", feedURL: feedUrl, guid: guid, audioURL: audioUrl, pubDate: pubDate, duration: duration,
            artworkURL: artworkUrl
        )
    }
}

struct OpenedFeedDoc: Decodable, Sendable {
    var podcastId: String
    var episodeId: String?
}

struct FeedPreviewDoc: Decodable, Sendable {
    var feedUrl: String
    var podcastId: String?
    var subscribed: Bool
    var title: String
    var author: String?
    var artworkUrl: String?
    var episodeCount: Double?

    var model: SearchResult {
        SearchResult(id: podcastId ?? feedUrl, title: title, author: author ?? "", genre: "Podcast", feedURL: feedUrl, artworkURL: artworkUrl)
    }
}

struct ImportBatchDoc: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        var podcasts: Double?
        var podcastsProcessed: Double?
        var episodes: Double?
        var playedEpisodes: Double?
        var inProgressEpisodes: Double?
        var sessions: Double?
        var estimatedListenSeconds: Double?
        var earliestListenAt: Double?
    }
    var _id: String
    var status: String
    var startedAt: Double
    var finishedAt: Double?
    var error: String?
    var warning: String?
    var counts: Counts

    func progress(fileName: String) -> ImportProgress {
        let total = counts.podcasts ?? 0
        let processed = counts.podcastsProcessed ?? 0
        let phase: ImportProgress.Phase = switch status {
        case "done": .done
        case "failed": .failed
        case "parsing": .reading
        default: .matching
        }
        let fraction = phase == .done ? 1 : (total > 0 ? min(1, processed / total) : 0)
        return ImportProgress(
            phase: phase, fileName: fileName, podcasts: Int(total), playedEpisodes: Int(counts.playedEpisodes ?? 0),
            hours: ((counts.estimatedListenSeconds ?? 0) / 3600).rounded(), halfFinished: Int(counts.inProgressEpisodes ?? 0),
            fraction: fraction, earliest: counts.earliestListenAt, importedAt: finishedAt ?? startedAt,
            message: error ?? warning
        )
    }
}

// MARK: - Stats

struct StreakDoc: Decodable, Sendable { var length: Double; var startDay: String?; var endDay: String? }

struct TotalsDoc: Decodable, Sendable {
    var wall: Double
    var content: Double
    var speedSaved: Double
    var smartSaved: Double
    var timeSaved: Double
    var estimatedWall: Double
    var sessions: Double
    var averageSpeed: Double?
}

struct TopShowDoc: Decodable, Sendable {
    var podcast: PodcastSummaryDoc
    var wall: Double
    var model: TopShow { TopShow(podcastId: podcast._id, title: podcast.title, seconds: wall, isPrivate: podcast.isPrivate) }
}

struct DayDoc: Decodable, Sendable { var day: String; var wall: Double }
struct MonthDoc: Decodable, Sendable { var month: String; var wall: Double }

struct SummaryDoc: Decodable, Sendable {
    struct Completion: Decodable, Sendable { var started: Double; var completed: Double }
    var startDay: String
    var endDay: String
    var totals: TotalsDoc
    var completion: Completion
    var topShows: [TopShowDoc]
    var longestStreak: StreakDoc
    var currentStreak: StreakDoc
    var heatmap: [Double]
    var days: [DayDoc]
    var months: [MonthDoc]
    var includesEstimated: Bool
}

struct YearInReviewDoc: Decodable, Sendable {
    struct Personality: Decodable, Sendable { var key: String; var label: String; var percent: Double }
    var year: Double
    var totals: TotalsDoc
    var episodesCompleted: Double
    var topShows: [TopShowDoc]
    var longestStreak: StreakDoc
    var biggestDay: DayDoc?
    var busiestMonth: MonthDoc?
    var personality: Personality?
    var newShows: [PodcastSummaryDoc]
    var heatmap: [Double]
    var includesEstimated: Bool
    var estimatedBefore: Double?
}

enum StatsMapping {
    /// `heatmap` is 168 wall seconds, Monday first (index = weekday × 24 + hour). The UI wants
    /// 7 rows of 24, scaled 0...1.
    static func grid(_ flat: [Double]) -> [[Double]] {
        let peak = flat.max() ?? 0
        return (0..<7).map { d in
            (0..<24).map { h in
                let i = d * 24 + h
                return i < flat.count && peak > 0 ? flat[i] / peak : 0
            }
        }
    }

    static func peakLabel(_ flat: [Double]) -> String {
        guard let peak = flat.max(), peak > 0, let i = flat.firstIndex(of: peak) else { return "Not enough yet" }
        let days = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
        return "\(days[i / 24]) at \(hourLabel(i % 24))"
    }

    static func peakHour(_ flat: [Double]) -> String {
        var hours = [Double](repeating: 0, count: 24)
        for (i, v) in flat.enumerated() { hours[i % 24] += v }
        guard let peak = hours.max(), peak > 0, let h = hours.firstIndex(of: peak) else { return "—" }
        return hourLabel(h)
    }

    static func hourLabel(_ h: Int) -> String {
        switch h {
        case 0: "midnight"
        case 12: "noon"
        case 1..<12: "\(h) am"
        default: "\(h - 12) pm"
        }
    }

    static func summary(year: Int, _ s: SummaryDoc, allTime: SummaryDoc?, today: String, estimatedBefore: Double?) -> StatsSummary {
        let days = s.days.filter { $0.day <= today }.suffix(10).map { $0.wall / 60 }
        let recent = Array(repeating: 0.0, count: max(0, 10 - days.count)) + days
        let current = Int(s.currentStreak.length)
        let longest = Int(max(s.longestStreak.length, allTime?.longestStreak.length ?? 0))
        let previous = allTime.map { a in a.longestStreak.endDay == s.currentStreak.endDay ? 0 : Int(a.longestStreak.length) } ?? 0
        return StatsSummary(
            year: year, listenedSeconds: s.totals.wall, savedBySpeedSeconds: s.totals.speedSaved,
            savedBySmartSpeedSeconds: s.totals.smartSaved, currentStreakDays: current, bestStreakDays: max(longest, current),
            previousBestStreakDays: previous, recentDays: recent, heatmap: grid(s.heatmap), peakLabel: peakLabel(s.heatmap),
            topShows: s.topShows.map(\.model), showCount: s.topShows.count, episodesCompleted: Int(s.completion.completed),
            averageSpeed: s.totals.averageSpeed ?? 1, estimatedBefore: s.includesEstimated ? estimatedBefore : nil
        )
    }

    static func years(from allTime: SummaryDoc, current: Int) -> [Int] {
        var years = Set(allTime.months.filter { $0.wall > 0 }.compactMap { Int($0.month.prefix(4)) })
        years.insert(current)
        return years.sorted(by: >)
    }

    static func yearInReview(_ r: YearInReviewDoc) -> YearInReview {
        let top = r.topShows.map(\.model)
        let topSeconds = top.reduce(0) { $0 + $1.seconds }
        let monthName: String = r.busiestMonth.flatMap { m in
            let parts = m.month.split(separator: "-")
            guard parts.count == 2, let n = Int(parts[1]), (1...12).contains(n) else { return nil }
            return DateFormatter().monthSymbols[n - 1]
        } ?? "—"
        let biggest: String = r.biggestDay.map { d in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            guard let date = f.date(from: d.day) else { return d.day }
            f.dateFormat = "d MMM"
            return "\(f.string(from: date)) · \(Format.hours(d.wall))"
        } ?? "—"
        return YearInReview(
            year: Int(r.year), listenerName: "Mike", serial: Int(r.totals.sessions) % 10_000,
            listenedSeconds: r.totals.wall, savedBySpeedSeconds: r.totals.speedSaved,
            savedBySmartSpeedSeconds: r.totals.smartSaved, topShows: top, otherShowCount: 0,
            otherShowsSeconds: max(0, r.totals.wall - topSeconds), usualSpeed: r.totals.averageSpeed ?? 1,
            peakHourLabel: peakHour(r.heatmap), longestStreakDays: Int(r.longestStreak.length),
            episodesCompleted: Int(r.episodesCompleted), biggestDayLabel: biggest, busiestMonth: monthName,
            personality: r.personality.map { "\($0.label)" } ?? "Steady listener", newShows: r.newShows.count,
            includesEstimates: r.includesEstimated
        )
    }
}

// MARK: - Settings

/// Field names and value mappings between PoddleKit's settings and the backend's.
enum SettingsMapping {
    static func autoAdd(_ s: String?) -> AutoAdd? {
        switch s {
        case "inbox": .inbox
        case "upNextTop": .upNextTop
        case "upNextBottom": .upNextBottom
        case "none": .dontAdd
        default: nil
        }
    }

    static func api(_ a: AutoAdd) -> String { a == .dontAdd ? "none" : a.rawValue }

    static func autoArchive(_ days: Double?) -> AutoArchive? {
        guard let days else { return nil }
        switch days {
        case ...0: return .never
        case ..<11: return .afterWeek
        case ..<22: return .afterTwoWeeks
        default: return .afterMonth
        }
    }

    static func api(_ a: AutoArchive) -> Double {
        switch a {
        case .never: 0
        case .afterWeek: 7
        case .afterTwoWeeks: 14
        case .afterMonth: 30
        }
    }

    static func cellular(_ s: String?) -> CellularDownloads? {
        switch s {
        case "never": .wifiOnly
        case "ask": .ask
        case "always": .allow
        default: nil
        }
    }

    static func api(_ c: CellularDownloads) -> String {
        switch c {
        case .wifiOnly: "never"
        case .ask: "ask"
        case .allow: "always"
        }
    }

    static func deletePlayed(_ hours: Double?) -> DeletePlayed? {
        guard let hours else { return nil }
        switch hours {
        case ..<0: return .never
        case 0: return .immediately
        case ..<100: return .after24h
        default: return .afterWeek
        }
    }

    static func api(_ d: DeletePlayed) -> Double {
        switch d {
        case .immediately: 0
        case .after24h: 24
        case .afterWeek: 168
        case .never: -1
        }
    }

    static let gib = 1024.0 * 1024 * 1024

    /// A number or "all". Anything else is "not set".
    static func keepLatest(_ v: JSONValue?) -> KeepLatest? {
        if let n = v?.number { return .latest(Int(n)) }
        return v?.string == "all" ? .all : nil
    }

    static func api(_ k: KeepLatest) -> JSONValue {
        switch k {
        case .all: .string("all")
        case let .latest(n): .number(Double(n))
        }
    }

    static func global(_ o: [String: JSONValue]) -> GlobalSettings {
        var g = GlobalSettings.defaults
        if let v = o["playbackSpeed"]?.number { g.speed = v }
        if let v = o["smartSpeed"]?.bool { g.smartSpeed = v }
        if let v = o["voiceBoost"]?.bool { g.voiceBoost = v }
        if let v = o["timePitch"]?.string.flatMap(TimePitchAlgorithm.init(rawValue:)) { g.timePitch = v }
        if let v = o["skipIntroSeconds"]?.number { g.skipIntro = v }
        if let v = o["skipOutroSeconds"]?.number { g.skipOutro = v }
        if let v = autoAdd(o["newEpisodes"]?.string) { g.autoAdd = v }
        if let v = o["autoDownload"]?.string { g.autoDownload = v != "never" }
        // Not the global row's `keepLatestDownloaded`: that's old apps' download count (decisions.md, 25 Oct).
        if let v = keepLatest(o["keepLatest"]) { g.keepLatest = v }
        if let v = o["notifications"]?.bool { g.notifications = v }
        if let v = o["episodeOrder"]?.string.flatMap(EpisodeOrder.init(rawValue:)) { g.episodeOrder = v }
        if let v = autoArchive(o["autoArchiveUnplayedAfterDays"]?.number) { g.autoArchive = v }
        if let v = o["skipBackSeconds"]?.number { g.skipBack = v }
        if let v = o["skipForwardSeconds"]?.number { g.skipForward = v }
        if let v = o["remoteNextPrevious"]?.string { g.headphoneMapping = v == "chapter" ? .chapters : .skip }
        if let v = o["autoRewind"]?.bool { g.autoRewind = v }
        if let v = o["advanceToNext"]?.bool { g.autoAdvance = v }
        if let v = o["sleepFadeOut"]?.bool { g.sleepFadeOut = v }
        if let v = o["shakeToRestartSleep"]?.bool { g.shakeToRestartSleep = v }
        if let v = cellular(o["cellularDownloads"]?.string) { g.cellularDownloads = v }
        if let v = deletePlayed(o["deletePlayedAfterHours"]?.number) { g.deletePlayed = v }
        if let v = o["storageCapBytes"]?.number { g.storageCapGB = (v / gib).rounded() }
        return g
    }

    static func podcast(_ podcastId: String, _ o: [String: JSONValue]) -> PodcastSettings {
        var s = PodcastSettings(podcastId: podcastId)
        s.speed = o["playbackSpeed"]?.number
        s.smartSpeed = o["smartSpeed"]?.bool
        s.voiceBoost = o["voiceBoost"]?.bool
        s.timePitch = o["timePitch"]?.string.flatMap(TimePitchAlgorithm.init(rawValue:))
        s.skipIntro = o["skipIntroSeconds"]?.number
        s.skipOutro = o["skipOutroSeconds"]?.number
        s.autoAdd = autoAdd(o["newEpisodes"]?.string)
        s.autoDownload = o["autoDownload"]?.string.map { $0 != "never" }
        s.keepLatest = keepLatest(o["keepLatestDownloaded"])
        s.notifications = o["notifications"]?.bool
        s.episodeOrder = o["episodeOrder"]?.string.flatMap(EpisodeOrder.init(rawValue:))
        s.autoArchive = autoArchive(o["autoArchiveUnplayedAfterDays"]?.number)
        if case let .array(a)? = o["skipChapterTitles"] { s.skipChapterRules = a.compactMap(\.string) }
        return s
    }

    /// The per-show fields as API values (`.null` for "use default").
    static func fields(_ s: PodcastSettings) -> [String: JSONValue] {
        [
            "playbackSpeed": JSONValue(s.speed),
            "smartSpeed": JSONValue(s.smartSpeed),
            "voiceBoost": JSONValue(s.voiceBoost),
            "timePitch": JSONValue(s.timePitch?.rawValue),
            "skipIntroSeconds": JSONValue(s.skipIntro),
            "skipOutroSeconds": JSONValue(s.skipOutro),
            "newEpisodes": JSONValue(s.autoAdd.map(api)),
            "autoDownload": JSONValue(s.autoDownload.map { $0 ? "upNext" : "never" }),
            "keepLatestDownloaded": s.keepLatest.map(api) ?? .null,
            "notifications": JSONValue(s.notifications),
            "episodeOrder": JSONValue(s.episodeOrder?.rawValue),
            "autoArchiveUnplayedAfterDays": JSONValue(s.autoArchive.map(api)),
            "skipChapterTitles": s.skipChapterRules.map { .array($0.map(JSONValue.string)) } ?? .null,
        ]
    }

    static func fields(_ g: GlobalSettings) -> [String: JSONValue] {
        [
            "playbackSpeed": .number(g.speed),
            "smartSpeed": .bool(g.smartSpeed),
            "voiceBoost": .bool(g.voiceBoost),
            "timePitch": .string(g.timePitch.rawValue),
            "skipIntroSeconds": .number(g.skipIntro),
            "skipOutroSeconds": .number(g.skipOutro),
            "newEpisodes": .string(api(g.autoAdd)),
            "autoDownload": .string(g.autoDownload ? "upNext" : "never"),
            "keepLatest": api(g.keepLatest),
            "notifications": .bool(g.notifications),
            "episodeOrder": .string(g.episodeOrder.rawValue),
            "autoArchiveUnplayedAfterDays": .number(api(g.autoArchive)),
            "skipBackSeconds": .number(g.skipBack),
            "skipForwardSeconds": .number(g.skipForward),
            "remoteNextPrevious": .string(g.headphoneMapping == .chapters ? "chapter" : "skip"),
            "autoRewind": .bool(g.autoRewind),
            "advanceToNext": .bool(g.autoAdvance),
            "sleepFadeOut": .bool(g.sleepFadeOut),
            "shakeToRestartSleep": .bool(g.shakeToRestartSleep),
            "cellularDownloads": .string(api(g.cellularDownloads)),
            "deletePlayedAfterHours": .number(api(g.deletePlayed)),
            "storageCapBytes": .number(g.storageCapGB * gib),
        ]
    }

    /// Only the fields that changed, so a patch never stamps a field the user didn't touch (the
    /// server keeps a last-writer-wins clock per field).
    static func patch(from old: [String: JSONValue], to new: [String: JSONValue]) -> [String: JSONValue] {
        new.filter { old[$0.key] != $0.value }
    }
}
