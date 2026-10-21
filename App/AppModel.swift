import SwiftUI
import PoddleKit

enum Tab: String, CaseIterable, Identifiable, Hashable {
    case upNext, inbox, library, discover, stats
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext: "Up Next"
        case .inbox: "Inbox"
        case .library: "Library"
        case .discover: "Discover"
        case .stats: "Stats"
        }
    }

    var systemImage: String {
        switch self {
        case .upNext: "square.stack"
        case .inbox: "tray"
        case .library: "square.grid.2x2"
        case .discover: "safari"
        case .stats: "chart.bar"
        }
    }
}

enum Route: Hashable {
    case podcast(String)
    case episode(String)
    case settings
    case importOvercast
}

enum SheetRoute: Identifiable, Hashable {
    case speed(podcastId: String)
    case showSettings(podcastId: String)
    case queueAndChapters
    case episode(String)

    var id: String {
        switch self {
        case let .speed(p): "speed-\(p)"
        case let .showSettings(p): "settings-\(p)"
        case .queueAndChapters: "queue"
        case let .episode(e): "episode-\(e)"
        }
    }
}

/// Navigation and presentation state for the whole app.
@MainActor
@Observable
final class AppModel {
    var tab: Tab = .upNext
    var paths: [Tab: [Route]] = [:]
    var sheet: SheetRoute?
    /// Sheets shown on top of Now Playing (it's its own presentation).
    var nowPlayingSheet: SheetRoute?
    var showNowPlaying = false
    var showYearInReview = false
    /// Pre-filled search for screenshots.
    var discoverQuery = ""
    var fakeClipboard: String?
    var importDemo = false
    /// Running on sample data (`-PoddleMock`, or a screenshot run).
    var isMock = false

    func path(_ tab: Tab) -> Binding<[Route]> {
        Binding { self.paths[tab] ?? [] } set: { self.paths[tab] = $0 }
    }

    func push(_ route: Route, on tab: Tab? = nil) {
        let t = tab ?? self.tab
        self.tab = t
        paths[t, default: []].append(route)
    }

    func goToShow(_ podcastId: String) {
        showNowPlaying = false
        sheet = nil
        tab = .library
        paths[.library] = [.podcast(podcastId)]
    }

    /// `-PoddleScreen <name>` opens a screen directly, for automated screenshots.
    func applyLaunchScreen(_ name: String, player: MockPlayer, store: PoddleStore) {
        // The sample data's IDs, or real ones when screenshotting live data (`-PoddleLive YES`).
        let show = { (mockId: String) in store.podcast(mockId) != nil ? mockId : store.library.first?.id ?? mockId }
        let episode = store.episode("ep_syntax_912") != nil ? "ep_syntax_912" : store.inbox.first?.id ?? store.queue.first?.id ?? ""
        switch name {
        case "upNext": tab = .upNext
        case "inbox": tab = .inbox
        case "library": tab = .library
        case "libraryList": tab = .library; UserDefaults.standard.set("list", forKey: "libraryLayout")
        case "podcast": tab = .library; paths[.library] = [.podcast(show("pod_syntax"))]
        case "showSettings":
            tab = .library
            paths[.library] = [.podcast(show("pod_conan"))]
            sheet = .showSettings(podcastId: show("pod_conan"))
        case "episode": tab = .inbox; paths[.inbox] = [.episode(episode)]
        case "settings": tab = .library; paths[.library] = [.settings]
        case "import", "importDone":
            tab = .library
            paths[.library] = [.settings, .importOvercast]
            importDemo = name == "importDone"
        case "discover":
            tab = .discover
            discoverQuery = UserDefaults.standard.string(forKey: "PoddleQuery") ?? "ai pod"
            if isMock { fakeClipboard = "https://podcast.mikecann.app/feed/9f2c6b1e7d0a4c55?token=sk_live_7f3a91" }
        case "stats": tab = .stats
        case "yearInReview": tab = .stats; showYearInReview = true
        case "nowPlaying": showNowPlaying = true
        case "speed": showNowPlaying = true; nowPlayingSheet = .speed(podcastId: player.item?.podcast.id ?? "")
        case "chapters": showNowPlaying = true; nowPlayingSheet = .queueAndChapters
        default: break
        }
    }
}
