#if os(iOS)
import BackgroundTasks
import Foundation

/// Background app refresh (spec §2.8): best effort, whenever iOS decides to run it. Each run asks
/// Convex to re-check feeds, syncs, starts downloads and books the next run. The sync push
/// (`apns:sendSyncWake`) is the timely part; this catches what it misses, like a push iOS
/// throttled or a phone that was off when it went out.
enum BackgroundRefresh {
    /// Also in Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
    static let identifier = "com.mikecann.poddle.refresh"
    /// The earliest the next run can be. iOS usually leaves it longer.
    static let interval: TimeInterval = 30 * 60

    /// On going to the background, and at the start of every run. Fails quietly in the
    /// simulator, which has no background app refresh.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        _ = await AppServices.current?.syncInBackground(recheckFeeds: true)
    }
}
#endif
