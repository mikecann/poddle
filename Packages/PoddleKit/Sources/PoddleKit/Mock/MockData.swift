import Foundation

/// Sample library matching the approved designs: Mike's real shows, the Up Next in c-p0, the
/// Syntax page in c-p3, Conan's settings in c-p4 and the stats in c-p7.
public enum MockData {
    public static let playingEpisodeId = "ep_dwarkesh_rl"
    public static let playingPosition: Double = 41 * 60 + 8
    /// Full notes for the playing episode, with links and timestamps, like a real feed's.
    static let playingShowNotes = """
        <p>How the labs are scaling <strong>reinforcement learning</strong>, why evals keep breaking, and what it means for 2027.</p>\
        <p>Sponsored by <a href="https://example.com/sponsor">Sponsor Co</a>. Transcript at https://www.dwarkesh.com/p/rl-scaling.</p>\
        <h3>Timestamps</h3>\
        <ul><li>(00:00:00) Intro</li><li>(00:04:12) Why RL is back</li><li>(00:18:40) Evals keep breaking</li>\
        <li>(00:41:08) Compute and the 2027 question</li><li>(01:12:30) What happens to software jobs</li>\
        <li>(01:38:55) Lightning round</li></ul>\
        <p><em>Thanks to everyone who sent in questions &amp; corrections.</em></p>
        """

    struct Ep {
        var id: String
        var title: String
        var daysAgo: Double
        var minutes: Double
        var played = false
        var position: Double = 0
        var inbox = false
        var starred = false
        var notes = ""
    }

    struct Show {
        var podcast: Podcast
        var episodes: [Ep]
    }

