import Foundation
import PoddleKit
import PoddlePlayback
#if os(iOS)
import UIKit
#endif

/// Everything long-lived behind the screens: the store, the player, downloads, session
/// forwarding and push. `current` lets the app delegate reach it.
@MainActor
final class AppServices {
    static var current: AppServices?

    let store: PoddleStore
    let app: AppModel
    let player: any PoddlePlayer
    let push: PushCoordinator
    let downloads: DownloadManager?
    let sessions: SessionForwarder?
    private var housekeeping: Task<Void, Never>?

    /// `fakePlayback` uses `MockPlayer` and sample downloads (previews and screenshots).
    init(store: PoddleStore, app: AppModel, fakePlayback: Bool) {
        self.store = store
        self.app = app
        push = PushCoordinator(store: store, app: app)
        if fakePlayback {
            downloads = nil
            sessions = nil
            player = MockPlayer(store: store)
        } else {
            let downloads = DownloadManager()
            store.downloader = downloads
            let sessions = SessionForwarder(
                dataSource: store.dataSource, deviceId: store.deviceId,
                persistURL: URL.applicationSupportDirectory.appending(path: "pending-sessions.json"))
            let player = EnginePlayer(store: store, downloads: downloads, sessions: sessions)
            downloads.onFileReady = { [weak player, weak downloads] id, url in
                if player?.currentEpisodeId == id {
                    // The engine measures it once it has the file; EnginePlayer stores the result.
                    player?.fileReady(url, for: id)
                } else {
                    Self.measureLoudness(url) { lufs in downloads?.setLoudness(lufs, for: id) }
                }
                AppServices.current?.runHousekeeping()
            }
            self.downloads = downloads
            self.sessions = sessions
            self.player = player
            startHousekeeping()
            #if os(iOS)
            followForeground(downloads)
            #endif
        }
        Self.current = self
    }

    /// Auto-downloads and cleanup now, and every 15 minutes while the app runs. Up Next changes
    /// call it too (RootView).
    func runHousekeeping() {
        store.runDownloadHousekeeping(playing: player.currentEpisodeId)
    }

    private func startHousekeeping() {
        housekeeping = Task { [weak self] in
            // Let the first snapshot land before deciding anything.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                self?.runHousekeeping()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    #if os(iOS)
    /// Tells downloads when the app leaves the foreground, so it can hand iOS everything waiting
    /// while that still counts as the foreground (`DownloadManager.setInForeground`). Resigning
    /// active comes first: locking the phone or swiping home, while it's still in front.
    private func followForeground(_ downloads: DownloadManager) {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { downloads.setInForeground(false) }
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { downloads.setInForeground(true) }
        }
    }
    #endif

    /// Woken in the background by a sync push (`apns:sendSyncWake`) or background app refresh:
    /// pull what's changed and start the downloads it needs, so new episodes are in Up Next and on
    /// the phone before Poddle's opened. `recheckFeeds` also asks Convex to re-check every feed, as
    /// coming to the foreground does. True if Up Next changed.
    func syncInBackground(recheckFeeds: Bool) async -> Bool {
        guard let live = store.dataSource as? LiveStore, await live.userId != nil else { return false }
        #if os(iOS)
        // A sync push also lands while the app's open. In the background it may have been launched
        // straight there, with no resign-active first.
        if UIApplication.shared.applicationState == .background { downloads?.setInForeground(false) }
        #endif
        let before = store.queue.map(\.id)
        if recheckFeeds { await store.refresh() }
        await live.syncNow()
        // The new snapshot reaches the store through its stream a moment later (LiveStore's
        // emit delay, then a hop to the main actor).
        try? await Task.sleep(for: .milliseconds(500))
        runHousekeeping()
        // The next launch reads Up Next from the cache, so it's there before the connection is.
        await live.flush()
        return store.queue.map(\.id) != before
    }

    /// Integrated loudness for Voice Boost, measured once per download off the main thread.
    nonisolated static func measureLoudness(_ url: URL, then store: @escaping @MainActor (Double) -> Void) {
        Task.detached(priority: .utility) {
            guard let lufs = try? LoudnessMeter.integratedLoudness(of: url) else { return }
            await store(lufs)
        }
    }
}
