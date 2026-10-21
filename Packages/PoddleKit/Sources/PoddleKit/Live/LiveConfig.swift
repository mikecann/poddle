import Foundation
import Security

/// Which deployment to talk to and the API token for it.
public struct LiveConfig: Sendable, Hashable {
    public var deploymentURL: URL
    public var token: String
    public init(deploymentURL: URL, token: String) { self.deploymentURL = deploymentURL; self.token = token }
}

/// The connection settings live in the Keychain. The build's values (Info.plist `PoddleConvexURL`
/// and `PoddleAPIToken`, from Config/Secrets.xcconfig) are copied in on first launch, and again
/// whenever a different build brings different values, unless Mike has pasted his own in Settings.
public enum LiveConfigStore {
    private static let service = "com.mikecann.poddle.connection"

    /// The build's own values, if it was built with secrets.
    public static func bundled(_ bundle: Bundle = .main) -> LiveConfig? {
        guard let url = (bundle.object(forInfoDictionaryKey: "PoddleConvexURL") as? String).flatMap(clean).flatMap(URL.init(string:)),
              url.host() != nil,
              let token = (bundle.object(forInfoDictionaryKey: "PoddleAPIToken") as? String).flatMap(clean) else { return nil }
        return LiveConfig(deploymentURL: url, token: token)
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("$(") || t.hasPrefix("REPLACE") ? nil : t
    }

    /// What to connect with right now.
    public static func resolve(bundle: Bundle = .main) -> LiveConfig? {
        let build = bundled(bundle)
        if read("manual") != "1", let build,
           read("seedURL") != build.deploymentURL.absoluteString || read("seedToken") != build.token {
            write("url", build.deploymentURL.absoluteString)
            write("token", build.token)
            write("seedURL", build.deploymentURL.absoluteString)
            write("seedToken", build.token)
        }
        if let url = read("url").flatMap(URL.init(string:)), let token = read("token") {
            return LiveConfig(deploymentURL: url, token: token)
        }
        return build // Keychain unavailable (unsigned builds): use the bundle directly.
    }

    /// Saves a pasted URL or token. It sticks until `resetToBuild()`.
    public static func saveManual(_ config: LiveConfig) {
        write("url", config.deploymentURL.absoluteString)
        write("token", config.token)
        write("manual", "1")
    }

    /// Goes back to the values the app was built with.
    public static func resetToBuild(bundle: Bundle = .main) -> LiveConfig? {
        delete("manual")
        delete("seedURL")
        delete("seedToken")
        return resolve(bundle: bundle)
    }

    public static var isManual: Bool { read("manual") == "1" }

    /// A stable ID for this install, for `deviceId` on positions and device registration.
    public static func deviceId() -> String {
        if let id = read("deviceId") { return id }
        let id = UUID().uuidString
        write("deviceId", id)
        return id
    }

    // MARK: Keychain

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
