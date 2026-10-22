import AVFoundation
import Foundation

/// The audio session (iOS): long-form spoken audio, interruptions and route changes.
/// On macOS there's no session; routes report `.unknown` and only the callbacks' shape is shared.
@MainActor
final class AudioSessionController {
    enum Event {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// The previous output went away (headphones unplugged, Bluetooth dropped): pause.
        case outputLost
        case routeChanged(AudioRoute)
    }

    var onEvent: ((Event) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    init() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27, *) {
            // iOS 27 splits interruptions into "the system deactivated us" and "you may resume".
            observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                guard context?.source == .system else { return }
                MainActor.assumeIsolated { self?.onEvent?(.interruptionBegan) }
            })
            observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let shouldResume = context?.recommendation == .shouldResume
                MainActor.assumeIsolated { self?.onEvent?(.interruptionEnded(shouldResume: shouldResume)) }
            })
        } else {
            // iOS 18: one notification with a began/ended type and a "should resume" option.
            observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                MainActor.assumeIsolated {
                    switch type {
                    case .began: self?.onEvent?(.interruptionBegan)
                    case .ended: self?.onEvent?(.interruptionEnded(shouldResume: shouldResume))
                    default: break
                    }
                }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable { self.onEvent?(.outputLost) }
                self.onEvent?(.routeChanged(self.currentRoute))
            }
        })
        #endif
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func configure() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        #endif
    }

    func activate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    var currentRoute: AudioRoute {
        #if os(iOS)
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .unknown }
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver: return .speaker
        case .headphones, .usbAudio: return .headphones
        case .carAudio: return .carPlay
        case .airPlay: return .airPlay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return output.portName.localizedCaseInsensitiveContains("airpods") ? .airPods : .bluetooth
        default: return .unknown
        }
        #else
        return .unknown
        #endif
    }
}
