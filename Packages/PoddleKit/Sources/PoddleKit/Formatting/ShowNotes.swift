import Foundation

/// Turns feed show notes (HTML, or sometimes plain text) into paragraphs and bullets of
/// `AttributedString`, with bold and italics kept, links tappable, bare URLs linked, and timestamps
/// like "12:34" or "1:02:03" linked to `poddle-seek://<seconds>` so tapping one seeks.
/// Pure and `nonisolated`, so it's safe to run off the main thread.
public enum ShowNotes {
    public enum Block: Hashable, Sendable {
        case paragraph(AttributedString)
        case bullet(AttributedString)
        case heading(AttributedString)
    }

    public static let seekScheme = "poddle-seek"

    /// The position a timestamp link points at.
    public static func seekSeconds(_ url: URL) -> Double? {
        guard url.scheme == seekScheme, let host = url.host() else { return nil }
        return Double(host)
    }

    /// "1:02:03" → 3723, "12:34" → 754. Nil for anything that isn't a clock time.
    public static func seconds(fromTimestamp text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.map { $0! }
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return Double(values.reduce(0) { $0 * 60 + $1 })
    }

    public static func blocks(html: String) -> [Block] {
        var parser = Parser()
        if html.range(of: #"<[a-zA-Z/][^>]*>"#, options: .regularExpression) == nil {
            // Plain text: blank lines split paragraphs, single newlines stay as line breaks.
            for para in html.components(separatedBy: "\n\n") {
                for (i, line) in para.components(separatedBy: "\n").enumerated() {
                    if i > 0 { parser.lineBreak() }
                    parser.text(line)
                }
                parser.endBlock()
            }
            return parser.blocks
        }
        let tag = /<(\/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>/
        var rest = html[...]
        while let match = rest.firstMatch(of: tag) {
            parser.text(String(rest[..<match.range.lowerBound]))
            parser.tag(name: match.2.lowercased(), closing: !match.1.isEmpty, attributes: String(match.3))
            rest = rest[match.range.upperBound...]
        }
        parser.text(String(rest))
        parser.endBlock()
        return parser.blocks
    }

    private struct Parser {
        var blocks: [Block] = []
        var current = AttributedString()
        var kind: Kind = .paragraph
        var bold = 0
        var italic = 0
        var links: [URL?] = []
        /// Inside <script>, <style> and the like: drop the text.
        var hidden = 0
        /// The last character written was whitespace (or the block is empty), so collapse more.
        var atSpace = true

        enum Kind { case paragraph, bullet, heading }

        mutating func text(_ raw: String) {
            guard hidden == 0 else { return }
            let decoded = ShowNotes.decodeEntities(raw)
            var collapsed = ""
            for ch in decoded {
                if ch.isWhitespace {
                    if !atSpace { collapsed.append(" "); atSpace = true }
                } else {
                    collapsed.append(ch)
                    atSpace = false
                }
            }
            guard !collapsed.isEmpty else { return }
            var intent: InlinePresentationIntent = []
            if bold > 0 || kind == .heading { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if let link = links.last ?? nil {
                var piece = AttributedString(collapsed)
                piece.link = link
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                current.append(piece)
            } else {
                current.append(ShowNotes.linkified(collapsed, intent: intent))
            }
        }

        mutating func lineBreak() {
            guard !current.characters.isEmpty else { return }
            trimTrailingSpace()
            current.append(AttributedString("\n"))
            atSpace = true
        }

        mutating func tag(name: String, closing: Bool, attributes: String) {
            switch name {
            case "script", "style", "head", "title": hidden += closing ? -1 : 1; hidden = max(0, hidden)
            case "br": lineBreak()
            case "p", "div", "section", "article", "blockquote", "ul", "ol", "table", "tr", "pre", "hr":
                endBlock()
            case "li":
                endBlock()
                if !closing { kind = .bullet }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                endBlock()
                if !closing { kind = .heading }
            case "b", "strong": bold = max(0, bold + (closing ? -1 : 1))
            case "i", "em": italic = max(0, italic + (closing ? -1 : 1))
            case "a":
                if closing { _ = links.popLast() } else { links.append(ShowNotes.href(attributes)) }
            default: break
            }
        }

        mutating func endBlock() {
            trimTrailingSpace()
            while let first = current.characters.first, first.isWhitespace {
                current.removeSubrange(current.startIndex..<current.index(afterCharacter: current.startIndex))
            }
            if !current.characters.isEmpty {
                switch kind {
                case .paragraph: blocks.append(.paragraph(current))
                case .bullet: blocks.append(.bullet(current))
                case .heading: blocks.append(.heading(current))
                }
            }
            current = AttributedString()
            kind = .paragraph
            atSpace = true
        }

        private mutating func trimTrailingSpace() {
            while let last = current.characters.last, last == " " {
                current.removeSubrange(current.index(beforeCharacter: current.endIndex)..<current.endIndex)
            }
        }
    }

    static func href(_ attributes: String) -> URL? {
        guard let m = attributes.firstMatch(of: /href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/.ignoresCase()) else { return nil }
        let raw = String(m.1 ?? m.2 ?? m.3 ?? "")
        let value = decodeEntities(raw).trimmingCharacters(in: .whitespaces)
        if let t = seconds(fromTimestamp: value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) { return seekURL(t) }
        guard let url = URL(string: value), url.scheme != nil else { return nil }
        return url
    }

    static func seekURL(_ seconds: Double) -> URL? { URL(string: "\(seekScheme)://\(Int(seconds))") }

    /// Links bare URLs and timestamps in plain text.
    static func linkified(_ text: String, intent: InlinePresentationIntent) -> AttributedString {
        let regex = try! NSRegularExpression(pattern: #"(https?://[^\s<>"]+)|((?<![\d:])(?:\d{1,2}:)?\d{1,2}:\d{2}(?![\d:]))"#)
        let ns = text as NSString
        var out = AttributedString()
        func append(_ s: String, link: URL? = nil) {
            guard !s.isEmpty else { return }
            var a = AttributedString(s)
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if let link { a.link = link }
            out.append(a)
        }
        var cursor = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            var matched = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound {
                var trailing = ""
                while let last = matched.last, ".,;:!?)]'\"".contains(last) {
                    trailing.insert(matched.removeLast(), at: trailing.startIndex)
                }
                append(matched, link: URL(string: matched))
                append(trailing)
            } else {
                append(matched, link: seconds(fromTimestamp: matched).flatMap(seekURL))
            }
            cursor = m.range.location + m.range.length
        }
        append(ns.substring(from: cursor))
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "rsquo": "\u{2019}",
            "lsquo": "\u{2018}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "mdash": "\u{2014}", "ndash": "\u{2013}",
            "hellip": "\u{2026}", "copy": "\u{00A9}", "trade": "\u{2122}", "reg": "\u{00AE}",
        ]
        var out = ""
        var rest = s[...]
        while let m = rest.firstMatch(of: /&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/) {
            out += rest[..<m.range.lowerBound]
            let body = String(m.1)
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body.lowercased()]
            }
            out += replacement ?? String(rest[m.range])
            rest = rest[m.range.upperBound...]
        }
        out += rest
        return out
    }
}
