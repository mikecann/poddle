import Foundation
import PoddleKit
import PoddlePlayback

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

    /// Integrated loudness for Voice Boost, measured once per download off the main thread.
    nonisolated static func measureLoudness(_ url: URL, then store: @escaping @MainActor (Double) -> Void) {
        Task.detached(priority: .utility) {
            guard let lufs = try? LoudnessMeter.integratedLoudness(of: url) else { return }
            await store(lufs)
        }
    }
}
