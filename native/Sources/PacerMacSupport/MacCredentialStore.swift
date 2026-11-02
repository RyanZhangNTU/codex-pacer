import Foundation
import Security
import PacerCore

/// Each instance addresses one Pacer-owned login-keychain item.
public struct MacCredentialStore: PlatformCredentialStore {
    private let service: String
    private let account: String
    private let label: String
    public init(service: String, account: String, label: String) {
        self.service = service; self.account = account; self.label = label
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read() -> Data? {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    public var exists: Bool {
        var request = query; request[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }
    public func save(_ data: Data) -> Bool {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data; item[kSecAttrLabel as String] = label
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    public func remove() { _ = SecItemDelete(query as CFDictionary) }
}

extension DeepSeekAPIKeyStore {
    private static var applicationStore: Self {
        Self(store: MacCredentialStore(service: "Codex Pacer DeepSeek balance", account: "api-key",
            label: "Codex Pacer DeepSeek balance key"))
    }
    public static func read() -> String? { applicationStore.read() }
    public static var exists: Bool { applicationStore.exists }
    @discardableResult public static func save(_ raw: String) -> Bool { applicationStore.save(raw) }
    public static func remove() { applicationStore.remove() }
}
