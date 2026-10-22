import Foundation

/// A small Gherkin reader for the app's feature files (features/app/*.feature). It covers what
/// those files use: `Feature`, free-text descriptions, `Background`, `Scenario` (or `Example`),
/// `Scenario Outline` with `Examples` tables, `Given`/`When`/`Then`/`And`/`But`/`*` steps, `@tags`
/// and `#` comments. Anything else (data tables under steps, doc strings, `Rule`) is an error, so
/// a feature never silently loses a step. scripts/bdd-drift.mjs reads the same subset.
enum Gherkin {
    struct Feature {
        var name: String
        /// The file's name without `.feature`, e.g. "sign-in". Its steps live in `Steps/<name>.steps.swift`.
        var file: String
        var background: [Step]
        var scenarios: [Scenario]
    }

    struct Scenario {
        var name: String
        var tags: [String]
        var line: Int
        var steps: [Step]
    }

    struct Step {
        /// "Given", "When", "Then", "And", "But" or "*", as written.
        var keyword: String
        var text: String
        var line: Int
    }

    struct ParseError: Error, CustomStringConvertible {
        var file: String
        var line: Int
        var message: String
        var description: String { "\(file):\(line): \(message)" }
    }

    static func parse(_ source: String, file: String) throws -> Feature {
        var feature: Feature?
        var background: [Step]?
        var scenarios: [Scenario] = []
        var pendingTags: [String] = []
        /// What steps are being added to.
        enum Section { case none, background, scenario, outline, examples }
        var section = Section.none
        var outline: (name: String, tags: [String], line: Int, steps: [Step])?
        var exampleHeader: [String]?

        func fail(_ line: Int, _ message: String) -> ParseError { ParseError(file: file, line: line, message: message) }

        func finishOutline() {
            outline = nil
            exampleHeader = nil
        }

        let lines = source.components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("@") {
                pendingTags += line.split(whereSeparator: \.isWhitespace).map(String.init)
                continue
            }
            if let name = line.dropPrefix("Feature:") {
                guard feature == nil else { throw fail(number, "A file has one Feature") }
                feature = Feature(name: name, file: file, background: [], scenarios: [])
                pendingTags = []
                continue
            }
            guard feature != nil else { throw fail(number, "Expected `Feature:` first") }

            if line.dropPrefix("Background:") != nil {
                guard background == nil, scenarios.isEmpty, outline == nil else { throw fail(number, "Background goes once, before the scenarios") }
                background = []
                section = .background
                continue
            }
            if let name = line.dropPrefix("Scenario Outline:") ?? line.dropPrefix("Scenario Template:") {
                finishOutline()
                outline = (name, pendingTags, number, [])
                pendingTags = []
                section = .outline
                continue
            }
            if let name = line.dropPrefix("Scenario:") ?? line.dropPrefix("Example:") {
                finishOutline()
                scenarios.append(Scenario(name: name, tags: pendingTags, line: number, steps: []))
                pendingTags = []
                section = .scenario
                continue
            }
            if line.dropPrefix("Examples:") != nil || line.dropPrefix("Scenarios:") != nil {
                guard outline != nil else { throw fail(number, "Examples without a Scenario Outline") }
                exampleHeader = nil
                section = .examples
                continue
            }
            if line.dropPrefix("Rule:") != nil { throw fail(number, "`Rule` isn't supported here") }

            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard section == .examples, let o = outline else { throw fail(number, "Data tables under steps aren't supported; use a Scenario Outline") }
                guard let header = exampleHeader else { exampleHeader = cells; continue }
                guard cells.count == header.count else { throw fail(number, "This row has \(cells.count) cells, the header has \(header.count)") }
                let values = Dictionary(uniqueKeysWithValues: zip(header, cells))
                func fill(_ s: String) -> String {
                    values.reduce(s) { $0.replacingOccurrences(of: "<\($1.key)>", with: $1.value) }
                }
                let label = header.map { "\($0)=\(values[$0]!)" }.joined(separator: ", ")
                scenarios.append(Scenario(
                    name: "\(fill(o.name)) (\(label))", tags: o.tags, line: number,
                    steps: o.steps.map { Step(keyword: $0.keyword, text: fill($0.text), line: $0.line) }))
                continue
            }
            if line.hasPrefix("\"\"\"") || line.hasPrefix("```") { throw fail(number, "Doc strings aren't supported") }

            if let (keyword, text) = stepParts(line) {
                let step = Step(keyword: keyword, text: text, line: number)
                switch section {
                case .background: background!.append(step)
                case .scenario: scenarios[scenarios.count - 1].steps.append(step)
                case .outline: outline!.steps.append(step)
                case .none, .examples: throw fail(number, "A step outside a scenario")
                }
                continue
            }
            // Free text: the feature's or a scenario's description.
            if section == .none || (section == .scenario && scenarios.last?.steps.isEmpty == true) { continue }
            throw fail(number, "Not a step: \(line)")
        }
        guard var result = feature else { throw ParseError(file: file, line: 1, message: "No Feature") }
        result.background = background ?? []
        result.scenarios = scenarios
        if let empty = scenarios.first(where: { $0.steps.isEmpty }) { throw fail(empty.line, "Scenario \"\(empty.name)\" has no steps") }
        return result
    }

    private static let keywords = ["Given ", "When ", "Then ", "And ", "But ", "* "]

    private static func stepParts(_ line: String) -> (String, String)? {
        for k in keywords where line.hasPrefix(k) {
            return (k.trimmingCharacters(in: .whitespaces), String(line.dropFirst(k.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }
}
