import Foundation
import MediaPlayer

/// Lock screen, Control Centre, headphone and AirPods commands.
@MainActor
final class RemoteCommandController {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
        var setRate: (Double) -> Void
        var nextChapter: () -> Void
        var previousChapter: () -> Void
    }

    private var configuration = RemoteCommandConfiguration()
    private var handlers: Handlers?
    private var registered = false

    func install(_ handlers: Handlers, configuration: RemoteCommandConfiguration) {
        self.handlers = handlers
        self.configuration = configuration
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: configuration.skipBackwardInterval)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: configuration.skipForwardInterval)]
        center.changePlaybackRateCommand.supportedPlaybackRates = stride(from: 0.5, through: 3.0, by: 0.25).map { NSNumber(value: $0) }
        guard !registered else { return }
        registered = true

        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
            }
        }
        on(center.playCommand) { [weak self] _ in self?.handlers?.play(); return .success }
        on(center.pauseCommand) { [weak self] _ in self?.handlers?.pause(); return .success }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.handlers?.toggle(); return .success }
        on(center.skipBackwardCommand) { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? self.configuration.skipBackwardInterval
            self.handlers?.skip(-interval)
            return .success
        }
        on(center.skipForwardCommand) { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? self.configuration.skipForwardInterval
            self.handlers?.skip(interval)
            return .success
        }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.handlers?.seek(event.positionTime)
            return .success
        }
        on(center.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.handlers?.setRate(Double(event.playbackRate))
            return .success
        }
        // AirPods double/triple tap and headphone buttons send next/previous track.
        on(center.nextTrackCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.configuration.nextPrevious == .chapter { self.handlers?.nextChapter() } else { self.handlers?.skip(self.configuration.skipForwardInterval) }
            return .success
        }
        on(center.previousTrackCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.configuration.nextPrevious == .chapter { self.handlers?.previousChapter() } else { self.handlers?.skip(-self.configuration.skipBackwardInterval) }
            return .success
        }
    }
}
