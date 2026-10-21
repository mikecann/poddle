#if DEBUG
import Foundation
import PoddleKit
import PoddlePlayback

/// `-PoddleAudioCheck YES` (debug builds): plays the queue head, logs position and rate every two
/// seconds, downloads it mid-stream to check the hand-off, then jumps near the end to check the
/// queue advances. Used with `-PoddleRealAudio YES` so the queue has real enclosures.
@MainActor
enum AudioCheck {
    static func run(_ services: AppServices) {
        if UserDefaults.standard.string(forKey: "PoddleAudioCheck") == "pauseResume" { pauseResume(services); return }
        guard UserDefaults.standard.bool(forKey: "PoddleAudioCheck"), let player = services.player as? EnginePlayer else { return }
        let store = services.store
        Task { @MainActor in
            func log(_ s: String) {
                print("[audiocheck] \(s)")
                fflush(stdout)
            }
            @MainActor func status() -> String {
                let id = player.currentEpisodeId ?? "-"
                return "ep=\(id) backend=\(player.backend) pos=\(String(format: "%.1f", player.position))/\(String(format: "%.0f", player.duration)) rate=\(player.rate) playing=\(player.isPlaying) buffering=\(player.isBuffering) download=\(store.download(for: id).map { "\($0.state.rawValue) \(Int((store.downloadProgress(id)?.fraction ?? $0.progress) * 100))%" } ?? "none") queue=\(store.queue.prefix(3).map(\.id))"
            }
            // Stream first: hold auto-downloads off until the check downloads it by hand.
            store.updateGlobal { $0.autoDownload = false }
            try? await Task.sleep(for: .seconds(1))
            player.resume()
            let first = player.currentEpisodeId
            log("start \(status())")
            var last = (wall: Date(), pos: player.position)
            for i in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                let now = (wall: Date(), pos: player.position)
                let speed = (now.pos - last.pos) / now.wall.timeIntervalSince(last.wall)
                last = now
                log("t=\(2 * (i + 1))s content/wall=\(String(format: "%.2f", speed)) \(status())")
                if i == 6, let id = player.currentEpisodeId {
                    log("download requested: \(store.download(id))")
                }
                if player.backend == .engine, player.currentEpisodeId == first, player.duration - player.position > 20 {
                    try? await Task.sleep(for: .seconds(4))
                    log("handed off to the engine; jumping near the end \(status())")
                    player.seek(to: player.duration - 8)
                    last = (Date(), player.position)
                }
                if player.currentEpisodeId != first {
                    log("advanced: \(status()) played(first)=\(first.map { store.snapshot.state($0).played } ?? false)")
                    if let mock = store.dataSource as? MockStore {
                        let sessions = await mock.sessions
                        log("sessions recorded: \(sessions.count) \(sessions.values.map { "\($0.episodeId) \(Int(($0.endedAt - $0.startedAt) / 1000))s wall, \(Int($0.contentEnd - $0.contentStart))s content at \($0.rate)" })")
                    }
                    try? await Task.sleep(for: .seconds(6))
                    log("after advance \(status())")
                    store.updateGlobal { $0.autoDownload = true }
                    return
                }
            }
        }
    }

    /// `-PoddleAudioCheck pauseResume`: safe on real data. Plays the queue head for 20 s, pauses for
    /// 5 s, resumes for 15 s and pauses, logging position and rate. Nothing is marked played or downloaded.
    static func pauseResume(_ services: AppServices) {
        guard let player = services.player as? EnginePlayer else { return }
        let store = services.store
        Task { @MainActor in
            func log(_ s: String) {
                print("[audiocheck] \(s)")
                fflush(stdout)
            }
            // Wait for the live queue (first launch has no cache).
            for _ in 0..<30 where player.currentEpisodeId == nil { try? await Task.sleep(for: .seconds(1)) }
            guard let id = player.currentEpisodeId else { return log("nothing queued") }
            let speed = store.snapshot.resolved(store.episode(id)?.podcastId ?? "").speed.value
            @MainActor func status() -> String {
                "ep=\(id) backend=\(player.backend) pos=\(String(format: "%.1f", player.position)) rate=\(player.rate) resolvedSpeed=\(speed) playing=\(player.isPlaying) buffering=\(player.isBuffering)"
            }
            @MainActor func run(_ seconds: Int) async {
                var last = (wall: Date(), pos: player.position)
                for _ in 0..<(seconds / 2) {
                    try? await Task.sleep(for: .seconds(2))
                    let now = (wall: Date(), pos: player.position)
                    log("content/wall=\(String(format: "%.2f", (now.pos - last.pos) / now.wall.timeIntervalSince(last.wall))) \(status())")
                    last = now
                }
            }
            log("start \(status())")
            player.resume()
            await run(20)
            player.pause()
            log("paused \(status())")
            let pausedAt = player.position
            try? await Task.sleep(for: .seconds(5))
            log("still paused, moved \(String(format: "%.1f", player.position - pausedAt)) s \(status())")
            player.resume()
            log("resumed \(status())")
            await run(14)
            player.pause()
            log("done \(status())")
        }
    }
}
#endif
