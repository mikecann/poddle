import Foundation
import Synchronization

/// Time source for the engine's timers (sleep timer, auto-rewind, segments). Injectable for tests.
public protocol PlaybackClock: Sendable {
    /// Monotonic seconds.
    var now: Double { get }
    /// Milliseconds since the epoch.
    var wallNow: Double { get }
}

public struct SystemPlaybackClock: PlaybackClock {
    public init() {}
    public var now: Double { ProcessInfo.processInfo.systemUptime }
    public var wallNow: Double { Date().timeIntervalSince1970 * 1_000 }
}

/// A clock that only moves when told to.
public final class ManualPlaybackClock: PlaybackClock {
    private let state: Mutex<(now: Double, wall: Double)>

    public init(now: Double = 0, wallNow: Double = 1_760_000_000_000) {
        state = Mutex((now, wallNow))
    }

    public var now: Double { state.withLock { $0.now } }
    public var wallNow: Double { state.withLock { $0.wall } }

    public func advance(by seconds: Double) {
        state.withLock {
            $0.now += seconds
            $0.wall += seconds * 1_000
        }
    }
}
