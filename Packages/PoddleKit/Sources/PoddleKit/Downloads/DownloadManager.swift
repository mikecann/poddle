import Foundation
import Observation

/// One episode's download. Device-local, kept in `downloads.json` next to the files.
public struct DownloadRecord: Codable, Sendable, Hashable {
    /// `queued` waits for one of the `DownloadManager.maxConcurrent` slots.
    public enum State: String, Codable, Sendable { case queued, downloading, pausedForWifi, done, failed }

    public var episodeId: String
    public var remoteURL: String
    public var state: State
    public var bytesWritten: Int64 = 0
    public var bytesExpected: Int64 = 0
    /// Relative to the downloads folder (the app container's path changes between installs).
    public var fileName: String?
    /// Whether the request (or the one inside its resume data) may use mobile data.
    public var taskAllowsMobile: Bool
    /// "Download now on mobile": this one may use mobile whatever the allowance says.
    public var oneOffMobile: Bool
    public var isAuto: Bool
    public var completedAt: Date?
    /// Integrated loudness in LUFS, measured once after download for Voice Boost.
    public var loudness: Double?
    public var error: String?
    /// Breaks ties when picking what to start next.
    public var requestedAt: Date?

    public var progress: Double {
        if state == .done { return 1 }
        return bytesExpected > 0 ? min(1, Double(bytesWritten) / Double(bytesExpected)) : 0
    }
}

/// Bytes for one download, observed only by the small views that draw progress. Kept out of
/// `DownloadManager.records` so progress ticks don't rebuild every list that shows episodes.
@MainActor
@Observable
public final class DownloadProgress {
    public private(set) var bytesWritten: Int64
    public private(set) var bytesExpected: Int64
    /// Set directly for fake downloads (previews), which have no byte counts.
    public private(set) var fraction: Double

    public init(bytesWritten: Int64 = 0, bytesExpected: Int64 = 0, fraction: Double? = nil) {
        self.bytesWritten = bytesWritten
        self.bytesExpected = bytesExpected
        self.fraction = fraction ?? Self.fraction(bytesWritten, bytesExpected)
    }

    func update(written: Int64, expected: Int64) {
        if bytesWritten != written { bytesWritten = written }
        if expected > 0, bytesExpected != expected { bytesExpected = expected }
        let f = Self.fraction(bytesWritten, bytesExpected)
        if fraction != f { fraction = f }
    }

    public func setFraction(_ value: Double) { if fraction != value { fraction = value } }

    private static func fraction(_ written: Int64, _ expected: Int64) -> Double {
        expected > 0 ? min(1, Double(written) / Double(expected)) : 0
    }
}

/// Downloads episodes with a background `URLSession`, so they carry on while the app is suspended
/// and are picked up again after a relaunch. Interrupted downloads resume from resume data.
/// Mobile data follows `DownloadPolicy`: `allowsExpensiveNetworkAccess` is set per request, and the
/// manager pauses or restarts tasks when the network, the mode or the allowance changes.
@MainActor
@Observable
public final class DownloadManager {
    public static let sessionIdentifier = "com.mikecann.poddle.downloads"
    /// More at once just splits the bandwidth, so the top of Up Next lands later. Only while the
    /// app's in the foreground (`setInForeground`).
    public static let maxConcurrent = 2

    /// Changes only on state transitions (queued, downloading, done, failed, waiting for Wi-Fi), so
    /// lists can read it freely. Live byte counts are in `progress(for:)`.
    public private(set) var records: [String: DownloadRecord] = [:]
    public private(set) var settings: DownloadSettings
    public private(set) var network: NetworkPath = .wifi
    public let directory: URL

