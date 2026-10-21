import Foundation
import Observation
import UserNotifications
import PoddleKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Push: registers for remote notifications at launch and sends the token to the backend
/// (`devices:register`), asks for permission at a sensible moment (after the first subscribe, or
/// from Settings) rather than on first launch, and opens the episode when a new-episode alert is tapped.
@MainActor
@Observable
final class PushCoordinator {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    var notAskedYet: Bool { authorization == .notDetermined }
    var isDenied: Bool { authorization == .denied }

    @ObservationIgnored private let store: PoddleStore
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let delegate = NotificationDelegate()

    init(store: PoddleStore, app: AppModel) {
        self.store = store
        self.app = app
    }

    /// Called from the app delegate's did-finish-launching.
    func start() {
        UNUserNotificationCenter.current().delegate = delegate
        // A token arrives without asking permission; alerts only show once it's granted.
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows the system prompt the first time (after the first subscribe, or from Settings).
    func requestAuthorizationIfNeeded() {
        Task {
            await refreshAuthorization()
            guard authorization == .notDetermined else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let source = store.dataSource
        Task {
            do {
                try await source.registerDevice(apnsToken: hex, environment: .current)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func didFailToRegister(_ error: any Error) {
        lastError = error.localizedDescription
    }

    /// A tapped alert: `{ aps, episodeId, podcastId }` (docs/api.md).
    func open(userInfo: [AnyHashable: Any]) {
        guard let episodeId = userInfo["episodeId"] as? String else {
            if let podcastId = userInfo["podcastId"] as? String { app.goToShow(podcastId) }
            return
        }
        app.showNowPlaying = false
        app.sheet = .episode(episodeId)
    }
}

/// Shows alerts while the app is open and routes taps back to the coordinator.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let episodeId = info["episodeId"] as? String
        let podcastId = info["podcastId"] as? String
        await MainActor.run {
            var payload: [AnyHashable: Any] = [:]
            payload["episodeId"] = episodeId
            payload["podcastId"] = podcastId
            AppServices.current?.push.open(userInfo: payload)
        }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppServices.current?.push.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppServices.current?.push.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppServices.current?.push.didFailToRegister(error)
    }

    /// Downloads finished while the app was suspended or gone: the system relaunched it to hear about them.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier, let downloads = AppServices.current?.downloads else {
            return completionHandler()
        }
        downloads.backgroundCompletion = completionHandler
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.current?.push.start()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppServices.current?.push.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppServices.current?.push.didFailToRegister(error)
    }
}
#endif
