import Foundation
import XCTest

/// One scenario's world: the app under test, the e2e world API (e2e/world/worldApi.mjs, over
/// HTTP to the fixture server) and whatever the steps want to remember between them.
/// docs/testing.md has the whole picture.
@MainActor
final class World {
    struct Config: Decodable {
        var convexUrl: String
        var siteUrl: String
        var fixtureUrl: String
        var users: [String: String]
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    let config: Config
    let app = XCUIApplication(bundleIdentifier: "com.mikecann.poddle")
    let test: XCTestCase
    let scenario: String
    /// Shared between a scenario's steps.
    var memo: [String: String] = [:]
    /// Who the scenario is about (the listener unless a step says otherwise).
    var email: String
    /// More launch arguments for when the scenario opens the app (e.g. `-PoddleImportFile`).
    var launchExtras: [String] = []
    /// Episode id → title, for reading Up Next off the screen (`knownEpisodeTitles`).
    var titleCache: [String: String]?

    init(test: XCTestCase, scenario: String) throws {
        let file = FeatureFiles.repo.appending(path: "e2e/.runtime/world.json")
        guard let data = try? Data(contentsOf: file) else {
            throw Failure("No e2e world at \(file.path). Run the suite with `npm run test:e2e:ios`, which starts one.")
        }
        config = try JSONDecoder().decode(Config.self, from: data)
        self.test = test
        self.scenario = scenario
        email = config.users["listener"]!
        // The notification prompt can turn up after a subscribe; it isn't what these scenarios are about.
        test.addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Don’t Allow", "Don't Allow", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        _ = try call("reset")
    }

    func finish() {
        if app.state != .notRunning { app.terminate() }
    }

    // MARK: The world API

    /// Calls `/_world/<op>` and returns its JSON object.
    @discardableResult
    func call(_ op: String, _ body: [String: Any] = [:]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(config.fixtureUrl)/_world/\(op)")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try Self.send(request)
        guard status == 200 else { throw Failure("world \(op) failed (\(status)): \(String(decoding: data, as: UTF8.self))") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The test runs on the main thread with no run loop to spare, so wait for the reply here.
    private nonisolated static func send(_ request: URLRequest) throws -> (Data, Int) {
        final class Box: @unchecked Sendable { var result: Result<(Data, Int), Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { box.result = .failure(error) } else {
                box.result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result!.get()
    }

    // MARK: The app

    /// Launches Poddle as a fresh install on the local backend. With an email it signs straight in
    /// with test sign-in (`-PoddleTestSignIn`).
    func launch(signedInAs email: String?, fresh: Bool = true, extra: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        var args = [
            "-PoddleConvexURL", config.convexUrl,
            "-PoddleSiteURL", config.siteUrl,
            // No companion: his idle animations keep the app from ever settling.
            "-showPoddle", "NO",
            "-PoddleAppearance", "light",
            // Undo toasts last 12 s instead of 5, so a slow run still reaches Undo in time.
            "-PoddleUndoSeconds", "12",
        ]
        if fresh { args += ["-PoddleResetState", "YES"] }
        if let email { args += ["-PoddleTestSignIn", email] }
        app.launchArguments = args + extra
        app.launch()
    }

    /// Saves what the screen looked like when a step failed, next to the xcresult's copy.
    func recordFailure(step: String, message: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "Failed: \(step)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        let tree = app.state == .notRunning ? "(the app isn't running)" : app.debugDescription
        let treeAttachment = XCTAttachment(string: tree)
        treeAttachment.name = "Accessibility tree"
        treeAttachment.lifetime = .keepAlways
        test.add(treeAttachment)

        let dir = FeatureFiles.repo.appending(path: "e2e/.runtime/ios-failures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = scenario.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        try? shot.pngRepresentation.write(to: dir.appending(path: "\(name).png"))
        try? "\(scenario)\n\(step)\n\(message)\n\n\(tree)".write(to: dir.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
    }
}