    /// A file landed: `(episodeId, fileURL)`. The app hands it to the player and measures loudness.
    @ObservationIgnored public var onFileReady: ((String, URL) -> Void)?
    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    @ObservationIgnored public var backgroundCompletion: (() -> Void)?
    @ObservationIgnored public var now: () -> Date

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Tasks cancelled on purpose (paused, removed), whose cancellation error should be ignored.
    @ObservationIgnored private var cancelled = Set<Int>()
    @ObservationIgnored private let monitor: (any NetworkMonitoring)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var expiryTimer: Task<Void, Never>?
    @ObservationIgnored private var lastProgressUpdate: [String: Date] = [:]
    @ObservationIgnored private var progressById: [String: DownloadProgress] = [:]
    /// Up Next positions, so queued downloads start in the order they'll be played.
    @ObservationIgnored private var order: [String: Int] = [:]
    /// False once the app leaves the foreground (`setInForeground`), which lifts the two-at-a-time cap.
    @ObservationIgnored private var inForeground = true

    private static let settingsKey = "PoddleDownloadSettings"

    public init(
        directory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        monitor: (any NetworkMonitoring)? = SystemNetworkMonitor(), defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        let dir = directory ?? Self.defaultDirectory
        self.directory = dir
        self.monitor = monitor
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(DownloadSettings.self, from: data) {
            settings = saved
        } else {
            settings = DownloadSettings()
        }
        try? FileManager.default.createDirectory(at: dir.appending(path: ".resume"), withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
        loadRecords()

        let config = configuration ?? {
            let c = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            c.sessionSendsLaunchEvents = true
            c.isDiscretionary = false
            return c
        }()
        let delegate = SessionDelegate(directory: dir) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        reattach()
        monitor?.start { [weak self] path in
            Task { @MainActor in self?.networkChanged(path) }
        }
        scheduleExpiry()
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    // MARK: Reading

    public var policy: DownloadPolicy { DownloadPolicy(settings: settings) }

    /// Every download, as rows show them. Maps all records, so prefer `download(for:)`.
    public var downloads: [String: Download] { records.mapValues { download($0) } }

    /// What an episode row shows. Its `progress` is as of the last state change; draw live
    /// progress from `progress(for:)`.
    public func download(for episodeId: String) -> Download? { records[episodeId].map(download) }

    private func download(_ r: DownloadRecord) -> Download {
        let state: Download.State = switch r.state {
        case .done: .done
        case .failed: .failed
        case .pausedForWifi: .waitingForWifi
        case .queued: network == .mobile && !policy.mayUseMobile(now: now(), oneOff: r.oneOffMobile) ? .waitingForWifi : .queued
        case .downloading: !r.taskAllowsMobile && network == .mobile && !r.oneOffMobile ? .waitingForWifi
            : r.bytesWritten > 0 ? .downloading : .queued
        }
        return Download(episodeId: r.episodeId, state: state, progress: r.progress,
                        bytes: Double(r.state == .done ? r.bytesWritten : r.bytesExpected))
    }

    /// Live bytes for one download. Observe it from a leaf view (a ring or a percentage), not a row.
    public func progress(for episodeId: String) -> DownloadProgress? {
        guard let r = records[episodeId] else { return nil }
        if let p = progressById[episodeId] { return p }
        let p = DownloadProgress(bytesWritten: r.bytesWritten, bytesExpected: r.bytesExpected, fraction: r.progress)
        progressById[episodeId] = p
        return p
    }

    /// Up Next order (episode ids). Queued downloads start in this order, after manual taps.
    public func setOrder(_ episodeIds: [String]) {
        order = Dictionary(episodeIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        startQueued()
    }

    public func localFile(for episodeId: String) -> URL? {
        guard let r = records[episodeId], r.state == .done, let name = r.fileName else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public func loudness(for episodeId: String) -> Double? { records[episodeId]?.loudness }

    func taskIdentifier(for episodeId: String) -> Int? { tasks[episodeId]?.taskIdentifier }

    public var storageUsed: Int64 {
        records.values.filter { $0.state == .done }.reduce(0) { $0 + $1.bytesWritten }
    }

    public var downloadedFiles: [(episodeId: String, bytes: Int64)] {
        records.values.filter { $0.state == .done }.map { ($0.episodeId, $0.bytesWritten) }
    }

    /// Seconds left on "allow mobile downloads", for the chip.
    public var mobileAllowanceRemaining: TimeInterval? { policy.allowanceRemaining(now: now()) }

    // MARK: Requests

    public enum RequestResult: Sendable, Hashable {
        case started, alreadyDownloaded, needsMobilePrompt
    }

    /// Download one episode. A tap over mobile data in Wi-Fi-only mode returns `.needsMobilePrompt`
    /// (then call `resolvePrompt`). Auto-downloads never prompt; they wait for Wi-Fi.
    @discardableResult
    public func request(_ episodeId: String, url: URL, auto: Bool = false) -> RequestResult {
        if let r = records[episodeId] {
            if r.state == .done { return .alreadyDownloaded }
            if r.state != .failed { return .started }
        }
        let p = policy
        if auto {
            start(episodeId, url: url, allowsMobile: p.allowsMobileForAutoDownload(now: now()), oneOff: false, auto: true)
            return .started
        }
        switch p.decisionForTap(on: network, now: now()) {
        case .ask:
            return .needsMobilePrompt
        case let .start(allowsMobile):
            start(episodeId, url: url, allowsMobile: allowsMobile, oneOff: false, auto: false)
            return .started
        }
    }

    public func resolvePrompt(_ choice: MobilePromptChoice, episodeId: String, url: URL) {
        let outcome = policy.resolve(choice, now: now())
        updateSettings(outcome.settings)
        start(episodeId, url: url, allowsMobile: outcome.allowsMobile, oneOff: outcome.oneOff, auto: false)
    }

    /// Cancels a download and deletes its file.
    public func remove(_ episodeId: String) {
        if let task = tasks.removeValue(forKey: episodeId) {
            cancelled.insert(task.taskIdentifier)
            task.cancel()
        }
        if let name = records[episodeId]?.fileName { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        try? FileManager.default.removeItem(at: resumeURL(episodeId))
        records[episodeId] = nil
        progressById[episodeId] = nil
        lastProgressUpdate[episodeId] = nil
        saveRecords()
        startQueued()
    }

    /// Cancels every download and deletes every downloaded file (deleting the account).
    public func removeAll() {
        for (_, task) in tasks {
            cancelled.insert(task.taskIdentifier)
            task.cancel()
        }
        tasks = [:]
        for record in records.values {
            if let name = record.fileName { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        }
        try? FileManager.default.removeItem(at: directory.appending(path: ".resume"))
        try? FileManager.default.createDirectory(at: directory.appending(path: ".resume"), withIntermediateDirectories: true)
        records = [:]
        progressById = [:]
        lastProgressUpdate = [:]
        saveRecords()
    }

    public func setLoudness(_ lufs: Double, for episodeId: String) {
        guard records[episodeId] != nil else { return }
        records[episodeId]?.loudness = lufs
        saveRecords()
    }

    // MARK: Settings

    public func setMode(_ mode: DownloadNetworkMode) {
        var s = settings
        s.mode = mode
        if mode == .wifiAndMobile { s.mobileAllowedUntil = nil }
        updateSettings(s)
    }

    public func allowMobile(_ allowance: MobileAllowance) {
        var s = settings
        s.mobileAllowedUntil = allowance.expiry(from: now())
        updateSettings(s)
    }

    /// The chip's Stop button.
    public func stopMobileAllowance() {
        var s = settings
        s.mobileAllowedUntil = nil
        updateSettings(s)
    }

    private func updateSettings(_ s: DownloadSettings) {
        guard s != settings else { return }
        settings = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.settingsKey) }
        scheduleExpiry()
        reconcile()
    }

    private func scheduleExpiry() {
        expiryTimer?.cancel()
        guard let until = settings.mobileAllowedUntil, until > now() else { return }
        let delay = until.timeIntervalSince(now())
        expiryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.5))
            guard !Task.isCancelled, let self else { return }
            // Expired: anything on mobile under the allowance pauses until Wi-Fi.
            self.settings.mobileAllowedUntil = nil
            if let data = try? JSONEncoder().encode(self.settings) { self.defaults.set(data, forKey: Self.settingsKey) }
            self.reconcile()
        }
    }

    /// The app is coming to the foreground or leaving it. iOS only treats downloads handed to a
    /// background session from the foreground as wanted now. Ones created later (when a slot frees
    /// up while suspended, or after a sync push) wait for the system's go-ahead, often until the
    /// phone's charging on Wi-Fi. So on the way out everything waiting is handed over at once,
    /// and the system downloads the lot while the app is gone. Back in the foreground, new ones
    /// wait for a slot again; whatever's already running carries on.
    public func setInForeground(_ foreground: Bool) {
        guard foreground != inForeground else { return }
        inForeground = foreground
        if !foreground { startQueued() }
    }

    /// Two at a time while someone's looking, so the top of Up Next lands first and progress
    /// events don't crowd scrolling. No cap while the app's away.
    private var slotLimit: Int { inForeground ? Self.maxConcurrent : .max }

    // MARK: Tasks

    private func start(_ episodeId: String, url: URL, allowsMobile: Bool, oneOff: Bool, auto: Bool) {
        if let task = tasks.removeValue(forKey: episodeId) {
            cancelled.insert(task.taskIdentifier)
            task.cancel()
        }
        let wasRunning = records[episodeId]?.state == .downloading
        var record = records[episodeId] ?? DownloadRecord(
            episodeId: episodeId, remoteURL: url.absoluteString, state: .queued,
            taskAllowsMobile: allowsMobile, oneOffMobile: oneOff, isAuto: auto)
        record.remoteURL = url.absoluteString
        record.oneOffMobile = oneOff
        record.isAuto = record.isAuto && auto
        record.error = nil
        record.requestedAt = record.requestedAt ?? now()
        if wasRunning || activeCount < slotLimit {
            records[episodeId] = record
            launch(episodeId, allowsMobile: allowsMobile, useResumeData: true)
        } else {
            record.state = .queued
            records[episodeId] = record
            saveRecords()
        }
    }

    private var activeCount: Int { records.values.count { $0.state == .downloading } }

    /// Fills free slots from the queued downloads: manual taps first, then Up Next order, then
    /// oldest request. Each gets whatever mobile data the policy allows when it starts.
    private func startQueued() {
        var free = slotLimit - activeCount
        guard free > 0 else { return }
        let waiting = records.values.filter { $0.state == .queued }.sorted { a, b in
            if a.isAuto != b.isAuto { return !a.isAuto }
            let oa = order[a.episodeId] ?? .max, ob = order[b.episodeId] ?? .max
            if oa != ob { return oa < ob }
            return (a.requestedAt ?? .distantPast, a.episodeId) < (b.requestedAt ?? .distantPast, b.episodeId)
        }
        let p = policy
        for r in waiting where free > 0 {
            launch(r.episodeId, allowsMobile: p.mayUseMobile(now: now(), oneOff: r.oneOffMobile), useResumeData: true)
            free -= 1
        }
    }

    /// Creates and starts the task, from resume data when there is some.
    private func launch(_ episodeId: String, allowsMobile: Bool, useResumeData: Bool) {
        guard var record = records[episodeId], let url = URL(string: record.remoteURL) else { return }
        let task: URLSessionDownloadTask
        if useResumeData, Self.canResume(taskAllowsMobile: record.taskAllowsMobile, allowsMobile: allowsMobile),
           let data = try? Data(contentsOf: resumeURL(episodeId)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: url)
            request.allowsExpensiveNetworkAccess = allowsMobile
            request.allowsConstrainedNetworkAccess = allowsMobile
            task = session.downloadTask(with: request)
            record.taskAllowsMobile = allowsMobile
            record.bytesWritten = 0
            progressById[episodeId]?.update(written: 0, expected: record.bytesExpected)
        }
        try? FileManager.default.removeItem(at: resumeURL(episodeId))
        task.taskDescription = episodeId
        tasks[episodeId] = task
        record.state = .downloading
        records[episodeId] = record
        saveRecords()
        task.resume()
    }

