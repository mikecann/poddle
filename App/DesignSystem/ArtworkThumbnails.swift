import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Podcast art is often 3000×3000 px. Decoding that for a 60 pt row is slow on an A12, so this
/// downsamples to the size shown and keeps the result in memory and on disk.
final class ArtworkThumbnails: @unchecked Sendable {
    static let shared = ArtworkThumbnails()

    private let memory = NSCache<NSString, CGImage>()
    private let directory = URL.cachesDirectory.appending(path: "Artwork", directoryHint: .isDirectory)
    private let lock = NSLock()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    private init() {
        memory.countLimit = 300
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Sizes round up to steps of 64 px, so nearby sizes share a thumbnail.
    static func pixels(for points: CGFloat, scale: CGFloat) -> Int {
        max(64, Int((points * scale / 64).rounded(.up)) * 64)
    }

    private static func key(_ url: URL, _ pixels: Int) -> String { "\(url.absoluteString)@\(pixels)" }

    /// Synchronous, so a row scrolled back into view draws its art straight away.
    func cached(_ url: URL, pixels: Int) -> CGImage? { memory.object(forKey: Self.key(url, pixels) as NSString) }

    func image(_ url: URL, pixels: Int) async -> CGImage? {
        let key = Self.key(url, pixels)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let task: Task<CGImage?, Never> = lock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task.detached(priority: .utility) { [self] in await load(url, pixels: pixels, key: key) }
            inFlight[key] = task
            return task
        }
        let image = await task.value
        lock.withLock { inFlight[key] = nil }
        return image
    }

    private func load(_ url: URL, pixels: Int, key: String) async -> CGImage? {
        let file = directory.appending(path: Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png")
        if let image = Self.decode(file: file, pixels: pixels) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = Self.thumbnail(source, pixels: pixels) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        return image
    }

    private static func decode(file: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return thumbnail(source, pixels: pixels)
    }

    private static func thumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A downsampled, cached remote image over a placeholder, which is only drawn until the image is in.
struct RemoteArtwork<Placeholder: View>: View {
    var url: URL
    var size: CGFloat
    @ViewBuilder var placeholder: Placeholder
    @Environment(\.displayScale) private var scale
    @State private var loaded: (key: String, image: CGImage)?

    var body: some View {
        let pixels = ArtworkThumbnails.pixels(for: size, scale: scale)
        let key = "\(url.absoluteString)@\(pixels)"
        let image = loaded?.key == key ? loaded?.image : ArtworkThumbnails.shared.cached(url, pixels: pixels)
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: key) {
            guard image == nil, let fetched = await ArtworkThumbnails.shared.image(url, pixels: pixels) else { return }
            loaded = (key, fetched)
        }
    }
}
