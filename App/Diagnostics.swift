import Foundation
import Sentry

/// Crash and error reporting (Sentry project `poddle`), for App Store and TestFlight installs only.
///
/// Mike's agents build, test and screenshot Poddle all day, and an agent watches Sentry and opens a
/// thread for anything serious, so only real people's crashes may get there. It's compiled out of
/// Debug and the simulator, and a Release build on a device starts it only when it was installed
/// from the App Store (Apple strips the provisioning profile). Release builds that
/// `scripts/install-phone.sh` puts on Mike's phone stay quiet.
///
/// Crashes, watchdog terminations and app hangs only: no tracing, sessions or network capture. A
/// podcast host timing out or a 5xx on a download isn't a bug in Poddle, so failed HTTP requests
/// aren't reported, and network breadcrumbs (which would list the episodes someone streamed) are off.
enum Diagnostics {
    static func start() {
        #if !DEBUG && !targetEnvironment(simulator)
        guard installedFromStore else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        SentrySDK.start { options in
            options.dsn = "https://325474d642eb61456018e347930e882c@o4508736647266304.ingest.us.sentry.io/4512336956817408"
            options.environment = "production"
            options.releaseName = "poddle@\(version)+\(build)"
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableAutoSessionTracking = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            #if os(macOS)
            options.enableAppHangTracking = false
            #endif
            options.initialScope = { scope in
                #if os(iOS)
                scope.setTag(value: "ios", key: "component")
                #else
                scope.setTag(value: "mac", key: "component")
                #endif
                return scope
            }
        }
        #endif
    }

    /// App Store and TestFlight builds: an iPhone build without an embedded provisioning profile, or
    /// a Mac build with a Mac App Store receipt. Xcode and `install-phone.sh` builds have the profile.
    private static var installedFromStore: Bool {
        #if os(iOS)
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil
        #else
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/_MASReceipt/receipt").path)
        #endif
    }
}