    /// A resumed request keeps the original's `allowsExpensiveNetworkAccess`, which can't be changed.
    /// So resume data is only used when that's no looser than what's allowed now. Otherwise the
    /// download starts over Wi-Fi-only: mobile isn't allowed, so it's on Wi-Fi (or waiting for it),
    /// and the bytes fetched again are free. Without this a download resumed on Wi-Fi could carry
    /// on over mobile data while the app is suspended.
    static func canResume(taskAllowsMobile: Bool, allowsMobile: Bool) -> Bool {
        allowsMobile || !taskAllowsMobile
    }

    /// Re-attaches tasks the system kept running while the app was gone, and restarts any it lost.
    private func reattach() {
        session.getAllTasks { [weak self] all in
            let found = all.compactMap { task -> (String, URLSessionDownloadTask)? in
                guard let id = task.taskDescription, let download = task as? URLSessionDownloadTask else { return nil }
                return (id, download)
            }
            let pairs = found.map { ($0.0, UncheckedTask(task: $0.1)) }
            Task { @MainActor in
                guard let self else { return }
                for (id, boxed) in pairs {
                    if self.records[id]?.state == .downloading { self.tasks[id] = boxed.task } else { boxed.task.cancel() }
                }
                // Lost ones go back in line, so they don't push past the cap.
                for (id, r) in self.records where r.state == .downloading && self.tasks[id] == nil {
                    self.records[id]?.state = .queued
                }
                self.reconcile()
            }
        }
    }

