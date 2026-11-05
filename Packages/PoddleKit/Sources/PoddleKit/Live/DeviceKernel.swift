import Darwin

/// Which kernel this device runs. Real phones run a release kernel, betas included. Apple's test
/// devices run a development one, which is how Diagnostics tells them apart.
public enum DeviceKernel {
    public static let version: String = {
        var size = 0
        guard sysctlbyname("kern.version", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.version", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()

    public static func isDevelopment(_ version: String = DeviceKernel.version) -> Bool {
        version.contains("/DEVELOPMENT_")
    }
}
