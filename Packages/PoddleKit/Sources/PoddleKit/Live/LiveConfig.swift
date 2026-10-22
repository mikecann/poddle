import Foundation
import Security

/// Which deployment to talk to. Who's signed in is `Account`'s business.
public struct LiveConfig: Sendable, Hashable {
    public var deploymentURL: URL
    public init(deploymentURL: URL) { self.deploymentURL = deploymentURL }

    /// `https://<name>.<region>.convex.site`, where HTTP actions (and Convex Auth's sign-in pages) live.
    public var siteURL: URL {
        guard var parts = URLComponents(url: deploymentURL, resolvingAgainstBaseURL: false),
              let host = parts.host, host.hasSuffix(".convex.cloud") else { return deploymentURL }
        parts.host = String(host.dropLast(".convex.cloud".count)) + ".convex.site"
        return parts.url ?? deploymentURL
    }

    /// "striped-turtle-260"
    public var deploymentName: String {
        deploymentURL.host()?.split(separator: ".").first.map(String.init) ?? deploymentURL.absoluteString
    }
}

/// The build's deployment (Info.plist `PoddleConvexURL`, from Config/Debug.xcconfig or
/// Release.xcconfig) and this install's device ID.
public enum LiveConfigStore {
    private static let service = "com.mikecann.poddle.connection"

    /// The build's own deployment.
    public static func bundled(_ bundle: Bundle = .main) -> LiveConfig? {
        guard let raw = bundle.object(forInfoDictionaryKey: "PoddleConvexURL") as? String else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("$("), let url = URL(string: t), url.host() != nil else { return nil }
        return LiveConfig(deploymentURL: url)
    }

    /// A stable ID for this install, for `deviceId` on positions and device registration.
    public static func deviceId() -> String {
        if let id = Keychain.read(service: service, account: "deviceId") { return id }
        let id = UUID().uuidString
        Keychain.write(service: service, account: "deviceId", id)
        // The API token used to live here too; it's gone now accounts sign in.
        for old in ["token", "seedToken", "url", "seedURL", "manual"] { Keychain.delete(service: service, account: old) }
        return id
    }
}

/// Generic-password Keychain items, readable after the first unlock so background work can sync.
enum Keychain {
    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func readData(service: String, account: String) -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func read(service: String, account: String) -> String? {
        readData(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func write(service: String, account: String, _ value: String) {
        writeData(service: service, account: account, Data(value.utf8))
    }

    static func writeData(service: String, account: String, _ data: Data) {
        let status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(service, account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) { SecItemDelete(query(service, account) as CFDictionary) }
}