    private func networkChanged(_ path: NetworkPath) {
        guard path != network else { return }
        network = path
        reconcile()
    }

    /// Applies the mobile-data rules to every unfinished download, then fills free slots. Queued
    /// ones get the rules when they start.
    public func reconcile() {
        let p = policy
        for (id, r) in records where r.state == .downloading || r.state == .pausedForWifi {
            switch p.adjustment(taskAllowsMobile: r.taskAllowsMobile, oneOff: r.oneOffMobile,
                                isPausedForWifi: r.state == .pausedForWifi, network: network, now: now()) {
            case .none: break
            case .pauseUntilWifi: pause(id)
            case .restartAllowingMobile:
                // A Wi-Fi-only request can't be changed, so start a fresh one (it had made no progress on mobile).
                try? FileManager.default.removeItem(at: resumeURL(id))
                if let task = tasks.removeValue(forKey: id) {
                    cancelled.insert(task.taskIdentifier)
                    task.cancel()
                }
                launch(id, allowsMobile: true, useResumeData: false)
            case .restartWifiOnly:
                if let task = tasks.removeValue(forKey: id) {
                    cancelled.insert(task.taskIdentifier)
                    task.cancel()
                }
                launch(id, allowsMobile: false, useResumeData: false)
            case .resume:
                // Back in line; `startQueued` resumes it from its resume data when a slot is free.
                records[id]?.state = .queued
                saveRecords()
            }
        }
        startQueued()
    }

