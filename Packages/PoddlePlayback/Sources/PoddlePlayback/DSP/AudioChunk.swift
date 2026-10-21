import Foundation

/// Where an output frame came from. `content` is the frame index in the original file.
/// `edited` counts frames after Smart Speed, so `Δcontent − Δedited` is what Smart Speed removed.
struct FrameTag: Sendable, Equatable {
    var content: Int64
    var edited: Int64
}

/// Deinterleaved float PCM plus one tag per frame. Every DSP stage moves tags along with the
/// samples, which keeps the content↔output time map exact however the stages cut or stretch audio.
struct AudioChunk {
    var channels: [[Float]]
    var tags: [FrameTag]

    init(channelCount: Int, capacity: Int = 0) {
        channels = Array(repeating: [], count: channelCount)
        tags = []
        if capacity > 0 {
            for c in channels.indices { channels[c].reserveCapacity(capacity) }
            tags.reserveCapacity(capacity)
        }
    }

    var channelCount: Int { channels.count }
    var frameCount: Int { tags.count }
    var isEmpty: Bool { tags.isEmpty }

    mutating func append(_ other: AudioChunk) {
        append(other, range: 0..<other.frameCount)
    }

    mutating func append(_ other: AudioChunk, range: Range<Int>) {
        guard !range.isEmpty else { return }
        for c in channels.indices { channels[c].append(contentsOf: other.channels[c][range]) }
        tags.append(contentsOf: other.tags[range])
    }

    mutating func removeFirst(_ n: Int) {
        guard n > 0 else { return }
        if n >= frameCount { removeAll(); return }
        for c in channels.indices { channels[c].removeFirst(n) }
        tags.removeFirst(n)
    }

    mutating func removeAll() {
        for c in channels.indices { channels[c].removeAll(keepingCapacity: true) }
        tags.removeAll(keepingCapacity: true)
    }
}
