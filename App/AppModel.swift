import SwiftUI
import PoddleKit

enum Tab: String, CaseIterable, Identifiable, Hashable {
    case upNext, library, discover, stats, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext: "Up Next"
        case .library: "Library"
        case .discover: "Discover"
        case .stats: "Stats"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .upNext: "square.stack"
        case .library: "square.grid.2x2"
        case .discover: "safari"
        case .stats: "chart.bar"
        case .profile: "person.crop.circle"
        }
    }

    var selectedImage: String {
        switch self {
        case .upNext: "square.stack.fill"
        case .library: "square.grid.2x2.fill"
        case .discover: "safari.fill"
        case .stats: "chart.bar.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
}

enum Route: Hashable {
    case podcast(String)
    case episode(String)
    case settings
    case importOvercast
}

/// Now Playing's three pages (decisions.md), left to right.
enum NowPlayingPage: Hashable, CaseIterable {
    case notes, player, settings
}

enum SheetRoute: Identifiable, Hashable {
    case showSettings(podcastId: String)
    case queue
    case episode(String)

    var id: String {
        switch self {
        case let .showSettings(p): "settings-\(p)"
        case .queue: "queue"
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
    /// Open Now Playing once the sheet that asked for it has gone (see `openNowPlaying`).
    var nowPlayingAfterSheet = false
    var nowPlayingPage: NowPlayingPage = .player
    /// The Undo toast for destructive actions.
    let undo = UndoCenter()
    /// What Poddle, the companion, is up to.
    let companion = CompanionModel()
    var showYearInReview = false
    /// Pre-filled search for screenshots.
    var discoverQuery = ""
    var fakeClipboard: String?
    var importDemo = false
    /// Running on sample data (`-PoddleMock`, or a screenshot run).
    var isMock = false
    /// Tapped download over mobile data in Wi-Fi-only mode: ask what to do (decisions.md).
    var mobilePromptEpisodeId: String?
    /// Start times from shared links (`/e/<id>?t=`), which the episode page offers to play from.
    var linkStarts: [String: Double] = [:]
    /// A shared link that went nowhere (a private feed's, or a deleted episode).
    var linkNotFound = false
    /// Whose cache, outbox and downloads to wipe from this device once the store has switched
    /// away from them (they just deleted their account; `PoddleApp.accountChanged`).
    var wipeAfterSignOut: String?

    /// Opens Now Playing from anywhere. From a sheet (the episode page opened by a share link)
    /// the sheet goes first: a full-screen cover can't come up while it's showing, so playing from
    /// there used to start the episode and leave you on the sheet.
    func openNowPlaying() {
        if sheet != nil {
            nowPlayingAfterSheet = true
            sheet = nil
        } else {
            showNowPlaying = true
        }
    }

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

    /// A website link (`https://poddle.mikecann.app/e/<id>?t=…`, `/s/<id>`, or `poddle://e/…` from
    /// its "Open in Poddle" button): fetch the episode or show if it isn't here yet, then show it.
    func open(_ url: URL, store: PoddleStore) {
        guard let target = ShareLinks.parse(url) else { return }
        Task {
            guard await store.loadShared(target) else {
                linkNotFound = true
                return
            }
            switch target {
            case let .episode(id, startAt):
                if let startAt { linkStarts[id] = startAt } else { linkStarts[id] = nil }
                showNowPlaying = false
                sheet = .episode(id)
            case let .show(id):
                goToShow(id)
            }
        }
    }

    /// `-PoddleScreen <name>` opens a screen directly, for automated screenshots.
    func applyLaunchScreen(_ name: String, player: any PoddlePlayer, store: PoddleStore) {
        // The sample data's IDs, or real ones when screenshotting live data (`-PoddleLive YES`).
        let show = { (mockId: String) in store.podcast(mockId) != nil ? mockId : store.library.first?.id ?? mockId }
        let episode = store.episode("ep_syntax_912") != nil ? "ep_syntax_912" : store.queue.first?.id ?? ""
        switch name {
        case "upNext": tab = .upNext
        case "library": tab = .library; UserDefaults.standard.set("grid", forKey: "libraryLayout")
        case "libraryList": tab = .library; UserDefaults.standard.set("list", forKey: "libraryLayout")
        case "podcast": tab = .library; paths[.library] = [.podcast(show("pod_syntax"))]
        case "showSettings":
            tab = .library
            paths[.library] = [.podcast(show("pod_conan"))]
            sheet = .showSettings(podcastId: show("pod_conan"))
        case "episode": tab = .upNext; paths[.upNext] = [.episode(episode)]
        case "settings", "profile": tab = .profile
        case "import", "importDone":
            tab = .profile
            paths[.profile] = [.importOvercast]
            importDemo = name == "importDone"
        case "discover":
            tab = .discover
            discoverQuery = UserDefaults.standard.string(forKey: "PoddleQuery") ?? "ai pod"
            if isMock { fakeClipboard = "https://podcast.mikecann.app/feed/9f2c6b1e7d0a4c55?token=sk_live_7f3a91" }
        case "upNextEmpty": tab = .upNext; store.clearQueue(keeping: player.currentEpisodeId)
        case "notFound": tab = .library; paths[.library] = [.podcast("missing")]
        case "discoverEmpty": tab = .discover
        case "sleepTimer": showNowPlaying = true; player.setSleepMinutes(30)
        // The companion's finished-episode moment, a beat after launch.
        case "celebrate":
            tab = .upNext
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                companion.celebrate()
            }
        // The companion recording: bopping while it plays, then paused, and dozing a few seconds later.
        case "companionDemo":
            tab = .upNext
            Task {
                try? await Task.sleep(for: .seconds(6))
                player.pause()
            }
        case "stats": tab = .stats
        case "yearInReview": tab = .stats; showYearInReview = true
        case "nowPlaying": showNowPlaying = true
        case "speed", "npSettings": showNowPlaying = true; nowPlayingPage = .settings
        case "npNotes", "chapters": showNowPlaying = true; nowPlayingPage = .notes
        case "queue": showNowPlaying = true; nowPlayingSheet = .queue
        // Undo checks: archive or remove the second Up Next item through the real actions, and
        // optionally press Undo a moment later.
        case "undoArchive", "undoArchiveUndone", "undoRemove", "undoRemoveUndone":
            tab = .upNext
            let target = store.upNext(excluding: player.currentEpisodeId).dropFirst().first
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard let target else { return }
                let actions = EpisodeActions(store: store, player: player, app: self)
                if name.hasPrefix("undoArchive") { actions.archive(target) } else { actions.removeFromUpNext(target) }
                guard name.hasSuffix("Undone") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                undo.undo()
            }
        default: break
        }
    }
}
