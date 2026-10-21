import Foundation

// Downloads over mobile data, as decisions.md says (Mike, 21 Oct):
// - "Download on: Wi-Fi only" (default) or "Wi-Fi and mobile data". Device-local, never synced.
// - In Wi-Fi-only mode, mobile can be allowed for 1 hour, 3 hours or until tomorrow. A chip shows
//   the time left with Stop. When it runs out, unfinished downloads pause until Wi-Fi.
// - Tapping download on one episode over mobile data in Wi-Fi-only mode asks first.
// - Streaming is always allowed; this only covers downloads.

/// What the device is on, from `NWPathMonitor`. Expensive (cellular, hotspot) or constrained
/// (Low Data Mode) paths count as mobile.
public enum NetworkPath: String, Sendable, Hashable, Codable {
    case offline, wifi, mobile
}

public enum DownloadNetworkMode: String, Sendable, Hashable, Codable, CaseIterable {
    case wifiOnly, wifiAndMobile

    public var label: String {
        switch self {
        case .wifiOnly: "Wi-Fi only"
        case .wifiAndMobile: "Wi-Fi and mobile data"
        }
    }
}

/// "Allow mobile downloads for 1 hour" (also 3 hours, or until tomorrow).
public enum MobileAllowance: String, Sendable, Hashable, Codable, CaseIterable {
    case oneHour, threeHours, untilTomorrow

    public var label: String {
        switch self {
        case .oneHour: "For 1 hour"
        case .threeHours: "For 3 hours"
        case .untilTomorrow: "Until tomorrow"
        }
    }

    /// When it runs out. "Until tomorrow" lasts until local midnight.
    public func expiry(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: now.addingTimeInterval(3_600)
        case .threeHours: now.addingTimeInterval(3 * 3_600)
        // Through the calendar rather than +24 h, so a daylight-saving change still ends at midnight.
        case .untilTomorrow:
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        }
    }
}

/// The three choices in the prompt you get tapping download on mobile data.
public enum MobilePromptChoice: String, Sendable, Hashable, CaseIterable {
    case downloadNowOnMobile, allowMobileForOneHour, waitForWifi

    public var label: String {
        switch self {
        case .downloadNowOnMobile: "Download now on mobile"
        case .allowMobileForOneHour: "Allow mobile for 1 hour"
        case .waitForWifi: "Wait for Wi-Fi"
        }
    }
}

/// Device-local download settings.
public struct DownloadSettings: Codable, Sendable, Hashable {
    public var mode: DownloadNetworkMode
    /// While set and in the future, Wi-Fi-only mode may use mobile data.
    public var mobileAllowedUntil: Date?

    public init(mode: DownloadNetworkMode = .wifiOnly, mobileAllowedUntil: Date? = nil) {
        self.mode = mode
        self.mobileAllowedUntil = mobileAllowedUntil
    }
}

/// The rules, as plain functions of the settings, the network and the time.
public struct DownloadPolicy: Sendable, Hashable {
    public var settings: DownloadSettings

    public init(settings: DownloadSettings) { self.settings = settings }

    public func isAllowanceActive(now: Date) -> Bool {
        settings.mode == .wifiOnly && (settings.mobileAllowedUntil.map { $0 > now } ?? false)
    }

    /// Seconds left on the temporary allowance, for the chip. Nil when there isn't one.
    public func allowanceRemaining(now: Date) -> TimeInterval? {
        guard isAllowanceActive(now: now), let until = settings.mobileAllowedUntil else { return nil }
        return until.timeIntervalSince(now)
    }

    /// Whether a download may use mobile data right now. `oneOff` is "Download now on mobile".
    public func mayUseMobile(now: Date, oneOff: Bool = false) -> Bool {
        oneOff || settings.mode == .wifiAndMobile || isAllowanceActive(now: now)
    }

    public enum TapDecision: Sendable, Hashable {
        /// Start it. `allowsMobile` goes on the request as `allowsExpensiveNetworkAccess`.
        case start(allowsMobile: Bool)
        /// Show the prompt.
        case ask
    }

    /// Tapping download on a single episode.
    public func decisionForTap(on network: NetworkPath, now: Date) -> TapDecision {
        if network == .mobile && !mayUseMobile(now: now) { return .ask }
        return .start(allowsMobile: mayUseMobile(now: now))
    }

    /// Auto-downloads never ask: they just wait for Wi-Fi.
    public func allowsMobileForAutoDownload(now: Date) -> Bool { mayUseMobile(now: now) }

    public struct PromptOutcome: Sendable, Hashable {
        public var settings: DownloadSettings
        public var allowsMobile: Bool
        /// Mobile data for this one download only, whatever the allowance does later.
        public var oneOff: Bool
    }

    /// What each prompt choice does.
    public func resolve(_ choice: MobilePromptChoice, now: Date, calendar: Calendar = .current) -> PromptOutcome {
        switch choice {
        case .downloadNowOnMobile:
            return PromptOutcome(settings: settings, allowsMobile: true, oneOff: true)
        case .allowMobileForOneHour:
            var s = settings
            s.mobileAllowedUntil = MobileAllowance.oneHour.expiry(from: now, calendar: calendar)
            return PromptOutcome(settings: s, allowsMobile: true, oneOff: false)
        case .waitForWifi:
            return PromptOutcome(settings: settings, allowsMobile: false, oneOff: false)
        }
    }

    /// What a running or waiting download should do now.
    public enum Adjustment: Sendable, Hashable {
        case none
        /// Mobile isn't allowed any more and it's on mobile: cancel with resume data and wait for Wi-Fi.
        case pauseUntilWifi
        /// It was made Wi-Fi-only but mobile is allowed now: restart it so it can use mobile.
        case restartAllowingMobile
        /// It may use mobile but mobile isn't allowed any more, and it isn't on mobile right now.
        /// Restart it Wi-Fi-only, or it could carry on over mobile while the app is suspended.
        case restartWifiOnly
        /// It's paused for Wi-Fi and Wi-Fi is back.
        case resume
    }

    public func adjustment(
        taskAllowsMobile: Bool, oneOff: Bool, isPausedForWifi: Bool, network: NetworkPath, now: Date
    ) -> Adjustment {
        let allowed = mayUseMobile(now: now, oneOff: oneOff)
        if isPausedForWifi {
            return network == .wifi || (network == .mobile && allowed) ? .resume : .none
        }
        if taskAllowsMobile && !allowed && network == .mobile { return .pauseUntilWifi }
        if !taskAllowsMobile && allowed && network == .mobile { return .restartAllowingMobile }
        if taskAllowsMobile && !allowed { return .restartWifiOnly }
        return .none
    }
}
