import Foundation
import Synchronization

/// Display formatting shared by every screen.
public enum Format {
    /// "1h 4m", "52m", "9m", "2h". Rounds to the nearest minute, with "<1m" for tiny amounts.
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes == 0 { return seconds > 0 ? "<1m" : "0m" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "1.8×", "1.25×", "2.0×".
    public static func speed(_ rate: Double) -> String { speedNumber(rate) + "×" }

    /// "1.8", "1.25", "2.0" (no sign), for presets and scales.
    public static func speedNumber(_ rate: Double) -> String {
        let hundredths = Int((rate * 100).rounded())
        if hundredths % 10 == 0 { return String(format: "%d.%d", hundredths / 100, (hundredths % 100) / 10) }
        return String(format: "%d.%02d", hundredths / 100, hundredths % 100)
    }

    /// "1.40" for the speed sheet's big readout.
    public static func speedPrecise(_ rate: Double) -> String {
        String(format: "%.2f", (rate * 100).rounded() / 100)
    }

    /// "38m left at 1.8×": wall-clock time left for `remaining` content seconds at `rate`.
    public static func timeLeft(_ remaining: Double, rate: Double) -> String {
        "\(duration(remaining / rate)) left at \(speed(rate))"
    }

    /// "41m at 1.8×" for something not started yet.
    public static func atSpeed(_ content: Double, rate: Double) -> String {
        "\(duration(content / rate)) at \(speed(rate))"
    }

    /// "41:08", "1:12:40".
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "−1:12:40" with a real minus sign.
    public static func remainingClock(_ seconds: Double) -> String { "\u{2212}" + clock(seconds) }

    /// "4m 12s", "27h", "1h 3m" for time saved.
    public static func saved(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        if s < 36_000 { return duration(Double(s)) }
        return "\(s / 3600)h"
    }

    /// "612h".
    public static func hours(_ seconds: Double) -> String { "\(Int((seconds / 3600).rounded()))h" }

    /// "3,412".
    public static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_AU")))
    }

    /// "6 episodes · 4h 42m at your speeds".
    public static func queueSummary(count: Int, wallSeconds: Double) -> String {
        let eps = count == 1 ? "1 episode" : "\(count) episodes"
        return count == 0 ? "Nothing queued" : "\(eps) · \(duration(wallSeconds)) at your speeds"
    }

    /// "Today", "Yesterday", "Mon 19 Oct", or "14 Oct 2025" for another year.
    public static func relativeDate(
        _ millis: Millis, now: Date = Date(), calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_AU")
    ) -> String {
        let date = Date(timeIntervalSince1970: millis / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let f = formatter(sameYear ? "EEE d MMM" : "d MMM yyyy", locale: locale, calendar: calendar)
        return f.string(from: date)
    }

    /// "21 OCT 2026" for receipts.
    public static func receiptDate(_ millis: Millis, calendar: Calendar = .current) -> String {
        formatter("d MMM yyyy", locale: Locale(identifier: "en_AU"), calendar: calendar)
            .string(from: Date(timeIntervalSince1970: millis / 1000)).uppercased()
    }

    /// "March 2014".
    public static func monthYear(_ millis: Millis, calendar: Calendar = .current) -> String {
        formatter("MMMM yyyy", locale: Locale(identifier: "en_AU"), calendar: calendar)
            .string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    /// Date formatters are slow to make, and rows ask for dates while scrolling, so each one is
    /// made once. (`DateFormatter` is thread-safe for formatting.)
    private static func formatter(_ format: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let key = "\(format)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        return formatters.withLock { cache in
            if let f = cache[key] { return f }
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            cache[key] = f
            return f
        }
    }

    private static let formatters = Mutex<[String: DateFormatter]>([:])

    /// "12:00", "4:30" countdown for the sleep timer.
    public static func countdown(_ seconds: Double) -> String { clock(seconds) }
}
