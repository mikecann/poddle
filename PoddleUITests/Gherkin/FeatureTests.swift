import Foundation
import ObjectiveC
import XCTest

/// Turns every scenario in features/app/*.feature into its own XCTest case, named
/// `test_<feature>__<scenario>`, so failures are reported per scenario. Each one resets the
/// e2e world, runs the Background and its steps through `StepRegistry`, and on failure attaches
/// a screenshot and the accessibility tree (also written to e2e/.runtime/ios-failures/).
///
/// Narrow a run with the runner's flags (scripts/run-e2e-ios.mjs), which arrive here as
/// `PODDLE_E2E_FEATURE` (a feature file name) and `PODDLE_E2E_SCENARIO` (part of a scenario name).
final class FeatureTests: XCTestCase {
    private struct Entry {
        var feature: Gherkin.Feature
        var scenario: Gherkin.Scenario
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    nonisolated(unsafe) private static var loadError: String?

    override class var defaultTestSuite: XCTestSuite {
        let suite = XCTestSuite(name: "Poddle features")
        let env = ProcessInfo.processInfo.environment
        let onlyFeature = env["PODDLE_E2E_FEATURE"].flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: ".feature", with: "") }
        let onlyScenario = env["PODDLE_E2E_SCENARIO"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        do {
            for feature in try FeatureFiles.load() where onlyFeature == nil || feature.file == onlyFeature {
                for scenario in feature.scenarios where onlyScenario.map({ scenario.name.lowercased().contains($0) }) ?? true {
                    suite.addTest(addCase(named: selectorName(feature, scenario), Entry(feature: feature, scenario: scenario)))
                }
            }
        } catch {
            loadError = String(describing: error)
            suite.addTest(addCase(named: "test_features_load", nil))
        }
        if suite.tests.isEmpty {
            loadError = "No scenarios matched feature \(onlyFeature ?? "(any)") and scenario \(onlyScenario ?? "(any)")"
            suite.addTest(addCase(named: "test_nothing_matched", nil))
        }
        return suite
    }

    private static func addCase(named name: String, _ entry: Entry?) -> FeatureTests {
        entries[name] = entry
        let selector = NSSelectorFromString(name)
        let body: @convention(block) (FeatureTests) -> Void = { test in
            // XCTest calls test methods on the main thread.
            nonisolated(unsafe) let test = test
            MainActor.assumeIsolated { test.run(name) }
        }
        class_addMethod(FeatureTests.self, selector, imp_implementationWithBlock(body), "v@:")
        return FeatureTests(selector: selector)
    }

    private static func selectorName(_ feature: Gherkin.Feature, _ scenario: Gherkin.Scenario) -> String {
        func clean(_ s: String) -> String {
            s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
                .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return "test_\(clean(feature.file))__\(clean(scenario.name))"
    }

    @MainActor private func run(_ name: String) {
        guard let entry = Self.entries[name] else {
            XCTFail(Self.loadError ?? "Unknown scenario \(name)")
            return
        }
        continueAfterFailure = false
        let world: World
        do {
            world = try World(test: self, scenario: "\(entry.feature.file): \(entry.scenario.name)")
        } catch {
            XCTFail("Couldn't set up the e2e world: \(error)")
            return
        }
        defer { world.finish() }
        let steps = entry.feature.background + entry.scenario.steps
        for step in steps {
            let label = "\(step.keyword) \(step.text)"
            var failure: String?
            XCTContext.runActivity(named: label) { _ in
                do {
                    let (definition, args) = try StepRegistry.shared.find(step.text)
                    try definition.body(world, args)
                } catch {
                    failure = String(describing: error)
                }
            }
            if let failure {
                world.recordFailure(step: label, message: failure)
                XCTFail("\(entry.feature.file).feature:\(step.line): \(label)\n\(failure)")
                return
            }
        }
    }
}

/// Finds and parses the app's feature files, in the checkout this test bundle was built from
/// (the simulator can read the Mac's disk, as snapshot tests do).
enum FeatureFiles {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = repo.appending(path: "features/app")

    static func load() throws -> [Gherkin.Feature] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "feature" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { url in
            try Gherkin.parse(String(contentsOf: url, encoding: .utf8), file: url.deletingPathExtension().lastPathComponent)
        }
    }
}
