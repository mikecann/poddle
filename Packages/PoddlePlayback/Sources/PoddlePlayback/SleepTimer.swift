import Foundation

public enum SleepTimerMode: Sendable, Equatable {
    case minutes(Double)
    case endOfEpisode
    case endOfChapter
}

public struct SleepTimerState: Sendable, Equatable {
    public var mode: SleepTimerMode
    /// Wall-clock seconds until playback stops.
    public var remaining: Double
}

/// Sleep timer logic, separate from the engine so it can be tested with a manual clock.
/// Minute timers only count down while playing. All modes fade out over the last 10 s.
public struct SleepTimer: Sendable {
    public static let fadeDuration = 10.0
    /// Shaking within this long after the timer stopped playback restarts the same timer.
    public static let restartWindow = 30.0

    public struct Context: Sendable {
        public var position: Double
        public var duration: Double
        public var rate: Double
        public var chapterEnd: Double?
        public var isPlaying: Bool

        public init(position: Double, duration: Double, rate: Double, chapterEnd: Double? = nil, isPlaying: Bool) {
            self.position = position
            self.duration = duration
            self.rate = rate
            self.chapterEnd = chapterEnd
            self.isPlaying = isPlaying
        }
    }

    public enum Decision: Sendable, Equatable {
        case inactive
        case running(remaining: Double, volume: Float)
        /// Stop playback now (and restore full volume).
        case fire
    }

    public private(set) var mode: SleepTimerMode?
    private var minutesRemaining = 0.0
    private var lastTick: Double?
    private var lastFired: (mode: SleepTimerMode, at: Double)?

    public init() {}

    public mutating func set(_ mode: SleepTimerMode?, now: Double) {
        self.mode = mode
        lastTick = now
        lastFired = nil
        if case .minutes(let m) = mode { minutesRemaining = m * 60 }
    }

    /// Shake to extend. A running minute timer goes back to its full length; a timer that stopped
    /// playback in the last 30 s starts again. Returns true if playback should resume.
    @discardableResult
    public mutating func extend(now: Double) -> Bool {
        if let mode {
            if case .minutes(let m) = mode { minutesRemaining = m * 60 }
            lastTick = now
            return false
        }
        if let lastFired, now - lastFired.at <= Self.restartWindow {
            set(lastFired.mode, now: now)
            return true
        }
        return false
    }

    public mutating func evaluate(now: Double, context: Context) -> Decision {
        guard let mode else { return .inactive }
        defer { lastTick = now }
        let remaining: Double
        switch mode {
        case .minutes:
            if context.isPlaying, let lastTick { minutesRemaining -= max(0, now - lastTick) }
            remaining = minutesRemaining
        case .endOfEpisode:
            remaining = (context.duration - context.position) / max(context.rate, 0.1)
        case .endOfChapter:
            remaining = ((context.chapterEnd ?? context.duration) - context.position) / max(context.rate, 0.1)
        }
        if remaining <= 0 {
            lastFired = (mode, now)
            self.mode = nil
            return .fire
        }
        let t = min(1, remaining / Self.fadeDuration)
        return .running(remaining: remaining, volume: Float(t * t))
    }

    public func state(now: Double, context: Context) -> SleepTimerState? {
        var copy = self
        guard let mode, case .running(let remaining, _) = copy.evaluate(now: now, context: context) else { return nil }
        return SleepTimerState(mode: mode, remaining: remaining)
    }
}