    private func pause(_ episodeId: String) {
        records[episodeId]?.state = .pausedForWifi
        saveRecords()
        defer { startQueued() }
        guard let task = tasks.removeValue(forKey: episodeId) else { return }
        cancelled.insert(task.taskIdentifier)
        let resume = resumeURL(episodeId)
        task.cancel(byProducingResumeData: { data in
            if let data { try? data.write(to: resume, options: .atomic) }
        })
    }

    // MARK: Delegate events

    func handle(_ event: SessionDelegate.Event) {
        switch event {
        case let .progress(id, taskId, written, expected):
            guard tasks[id]?.taskIdentifier == taskId, let r = records[id] else { return }
            // Only the first bytes (queued -> downloading) and a new size change what rows show.
            if (r.bytesWritten == 0 && written > 0) || (expected > 0 && expected != r.bytesExpected) {
                records[id]?.bytesWritten = written
                if expected > 0 { records[id]?.bytesExpected = expected }
            }
            // Progress views only need a few updates a second.
            let t = now()
            if let last = lastProgressUpdate[id], t.timeIntervalSince(last) < 0.25, written < expected { return }
            lastProgressUpdate[id] = t
            progress(for: id)?.update(written: written, expected: expected)

        case let .finished(id, taskId, fileName, bytes):
            if tasks[id]?.taskIdentifier == taskId { tasks[id] = nil }
            guard var r = records[id] else {
                try? FileManager.default.removeItem(at: directory.appending(path: fileName))
                return
            }
            r.state = .done
            r.fileName = fileName
            r.bytesWritten = bytes
            r.bytesExpected = bytes
            r.completedAt = now()
            records[id] = r
            progressById[id]?.update(written: bytes, expected: bytes)
            lastProgressUpdate[id] = nil
            saveRecords()
            startQueued()
            onFileReady?(id, directory.appending(path: fileName))

        case let .failed(id, taskId, message, resumeData):
            if cancelled.remove(taskId) != nil { return }
            guard let id, records[id] != nil else { return }
            if tasks[id]?.taskIdentifier == taskId { tasks[id] = nil }
            if let resumeData {
                try? resumeData.write(to: resumeURL(id), options: .atomic)
                // Dropped connection: carry on from where it got to in a moment, once the network allows.
                records[id]?.state = .pausedForWifi
                saveRecords()
                startQueued()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.reconcile()
                }
                return
            }
            records[id]?.state = .failed
            records[id]?.error = message
            saveRecords()
            startQueued()

        case .backgroundEventsFinished:
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    // MARK: Persistence

    private var recordsURL: URL { directory.appending(path: "downloads.json") }
    func resumeURL(_ id: String) -> URL { directory.appending(path: ".resume/\(SessionDelegate.safeName(id)).resume") }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: recordsURL),
              let saved = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) else { return }
        // Drop finished downloads whose file has gone (deleted by the system or by hand).
        records = saved.filter { _, r in
            guard r.state == .done else { return true }
            guard let name = r.fileName else { return false }
            return FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false))
        }
    }

    /// Writes on state changes only, with the latest byte counts (progress ticks don't save).
    private func saveRecords() {
        var latest = records
        for (id, p) in progressById where latest[id]?.state != .done {
            latest[id]?.bytesWritten = p.bytesWritten
            if p.bytesExpected > 0 { latest[id]?.bytesExpected = p.bytesExpected }
        }
        guard let data = try? JSONEncoder().encode(latest) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }
}

