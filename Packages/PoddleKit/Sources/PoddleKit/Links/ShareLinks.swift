import Foundation

/// Links to the website's public pages (`/e/<id>`, `/s/<id>`), which open in Poddle as universal
/// links when it's installed, and reading them (and the `poddle://e/…` form the website's
/// "Open in Poddle" button uses) back into somewhere to go.
///
/// Private shows have no public page (the server answers "not found"), so don't hand out links
/// for them: check `canShare(podcast)` first.
public struct ShareLinks: Sendable, Hashable {
    /// The site, e.g. `https://poddle.mikecann.app`.
    public var base: URL

    public init(base: URL) { self.base = base }

    /// Prod's site, used when the build doesn't say (Info.plist `PoddleSiteURL`).
    public static let production = ShareLinks(base: URL(string: "https://poddle.mikecann.app")!)

    /// This build's site: `PoddleSiteURL` from Config/Debug.xcconfig or Release.xcconfig.
    public static func bundled(_ bundle: Bundle = .main) -> ShareLinks {
        guard let raw = bundle.object(forInfoDictionaryKey: "PoddleSiteURL") as? String else { return .production }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("$("), let url = URL(string: t), url.host() != nil else { return .production }
        return ShareLinks(base: url)
    }

    /// The build's links. Use this from views.
    public static let current = bundled()

    public static func episode(_ id: String, at seconds: Double? = nil) -> URL { current.episode(id, at: seconds) }
    public static func show(_ id: String) -> URL { current.show(id) }

    /// `/e/<id>`, with `?t=<whole seconds>` when given a start time past zero.
    public func episode(_ id: String, at seconds: Double? = nil) -> URL {
        var url = base.appending(path: "e").appending(path: id)
        if let seconds, seconds.isFinite, seconds >= 1 {
            url.append(queryItems: [URLQueryItem(name: "t", value: String(Int(seconds)))])
        }
        return url
    }

    /// `/s/<id>`.
    public func show(_ id: String) -> URL { base.appending(path: "s").appending(path: id) }

    /// Whether a show gets share links: not if it's private (yours, or by default for feeds with tokens).
    public static func canShare(_ podcast: Podcast) -> Bool { !podcast.isPrivate }

    /// Where a link goes.
    public enum Target: Sendable, Hashable {
        case episode(id: String, startAt: Double?)
        case show(id: String)
    }

    /// Reads `https://<any host>/e/<id>?t=…`, `/s/<id>` and `poddle://e/<id>?t=…`, `poddle://s/<id>`.
    /// The host isn't checked: iOS only hands the app universal links for its associated domains.
    public static func parse(_ url: URL) -> Target? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = parts.path.split(separator: "/").map(String.init)
        switch parts.scheme?.lowercased() {
        case "poddle":
            // poddle://e/<id>: the host is the kind.
            if let host = parts.host, !host.isEmpty { path.insert(host, at: 0) }
        case "http", "https": break
        default: return nil
        }
        guard path.count == 2, let id = path.last, !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        switch path[0] {
        case "e":
            let t = parts.queryItems?.first(where: { $0.name == "t" })?.value.flatMap(parseStart)
            return .episode(id: id, startAt: t)
        case "s": return .show(id: id)
        default: return nil
        }
    }

    /// `?t=` as seconds ("754"), a clock ("12:34", "1:02:03") or "1h2m3s". Nil if none of those.
    static func parseStart(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let s = Double(t), s.isFinite, s >= 0 { return s }
        let clock = t.split(separator: ":", omittingEmptySubsequences: false)
        if (2...3).contains(clock.count), clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return clock.reduce(0) { $0 * 60 + Double($1)! }
        }
        var total = 0.0, number = "", sawUnit = false
        for c in t {
            if c.isNumber { number.append(c); continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""; sawUnit = true
        }
        return sawUnit && number.isEmpty ? total : nil
    }
}