    static func shows() -> [Show] {
        [
            Show(
                podcast: Podcast(
                    id: "pod_syntax", feedURL: "https://feed.syntax.fm/rss", title: "Syntax",
                    author: "Wes Bos & Scott Tolinski",
                    description: "Full-stack web dev with a side of tasty treats. Frameworks, CSS, tooling and the odd rant about build configs. Wes and Scott have been doing this since 2017 and still argue about semicolons.",
                    category: "Technology", appleId: "1253186678"
                ),
                episodes: [
                    Ep(id: "ep_syntax_912", title: "912: Vite 7, Rolldown and the end of config", daysAgo: 0.2, minutes: 54, inbox: true,
                       notes: "Vite 7 lands with Rolldown under the hood. We dig into what changes for your config (mostly: you can delete it)."),
                    Ep(id: "ep_syntax_911", title: "911: CSS anchor positioning finally lands", daysAgo: 2, minutes: 22, inbox: true,
                       notes: "Tooltips, popovers and dropdowns without a single line of JavaScript. Scott shows off anchor() and position-try."),
                    Ep(id: "ep_syntax_910", title: "Svelte 5 runes, one year later", daysAgo: 5, minutes: 105, position: 37 * 60,
                       notes: "A year of runes in production. What stuck, what we'd do differently, and whether $effect was a mistake."),
                    Ep(id: "ep_syntax_909", title: "909: Local-first is having a moment", daysAgo: 7, minutes: 47, played: true),
                    Ep(id: "ep_syntax_908", title: "908: The State of JS 2026 results", daysAgo: 9, minutes: 61, played: true),
                    Ep(id: "ep_syntax_907", title: "907: Supper Club × the Bun team", daysAgo: 12, minutes: 58, played: true, starred: true),
                    Ep(id: "ep_syntax_906", title: "906: Tailwind 5 first look", daysAgo: 14, minutes: 39, played: true),
                    Ep(id: "ep_syntax_905", title: "905: Hasty Treat: debugging with agents", daysAgo: 16, minutes: 18, played: true),
                    Ep(id: "ep_syntax_904", title: "904: TypeScript 7 and the Go compiler", daysAgo: 19, minutes: 52, played: true),
                    Ep(id: "ep_syntax_903", title: "903: Server components, two years on", daysAgo: 21, minutes: 66, played: true),
                    Ep(id: "ep_syntax_902", title: "902: Our 2026 desk setups", daysAgo: 23, minutes: 44, played: true),
                    Ep(id: "ep_syntax_901", title: "901: Edge databases explained", daysAgo: 26, minutes: 49, played: true),
                    Ep(id: "ep_syntax_900", title: "900: The episode 900 spectacular", daysAgo: 28, minutes: 83, played: true, starred: true),
                    Ep(id: "ep_syntax_899", title: "899: Hasty Treat: view transitions", daysAgo: 30.5, minutes: 21, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_dwarkesh", feedURL: "https://api.substack.com/feed/podcast/69345.rss", title: "Dwarkesh Podcast",
                    author: "Dwarkesh Patel",
                    description: "Deeply researched interviews about AI, history, economics and the long-run future.",
                    category: "Science", appleId: "1516093381"
                ),
                episodes: [
                    Ep(id: playingEpisodeId, title: "Inside the RL scaling race", daysAgo: 3, minutes: 113.8, position: playingPosition,
                       notes: "How the labs are scaling reinforcement learning, why evals keep breaking, and what it means for 2027."),
                    Ep(id: "ep_dwarkesh_economy", title: "The economics of a million AI workers", daysAgo: 13, minutes: 142, played: true, starred: true),
                    Ep(id: "ep_dwarkesh_england", title: "Why the industrial revolution happened in England", daysAgo: 27, minutes: 98, played: true),
                    Ep(id: "ep_dwarkesh_empires", title: "A historian on how empires run out of money", daysAgo: 41, minutes: 121, played: true),
                    Ep(id: "ep_dwarkesh_science", title: "What would it take to automate science?", daysAgo: 55, minutes: 104, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_conan", feedURL: "https://feeds.simplecast.com/dHoohVNH", title: "Conan O'Brien Needs a Friend",
                    author: "Team Coco & Earwolf",
                    description: "Conan O'Brien, Sona Movsesian and Matt Gourley talk to people Conan would like to be friends with. It rarely works out.",
                    category: "Comedy", appleId: "1438054347"
                ),
                episodes: [
                    Ep(id: "ep_conan_mail", title: "Sona and Matt answer your mail", daysAgo: 1.4, minutes: 62.4,
                       notes: "Listener questions, a disputed parking ticket and Conan's new hat."),
                    Ep(id: "ep_conan_failure", title: "Conan's summer of failure", daysAgo: 8, minutes: 71, played: true),
                    Ep(id: "ep_conan_largo", title: "Live from the Largo", daysAgo: 15, minutes: 66, played: true),
                    Ep(id: "ep_conan_fan", title: "Fan Corner: the boat", daysAgo: 22, minutes: 54, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_latent", feedURL: "https://api.substack.com/feed/podcast/1084089.rss", title: "Latent Space",
                    author: "swyx & Alessio",
                    description: "The podcast by and for AI engineers. Agents, evals, inference and the people building them.",
                    category: "Technology", appleId: "1674008350"
                ),
                episodes: [
                    Ep(id: "ep_latent_sandbox", title: "Why every agent needs a sandbox", daysAgo: 4, minutes: 115.2),
                    Ep(id: "ep_latent_inference", title: "The inference economy", daysAgo: 1, minutes: 74, inbox: true,
                       notes: "Where the money goes when tokens get cheap."),
                    Ep(id: "ep_latent_evals", title: "Evals are the new unit tests", daysAgo: 11, minutes: 81, played: true),
                    Ep(id: "ep_latent_mcp", title: "MCP, one year in", daysAgo: 18, minutes: 69, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_mike", feedURL: "https://podcast.mikecann.app/feed/9f2c6b1e7d0a4c55?token=sk_live_7f3a91", isPrivate: true,
                    credentialRef: "feed.pod_mike", title: "Mike Pod", author: "Mike Cann",
                    description: "A private daily AI briefing on the things Mike cares about. Generated every morning at 6am.",
                    category: "Technology"
                ),
                episodes: [
                    Ep(id: "ep_mike_tue", title: "Tuesday briefing: Convex, Bun 2 and a new Opus", daysAgo: 0.3, minutes: 16.2),
                    Ep(id: "ep_mike_mon", title: "Monday briefing: Xcode 27.1 and the week ahead", daysAgo: 1.3, minutes: 14, played: true),
                    Ep(id: "ep_mike_sun", title: "Sunday long read: local-first sync engines", daysAgo: 2.3, minutes: 22, played: true),
                    Ep(id: "ep_mike_sat", title: "Saturday briefing: what shipped this week", daysAgo: 3.3, minutes: 12, played: true),
                    Ep(id: "ep_mike_fri", title: "Friday briefing: Convex components, Swift 6.4", daysAgo: 4.3, minutes: 15, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_atp", feedURL: "https://atp.fm/rss", title: "Accidental Tech Podcast",
                    author: "Marco Arment, Casey Liss, John Siracusa",
                    description: "Three nerds discussing tech, Apple, programming, and loosely related matters.",
                    category: "Technology", appleId: "617416468"
                ),
                episodes: [
                    Ep(id: "ep_atp_649", title: "649: Six Months of Liquid Glass", daysAgo: 6, minutes: 140.4,
                       notes: "Half a year in. What's settled, what's still weird, and John's ongoing feud with toolbar buttons."),
                    Ep(id: "ep_atp_648", title: "648: The Mac Pro Question", daysAgo: 13, minutes: 131, played: true),
                    Ep(id: "ep_atp_647", title: "647: A Very Bad Router", daysAgo: 20, minutes: 126, played: true),
                    Ep(id: "ep_atp_646", title: "646: Batteries Not Included", daysAgo: 27, minutes: 138, played: true, starred: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_hardfork", feedURL: "https://feeds.simplecast.com/l2i9YnTd", title: "Hard Fork",
                    author: "The New York Times",
                    description: "Kevin Roose and Casey Newton explore and make sense of the latest in tech.",
                    category: "Technology", appleId: "1528594034"
                ),
                episodes: [
                    Ep(id: "ep_hardfork_shop", title: "The week AI agents learned to shop for us", daysAgo: 2, minutes: 73.8,
                       notes: "Agents with credit cards, a robot vacuum update and a listener's very specific question about trains."),
                    Ep(id: "ep_hardfork_bubble", title: "Is the AI bubble about to pop?", daysAgo: 0.9, minutes: 66, inbox: true),
                    Ep(id: "ep_hardfork_glasses", title: "We tried the new smart glasses", daysAgo: 9, minutes: 71, played: true),
                    Ep(id: "ep_hardfork_kids", title: "Kids, phones and the school ban", daysAgo: 16, minutes: 64, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_changelog", feedURL: "https://changelog.com/podcast/feed", title: "The Changelog",
                    author: "Changelog Media",
                    description: "Software's best weekly news brief, deep technical interviews and talk show.",
                    category: "Technology", appleId: "341623264"
                ),
                episodes: [
                    Ep(id: "ep_changelog_kaizen", title: "Kaizen! The CDN is finally ours", daysAgo: 1.6, minutes: 88, inbox: true),
                    Ep(id: "ep_changelog_news", title: "Changelog News: the npm worm, again", daysAgo: 3.2, minutes: 11, inbox: true),
                    Ep(id: "ep_changelog_htmx", title: "Hypermedia is back, baby", daysAgo: 10, minutes: 79, played: true),
                ]
            ),
            Show(
                podcast: Podcast(
                    id: "pod_lex", feedURL: "https://lexfridman.com/feed/podcast/", title: "Lex Fridman Podcast",
                    author: "Lex Fridman",
                    description: "Conversations about science, technology, history, philosophy and the nature of intelligence.",
                    category: "Science", appleId: "1434243584"
                ),
                episodes: [
                    Ep(id: "ep_lex_rome", title: "The fall of the Roman Republic, in five hours", daysAgo: 5.5, minutes: 302, inbox: true),
                    Ep(id: "ep_lex_chips", title: "Chips, fabs and the future of compute", daysAgo: 19, minutes: 214, played: true),
                ]
            ),
        ]
    }

    /// Queue order from the Up Next design, with the playing Dwarkesh episode at the head.
    public static let queueOrder = [
        playingEpisodeId, "ep_syntax_910", "ep_hardfork_shop", "ep_conan_mail", "ep_latent_sandbox", "ep_mike_tue", "ep_atp_649",
    ]

    public static func snapshot(now: Date = Date()) -> LibrarySnapshot {
        let nowMs = now.timeIntervalSince1970 * 1000
        let day = 86_400_000.0
        var podcasts: [String: Podcast] = [:]
        var episodes: [String: Episode] = [:]
        var states: [String: EpisodeState] = [:]

        for (i, show) in shows().enumerated() {
            var p = show.podcast
            p.subscribedAt = nowMs - Double(400 + i * 170) * day
            p.lastFetchedAt = nowMs - 600_000
            podcasts[p.id] = p
            for e in show.episodes {
                let pub = (nowMs - e.daysAgo * day).rounded()
                let slug = e.id.replacingOccurrences(of: "ep_", with: "")
                episodes[e.id] = Episode(
                    id: e.id, podcastId: p.id, guid: "guid-\(slug)",
                    enclosureURL: "https://cdn.example.com/\(slug).mp3", enclosureLength: e.minutes * 60 * 16_000,
                    title: e.title, pubDate: pub, duration: (e.minutes * 60).rounded(),
                    showNotesHTML: e.id == playingEpisodeId ? playingShowNotes : e.notes.isEmpty ? "<p>\(e.title).</p>" : "<p>\(e.notes)</p>",
                    chaptersURL: e.id == playingEpisodeId || e.id == "ep_atp_649" ? "https://cdn.example.com/\(slug).json" : nil
                )
                states[e.id] = EpisodeState(
                    episodeId: e.id, position: e.position, positionUpdatedAt: pub, played: e.played,
                    playedAt: e.played ? pub + day / 2 : nil, starredAt: e.starred ? pub + day / 2 : nil,
                    inboxAt: e.inbox ? pub : nil, updatedAt: pub
                )
            }
        }

        let keys = OrderKey.sequence(queueOrder.count)
        let queue = zip(queueOrder, keys).map { id, key in
            QueueItem(id: "q_\(id)", episodeId: id, orderKey: key, addedAt: nowMs - 3 * day, addedBy: id == "ep_mike_tue" ? .priority : .manual)
        }

        let settings: [String: PodcastSettings] = [
            "pod_dwarkesh": PodcastSettings(podcastId: "pod_dwarkesh", speed: 1.4),
            "pod_conan": PodcastSettings(
                podcastId: "pod_conan", speed: 1.2, voiceBoost: false, skipIntro: 45, autoAdd: .upNextBottom,
                keepLatest: .latest(5), notifications: false
            ),
            "pod_syntax": PodcastSettings(podcastId: "pod_syntax", autoAdd: .upNextTop),
            "pod_mike": PodcastSettings(podcastId: "pod_mike", autoAdd: .upNextTop, notifications: true),
            "pod_lex": PodcastSettings(podcastId: "pod_lex", smartSpeed: false),
        ]

        return LibrarySnapshot(
            podcasts: podcasts, episodes: episodes, states: states, queue: queue,
            global: GlobalSettings(speed: 1.8), podcastSettings: settings
        )
    }

    /// Real, short public episodes (Changelog News) for checking actual playback against sample data.
    public static let realEnclosures: [(url: String, duration: Double)] = [
        ("https://cdn.changelog.com/uploads/news/183/changelog-news-183.mp3", 310),
        ("https://cdn.changelog.com/uploads/news/182/changelog-news-182.mp3", 468),
        ("https://cdn.changelog.com/uploads/news/181/changelog-news-181.mp3", 384),
        ("https://cdn.changelog.com/uploads/news/180/changelog-news-180.mp3", 455),
        ("https://cdn.changelog.com/uploads/news/179/changelog-news-179.mp3", 526),
        ("https://cdn.changelog.com/uploads/news/178/changelog-news-178.mp3", 410),
        ("https://cdn.changelog.com/uploads/news/177/changelog-news-177.mp3", 374),
    ]

    /// The sample library with the top of the queue pointing at `realEnclosures`, from the start.
    public static func withRealAudio(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        var s = snapshot
        for (item, real) in zip(s.queue, realEnclosures) {
            s.episodes[item.episodeId]?.enclosureURL = real.url
            s.episodes[item.episodeId]?.duration = real.duration
            s.episodes[item.episodeId]?.enclosureLength = nil
            s.states[item.episodeId]?.position = 0
        }
        return s
    }

    /// Everything queued is downloaded except Latent Space, plus the newest Syntax.
    public static func downloads() -> [String: Download] {
        let ids = queueOrder.filter { $0 != "ep_latent_sandbox" } + ["ep_syntax_912", "ep_changelog_news"]
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, Download(episodeId: $0, state: .done, bytes: 48_000_000)) })
    }

    public static func chapters(for episodeId: String, duration: Double) -> [Chapter] {
        switch episodeId {
        case playingEpisodeId:
            let titles: [(Double, String)] = [
                (0, "Intro"), (300, "Where RL is today"), (1050, "Compute budgets"), (1800, "The data wall"),
                (2280, "Why the evals keep breaking"), (3300, "Reward hacking"), (4200, "Labs and secrecy"),
                (5400, "What happens in 2027"), (6300, "Closing thoughts"),
            ]
            return chapterList(titles, duration: duration)
        case "ep_atp_649":
            let titles: [(Double, String)] = [
                (0, "Follow-up"), (1500, "Liquid Glass, six months in"), (4200, "Sponsor: Squarespace"),
                (4320, "Toolbar buttons"), (6600, "#askatp"), (7800, "After show"),
            ]
            return chapterList(titles, duration: duration)
        default:
            return []
        }
    }

    static func chapterList(_ titles: [(Double, String)], duration: Double) -> [Chapter] {
        titles.enumerated().map { i, t in
            Chapter(start: t.0, end: i + 1 < titles.count ? titles[i + 1].0 : duration, title: t.1)
        }
    }

    // MARK: Stats

    /// 7×24 listening heatmap shaped like a commuter's week (the same shape as the design).
    public static func heatmap() -> [[Double]] {
        (0..<7).map { d in
            (0..<24).map { h in
                let weekday = d < 5
                let noise = Double((d * 31 + h * 17) % 7) / 28
                var v: Double
                if weekday {
                    let peaks: [Int: Double] = [7: 0.95, 8: 0.75, 12: 0.42, 17: 0.7, 18: 0.55, 20: 0.32, 21: 0.38, 22: 0.18]
                    v = peaks[h] ?? ((9...16).contains(h) ? 0.1 : (6...23).contains(h) ? 0.06 : 0)
                    if d == 4 && h >= 17 { v *= 0.5 }
                } else {
                    let peaks: [Int: Double] = [8: 0.6, 9: 0.85, 10: 0.6, 11: 0.3, 14: 0.35, 15: 0.42, 16: 0.3, 21: 0.3, 22: 0.2]
                    v = peaks[h] ?? ((7...22).contains(h) ? 0.08 : 0)
                }
                return v > 0 ? min(1, v + noise) : 0
            }
        }
    }

    public static let topShows2026: [TopShow] = [
        TopShow(podcastId: "pod_syntax", title: "Syntax", seconds: 96 * 3600),
        TopShow(podcastId: "pod_dwarkesh", title: "Dwarkesh Podcast", seconds: 81 * 3600),
        TopShow(podcastId: "pod_atp", title: "Accidental Tech Podcast", seconds: 74 * 3600),
        TopShow(podcastId: "pod_hardfork", title: "Hard Fork", seconds: 58 * 3600),
        TopShow(podcastId: "pod_mike", title: "Mike Pod", seconds: 41 * 3600, isPrivate: true),
        TopShow(podcastId: "pod_latent", title: "Latent Space", seconds: 33 * 3600),
        TopShow(podcastId: "pod_conan", title: "Conan O'Brien Needs a Friend", seconds: 27 * 3600),
        TopShow(podcastId: "pod_changelog", title: "The Changelog", seconds: 22 * 3600),
        TopShow(podcastId: "pod_lex", title: "Lex Fridman Podcast", seconds: 19 * 3600),
    ]

    public static func stats(year: Int, currentYear: Int) -> StatsSummary {
        // 2026 matches the design. Earlier years shrink back towards 2014.
        let scale = year == currentYear ? 1.0 : max(0.25, 1.0 - Double(currentYear - year) * 0.07)
        let isCurrent = year == currentYear
        return StatsSummary(
            year: year,
            listenedSeconds: 612 * 3600 * scale,
            savedBySpeedSeconds: 121 * 3600 * scale,
            savedBySmartSpeedSeconds: 27 * 3600 * scale,
            currentStreakDays: isCurrent ? 41 : 0,
            bestStreakDays: isCurrent ? 41 : Int(29 * scale),
            previousBestStreakDays: 29,
            recentDays: [64, 72, 31, 58, 80, 77, 42, 69, 71, 66],
            heatmap: heatmap(),
            peakLabel: "7am weekdays",
            topShows: topShows2026.map { TopShow(podcastId: $0.podcastId, title: $0.title, seconds: $0.seconds * scale, isPrivate: $0.isPrivate) },
            showCount: 84,
            episodesCompleted: Int(1_041 * scale),
            averageSpeed: 1.8,
            estimatedBefore: isCurrent ? nil : Date(timeIntervalSince1970: 1_792_540_800).timeIntervalSince1970 * 1000
        )
    }

    public static func yearInReview(year: Int) -> YearInReview {
        let top = Array(topShows2026.prefix(5))
        let topTotal = top.reduce(0) { $0 + $1.seconds }
        return YearInReview(
            year: year, listenerName: "Mike", serial: 1, listenedSeconds: 612 * 3600,
            savedBySpeedSeconds: 121 * 3600, savedBySmartSpeedSeconds: 27 * 3600, topShows: top,
            otherShowCount: 79, otherShowsSeconds: 612 * 3600 - topTotal, usualSpeed: 1.8,
            peakHourLabel: "7am commute", longestStreakDays: 41, episodesCompleted: 1_041,
            biggestDayLabel: "Sat 14 Mar · 7h 12m", busiestMonth: "July", personality: "Early bird: 38% before 9am",
            newShows: 12, includesEstimates: false
        )
    }

    // MARK: Directory

    struct CatalogueEntry {
        var result: SearchResult
        var keywords: String
    }

    static let catalogue: [CatalogueEntry] = [
        .init(result: SearchResult(id: "apple_1674008350", title: "Latent Space", author: "swyx & Alessio", genre: "Technology",
                                   feedURL: "https://api.substack.com/feed/podcast/1084089.rss", appleId: "1674008350"),
              keywords: "ai engineering agents llm podcast"),
        .init(result: SearchResult(id: "apple_1406537385", title: "Practical AI", author: "Changelog Media", genre: "Technology",
                                   feedURL: "https://changelog.com/practicalai/feed", appleId: "1406537385"),
              keywords: "ai machine learning podcast"),
        .init(result: SearchResult(id: "apple_1668002688", title: "No Priors", author: "Sarah Guo & Elad Gil", genre: "Business",
                                   feedURL: "https://feeds.megaphone.fm/nopriors", appleId: "1668002688"),
              keywords: "ai startups venture podcast"),
        .init(result: SearchResult(id: "apple_1669813431", title: "The Cognitive Revolution", author: "Nathan Labenz", genre: "Technology",
                                   feedURL: "https://feeds.megaphone.fm/cognitiverevolution", appleId: "1669813431"),
              keywords: "ai interviews podcast"),
        .init(result: SearchResult(id: "apple_1516093381", title: "Dwarkesh Podcast", author: "Dwarkesh Patel", genre: "Science",
                                   feedURL: "https://api.substack.com/feed/podcast/69345.rss", appleId: "1516093381"),
              keywords: "ai history economics interviews podcast"),
        .init(result: SearchResult(id: "apple_1528594034", title: "Hard Fork", author: "The New York Times", genre: "Technology",
                                   feedURL: "https://feeds.simplecast.com/l2i9YnTd", appleId: "1528594034"),
              keywords: "ai tech news podcast"),
        .init(result: SearchResult(id: "apple_1434243584", title: "Lex Fridman Podcast", author: "Lex Fridman", genre: "Science",
                                   feedURL: "https://lexfridman.com/feed/podcast/", appleId: "1434243584"),
              keywords: "ai science interviews podcast"),
        .init(result: SearchResult(id: "apple_1253186678", title: "Syntax", author: "Wes Bos & Scott Tolinski", genre: "Technology",
                                   feedURL: "https://feed.syntax.fm/rss", appleId: "1253186678"),
              keywords: "web javascript css dev podcast"),
        .init(result: SearchResult(id: "apple_617416468", title: "Accidental Tech Podcast", author: "Marco Arment, Casey Liss, John Siracusa", genre: "Technology",
                                   feedURL: "https://atp.fm/rss", appleId: "617416468"),
              keywords: "apple mac programming podcast"),
        .init(result: SearchResult(id: "apple_1050462261", title: "Acquired", author: "Ben Gilbert and David Rosenthal", genre: "Business",
                                   feedURL: "https://feeds.transistor.fm/acquired", appleId: "1050462261"),
              keywords: "business history companies podcast"),
        .init(result: SearchResult(id: "apple_1296350485", title: "Darknet Diaries", author: "Jack Rhysider", genre: "Technology",
                                   feedURL: "https://feeds.megaphone.fm/darknetdiaries", appleId: "1296350485"),
              keywords: "security hacking stories podcast"),
        .init(result: SearchResult(id: "apple_394775318", title: "99% Invisible", author: "Roman Mars", genre: "Arts",
                                   feedURL: "https://feeds.simplecast.com/BqbsxVfO", appleId: "394775318"),
              keywords: "design architecture stories podcast"),
        .init(result: SearchResult(id: "apple_1011668648", title: "Decoder with Nilay Patel", author: "The Verge", genre: "Technology",
                                   feedURL: "https://feeds.megaphone.fm/recodedecode", appleId: "1011668648"),
              keywords: "tech business interviews ai podcast"),
    ]

    public static func search(_ term: String) -> SearchResponse {
        let tokens = term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return SearchResponse(results: [], totalCount: 0) }
        let matches = catalogue.filter { entry in
            let words = "\(entry.result.title) \(entry.result.author) \(entry.result.genre) \(entry.keywords)"
                .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return tokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }.map(\.result)
        return SearchResponse(results: matches, totalCount: matches.isEmpty ? 0 : matches.count * 17 + 6)
    }

    /// Episodes the mock server "fetches" when you follow something new.
    static func freshEpisodes(podcastId: String, title: String, now: Millis) -> [(Episode, EpisodeState)] {
        let day = 86_400_000.0
        let names = ["The year ahead", "Listener questions", "A deep dive", "What we got wrong", "Live from the conference"]
        return names.enumerated().map { i, name in
            let id = "\(podcastId)_ep\(i)"
            let pub = now - Double(i * 6 + 1) * day
            let ep = Episode(id: id, podcastId: podcastId, enclosureURL: "https://cdn.example.com/\(id).mp3",
                             title: name, pubDate: pub, duration: Double(35 + i * 9) * 60,
                             showNotesHTML: "<p>\(title): \(name.lowercased()).</p>")
            let state = EpisodeState(episodeId: id, inboxAt: i == 0 ? now : nil, updatedAt: now)
            return (ep, state)
        }
    }
}