private struct UncheckedTask: @unchecked Sendable { let task: URLSessionDownloadTask }

/// `URLSession`'s delegate. Runs on the session's queue; moves finished files synchronously
/// (the temporary file is gone once the callback returns) and forwards everything else.
final class SessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    enum Event: Sendable {
        case progress(String, taskId: Int, written: Int64, expected: Int64)
        case finished(String, taskId: Int, fileName: String, bytes: Int64)
        case failed(String?, taskId: Int, message: String, resumeData: Data?)
        case backgroundEventsFinished
    }

    let directory: URL
    let send: @Sendable (Event) -> Void

    init(directory: URL, send: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.send = send
    }

    static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    static let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "m4b", "wav", "aif", "aiff", "caf", "ogg", "opus", "flac"]

    static func fileExtension(url: URL?, mimeType: String?) -> String {
        if let ext = url?.pathExtension.lowercased(), audioExtensions.contains(ext) { return ext }
        switch mimeType {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return "mp3"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        send(.progress(id, taskId: downloadTask.taskIdentifier, written: totalBytesWritten, expected: max(0, totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            send(.failed(id, taskId: downloadTask.taskIdentifier, message: "HTTP \(http.statusCode)", resumeData: nil))
            return
        }
        let ext = Self.fileExtension(url: downloadTask.response?.url ?? downloadTask.originalRequest?.url,
                                     mimeType: downloadTask.response?.mimeType)
        let name = "\(Self.safeName(id)).\(ext)"
        let destination = directory.appending(path: name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            send(.finished(id, taskId: downloadTask.taskIdentifier, fileName: name, bytes: bytes))
        } catch {
            send(.failed(id, taskId: downloadTask.taskIdentifier, message: error.localizedDescription, resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        send(.failed(task.taskDescription, taskId: task.taskIdentifier, message: error.localizedDescription, resumeData: resumeData))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        send(.backgroundEventsFinished)
    }
}
