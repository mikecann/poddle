import Foundation
import ObjectiveC
import XCTest

/// One step file: `Steps/<feature>.steps.swift` holds a `StepModule` subclass that registers the
/// steps for `features/app/<feature>.feature` (scripts/verify-bdd-pairing.mjs checks the pairing).
/// Files starting with `_` hold shared steps. Every module is found at run time, so a new file only
/// needs the subclass.
class StepModule: NSObject {
    @MainActor class func register(_ steps: StepRegistry) {}
}

/// The arguments a step's expression captured, in order.
struct StepArgs {
    var values: [String]
    func string(_ i: Int) -> String { values[i] }
    func int(_ i: Int) -> Int { Int(values[i])! }
    func double(_ i: Int) -> Double { Double(values[i])! }
}

typealias StepBody = @MainActor (World, StepArgs) throws -> Void

/// Steps are written as Cucumber expressions, the same as the website's playwright-bdd steps:
/// `{string}` is a double-quoted string, `{int}` a whole number, `{float}` a number and `{word}`
/// one word. Everything else is literal.
struct StepDefinition {
    var expression: String
    var regex: NSRegularExpression
    var body: StepBody
    var source: String

    func match(_ text: String) -> StepArgs? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        let values = (1..<m.numberOfRanges).map { i -> String in
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
        return StepArgs(values: values)
    }

    static func regex(for expression: String) -> NSRegularExpression {
        var pattern = "^"
        var rest = Substring(expression)
        let parameters = ["{string}": "\"([^\"]*)\"", "{int}": "(-?\\d+)", "{float}": "(-?\\d+(?:\\.\\d+)?)", "{word}": "([^\\s]+)"]
        while !rest.isEmpty {
            if let (token, group) = parameters.first(where: { rest.hasPrefix($0.key) }) {
                pattern += group
                rest = rest.dropFirst(token.count)
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(rest.first!))
                rest = rest.dropFirst()
            }
        }
        return try! NSRegularExpression(pattern: pattern + "$")
    }
}

@MainActor
final class StepRegistry {
    private(set) var definitions: [StepDefinition] = []

    func given(_ expression: String, file: StaticString = #fileID, line: UInt = #line, _ body: @escaping StepBody) {
        add(expression, file, line, body)
    }
    func when(_ expression: String, file: StaticString = #fileID, line: UInt = #line, _ body: @escaping StepBody) {
        add(expression, file, line, body)
    }
    func then(_ expression: String, file: StaticString = #fileID, line: UInt = #line, _ body: @escaping StepBody) {
        add(expression, file, line, body)
    }

    private func add(_ expression: String, _ file: StaticString, _ line: UInt, _ body: @escaping StepBody) {
        precondition(!definitions.contains { $0.expression == expression }, "Step \"\(expression)\" is defined twice")
        definitions.append(StepDefinition(expression: expression, regex: StepDefinition.regex(for: expression), body: body, source: "\(file):\(line)"))
    }

    enum MatchError: Error, CustomStringConvertible {
        case undefined(String)
        case ambiguous(String, [String])
        var description: String {
            switch self {
            case let .undefined(text): "No step matches \"\(text)\". Add it to the feature's Steps/<feature>.steps.swift."
            case let .ambiguous(text, sources): "\"\(text)\" matches more than one step: \(sources.joined(separator: ", "))"
            }
        }
    }

    func find(_ text: String) throws -> (StepDefinition, StepArgs) {
        let matches = definitions.compactMap { d in d.match(text).map { (d, $0) } }
        guard let first = matches.first else { throw MatchError.undefined(text) }
        guard matches.count == 1 else { throw MatchError.ambiguous(text, matches.map(\.0.source)) }
        return first
    }

    /// Every `StepModule` subclass in the test bundle, registered once.
    static let shared: StepRegistry = {
        let registry = StepRegistry()
        for module in allModules() { module.register(registry) }
        return registry
    }()

    /// Classes from this test bundle's own binary only: touching some of the system's private
    /// runtime classes (even retaining one) crashes the process.
    private static func allModules() -> [StepModule.Type] {
        guard let image = Bundle(for: StepModule.self).executablePath else { return [] }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        let base = ObjectIdentifier(StepModule.self)
        var found: [StepModule.Type] = []
        for i in 0..<Int(count) {
            guard let cls = objc_getClass(names[i]) as? AnyClass else { continue }
            var superclass: AnyClass? = class_getSuperclass(cls)
            while let s = superclass, ObjectIdentifier(s) != base { superclass = class_getSuperclass(s) }
            if superclass != nil { found.append(unsafeBitCast(cls, to: StepModule.Type.self)) }
        }
        return found.sorted { NSStringFromClass($0) < NSStringFromClass($1) }
    }
}
