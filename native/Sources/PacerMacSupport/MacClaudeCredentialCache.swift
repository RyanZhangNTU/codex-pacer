import Foundation
import Security
import Darwin
import PacerCore

/// The legacy macOS keychain ignores some modern per-query UI controls. Keep
/// every Pacer-owned operation in one synchronous, serialized scope and restore
/// the process setting before returning. No other app's ACL is changed.
enum ClaudeKeychainAccess {
    private static let lock = NSRecursiveLock()
    private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<UInt8>?) -> OSStatus
    private typealias SetInteraction = @convention(c) (UInt8) -> OSStatus

    static func perform<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        // These are public legacy APIs. Resolve them without turning SDK
        // deprecation diagnostics into warnings throughout otherwise modern code.
        guard let getSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainGetUserInteractionAllowed"),
              let setSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else {
            throw ClaudeQuotaError.keychainAccessRequired
        }
        let get = unsafeBitCast(getSymbol, to: GetInteraction.self)
        let set = unsafeBitCast(setSymbol, to: SetInteraction.self)
        var previous: UInt8 = 0
        guard get(&previous) == errSecSuccess, set(allowInteraction ? 1 : 0) == errSecSuccess else {
            throw ClaudeQuotaError.keychainAccessRequired
        }
        defer { _ = set(previous) }
        return try operation()
    }

    static func data(service: String, account: String? = nil, allowInteraction: Bool = false) throws -> Data? {
        try perform(allowInteraction: allowInteraction) {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: ClaudeCredentialStore.authenticationContext(allowInteraction: allowInteraction)]
            if let account { query[kSecAttrAccount as String] = account }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw ClaudeQuotaError.keychainAccessRequired }
            return result as? Data
        }
    }
}

/// Only a verified access token and its expiry are persisted. This cache never
/// contains Desktop's password/AES key, refresh tokens, cookies or identities.
/// The default legacy ACL trusts its creating app; it is never relaxed.
extension ClaudeQuotaCredentialCache {
    public static let service = "Codex Pacer Claude Quota"

    public static func read(location: String, accountBinding: String, expectedScope: String?, now: Date = Date(),
                     expectedCiphertextFingerprint: String? = nil) throws -> ClaudeOAuthCredential? {
        guard let data = try ClaudeKeychainAccess.data(service: service, account: location) else { return nil }
        do {
            let credential = try decode(data, accountBinding: accountBinding, expectedScope: expectedScope, now: now,
                                        expectedCiphertextFingerprint: expectedCiphertextFingerprint)
            if credential == nil { remove(location: location) }
            return credential
        } catch { remove(location: location); throw error }
    }

    public static func write(_ credential: ClaudeOAuthCredential, location: String, accountBinding: String, now: Date = Date(),
                      ciphertextFingerprint: String? = nil) -> Bool {
        guard let data = encode(credential, accountBinding: accountBinding, now: now, ciphertextFingerprint: ciphertextFingerprint) else { return false }
        return (try? ClaudeKeychainAccess.perform(allowInteraction: false) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: location]
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return true }
            guard update == errSecItemNotFound else { return false }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Codex Pacer Claude quota connection"
            // Omitting SecAccess retains the system's creator-only default ACL.
            // The login keychain encrypts the item; no plaintext file is written.
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }) ?? false
    }

    public static func remove(location: String) {
        try? ClaudeKeychainAccess.perform(allowInteraction: false) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: location]
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    /// Every cached connection Pacer created, whichever Claude location it served.
    public static func removeAll() {
        try? ClaudeKeychainAccess.perform(allowInteraction: false) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            _ = SecItemDelete(query as CFDictionary)
        }
    }
}

/// Explicit diagnostic fixture only: no Claude item, account, token or file is
/// involved. The packaged executable creates its own default-ACL item, then a
/// separate invocation verifies ordinary relaunch access through the quiet gate.
enum ClaudeKeychainCacheQA {
    static let service = "Codex Pacer Claude Quota QA"
    static let account = "relaunch-fixture-v1"
    static let marker = Data("pacer-keychain-qa-v1".utf8)

    static func perform(_ action: String) -> [String: Bool] {
        switch action {
        case "prepare":
            let success = (try? ClaudeKeychainAccess.perform(allowInteraction: false) {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account]
                let removed = SecItemDelete(query as CFDictionary)
                guard removed == errSecSuccess || removed == errSecItemNotFound else { return false }
                var item = query; item[kSecValueData as String] = marker
                item[kSecAttrLabel as String] = "Codex Pacer synthetic keychain QA"
                return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
            }) ?? false
            return ["prepared": success]
        case "read":
            let data = try? ClaudeKeychainAccess.data(service: service, account: account)
            return ["readable": data == marker]
        case "cleanup":
            let success = (try? ClaudeKeychainAccess.perform(allowInteraction: false) {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account]
                let status = SecItemDelete(query as CFDictionary)
                return status == errSecSuccess || status == errSecItemNotFound
            }) ?? false
            return ["removed": success]
        default: return ["validAction": false]
        }
    }
}
