import Foundation
import Network

/// Tells Wi-Fi from mobile data. Injectable so the download rules can be tested.
public protocol NetworkMonitoring: AnyObject, Sendable {
    /// Calls `onChange` with the current path straight away and on every change, on any thread.
    func start(_ onChange: @escaping @Sendable (NetworkPath) -> Void)
    func cancel()
}

/// `NWPathMonitor`: an expensive (cellular, hotspot) or constrained (Low Data Mode) path is mobile.
public final class SystemNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mikecann.poddle.network")

    public init() {}

    public func start(_ onChange: @escaping @Sendable (NetworkPath) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(Self.classify(path)) }
        monitor.start(queue: queue)
    }

    public func cancel() { monitor.cancel() }

    static func classify(_ path: NWPath) -> NetworkPath {
        guard path.status == .satisfied else { return .offline }
        return path.isExpensive || path.isConstrained ? .mobile : .wifi
    }
}

/// A network that only changes when told to.
public final class ManualNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var path: NetworkPath
    private var onChange: (@Sendable (NetworkPath) -> Void)?

    public init(_ path: NetworkPath = .wifi) { self.path = path }

    public func start(_ onChange: @escaping @Sendable (NetworkPath) -> Void) {
        lock.withLock { self.onChange = onChange }
        onChange(lock.withLock { path })
    }

    public func cancel() { lock.withLock { onChange = nil } }

    public func set(_ newPath: NetworkPath) {
        let callback = lock.withLock { () -> (@Sendable (NetworkPath) -> Void)? in
            path = newPath
            return onChange
        }
        callback?(newPath)
    }
}
