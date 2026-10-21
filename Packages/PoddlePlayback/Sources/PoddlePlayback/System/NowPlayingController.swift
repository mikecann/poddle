import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Lock screen / Control Centre metadata.
@MainActor
final class NowPlayingController {
    private var artworkKey: Data?
    private var artwork: MPMediaItemArtwork?

    struct Snapshot {
        var item: PlaybackItem
        var chapter: Chapter?
        var chapterIndex: Int?
        var position: Double
        var duration: Double
        var rate: Double
        var isPlaying: Bool
    }

    func update(_ s: Snapshot) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.item.title,
            MPMediaItemPropertyArtist: s.item.showTitle,
            MPMediaItemPropertyAlbumTitle: s.chapter?.title ?? s.item.showTitle,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPMediaItemPropertyPlaybackDuration: s.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: s.position,
            MPNowPlayingInfoPropertyPlaybackRate: s.isPlaying ? s.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: s.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let index = s.chapterIndex {
            info[MPNowPlayingInfoPropertyChapterNumber] = index
            info[MPNowPlayingInfoPropertyChapterCount] = s.item.chapters.count
        }
        if let artwork = makeArtwork(s.chapter?.artwork ?? s.item.artwork) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = s.isPlaying ? .playing : .paused
        #endif
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func makeArtwork(_ data: Data?) -> MPMediaItemArtwork? {
        guard let data else { return nil }
        if data == artworkKey { return artwork }
        artworkKey = data
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { artwork = nil; return nil }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in UIImage(data: data) ?? UIImage() }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { artwork = nil; return nil }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in NSImage(data: data) ?? NSImage() }
        #endif
        return artwork
    }
}
