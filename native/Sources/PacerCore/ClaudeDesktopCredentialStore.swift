import Foundation
import Security
import CommonCrypto

/// Read-only compatibility with the installed Claude Desktop's Electron v10
/// storage. No cookie/session keys, refresh tokens or writes are used.
enum ClaudeDesktopCredentialStore {
    struct Configuration: Sendable {
        let account: String
        let ciphertext: Data
        let identity: ClaudeAccountIdentity?
    }

    static func configuration(userHome: URL) -> Configuration? {
        let configURL = userHome.appendingPathComponent("Library/Application Support/Claude/config.json")
        guard let data = ClaudeCredentialStore.boundedData(at: configURL),
              let config = try? ClaudeQuotaDecoder.dictionary(data),
              let account = config["lastKnownAccountUuid"] as? String, UUID(uuidString: account) != nil,
              let encrypted = config["oauth:tokenCacheV2"] as? String,
              let ciphertext = Data(base64Encoded: encrypted), ciphertext.starts(with: Data("v10".utf8)) else { return nil }
        let identity = ClaudeCredentialStore.identity(userHome: userHome, home: userHome.appendingPathComponent(".claude"))
        guard identity == nil || identity?.accountID.caseInsensitiveCompare(account) == .orderedSame else { return nil }
        return Configuration(account: account.lowercased(), ciphertext: ciphertext, identity: identity)
    }

    static func read(userHome: URL, allowInteraction: Bool = false) throws -> ClaudeOAuthCredential? {
        try ClaudeDesktopCredentialReader(userHome: userHome, allowInteraction: allowInteraction).read()
    }

    static func decodeCache(_ data: Data, activeAccount: String,
                            expectedIdentity: ClaudeAccountIdentity? = nil,
                            now: Date = Date()) -> ClaudeOAuthCredential? {
        guard UUID(uuidString: activeAccount) != nil, let entries = try? ClaudeQuotaDecoder.dictionary(data),
              entries.count <= 256 else { return nil }
        // A CLI profile for another account cannot select Desktop's quota.
        guard expectedIdentity == nil || expectedIdentity?.accountID.caseInsensitiveCompare(activeAccount) == .orderedSame else { return nil }
        let expected = expectedIdentity?.accountID.caseInsensitiveCompare(activeAccount) == .orderedSame
            ? expectedIdentity : nil
        let accountPrefix = "acct:" + activeAccount.lowercased() + "|"
        var candidates: [(organization: String, credential: ClaudeOAuthCredential)] = []
        for (key, raw) in entries {
            guard key.lowercased().hasPrefix(accountPrefix), key.count <= 2048,
                  let value = raw as? [String: Any], let token = value["token"] as? String,
                  ClaudeCredentialStore.validToken(token),
                  let milliseconds = ClaudeQuotaDecoder.number(value["expiresAt"]), milliseconds > 0 else { continue }
            let suffix = String(key.dropFirst(accountPrefix.count))
            guard let endpoint = suffix.range(of: ":https://api.anthropic.com:") else { continue }
            let prefix = String(suffix[..<endpoint.lowerBound]).split(separator: ":", omittingEmptySubsequences: false)
            guard prefix.count == 2, !prefix[0].isEmpty, UUID(uuidString: String(prefix[1])) != nil else { continue }
            let organization = String(prefix[1]).lowercased()
            let scopes = Set(suffix[endpoint.upperBound...].split(separator: " ").map(String.init))
            guard scopes.contains("user:inference"), scopes.contains("user:profile"),
                  expected == nil || organization == expected?.organizationID.lowercased() else { continue }
            let expiry = Date(timeIntervalSince1970: milliseconds / 1000)
            guard expiry > now else { continue }
            let scope = ClaudeQuotaDecoder.digest("claude|" + activeAccount.lowercased() + "|" + organization)
            candidates.append((organization, ClaudeOAuthCredential(token: token, expiresAt: expiry, plan: nil, scope: scope)))
        }
        // Without an observed active organization, ambiguity is unavailable.
        guard Set(candidates.map(\.organization)).count == 1 else { return nil }
        return candidates.max { ($0.credential.expiresAt ?? .distantPast) < ($1.credential.expiresAt ?? .distantPast) }?.credential
    }

    /// Chromium's macOS v10 format uses PBKDF2-HMAC-SHA1(password, saltysalt,
    /// 1003), AES-128-CBC with a 16-space IV, and PKCS7 padding. Unknown formats
    /// fail closed. Only the decrypted token-cache object is interpreted.
    static func decryptV10(_ encrypted: Data, password: Data) -> Data? {
        guard var key = deriveKey(password: password) else { return nil }
        defer { key.resetBytes(in: 0..<key.count) }
        return decryptV10(encrypted, derivedKey: key)
    }

    static func deriveKey(password: Data) -> Data? {
        guard !password.isEmpty, password.count <= 4096 else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: Int8.self).baseAddress,
                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        return Data(key)
    }

    static func decryptV10(_ encrypted: Data, derivedKey: Data) -> Data? {
        guard encrypted.count <= 2 * 1024 * 1024, encrypted.count >= 19,
              encrypted.starts(with: Data("v10".utf8)), (encrypted.count - 3) % kCCBlockSizeAES128 == 0,
              derivedKey.count == kCCKeySizeAES128 else { return nil }
        let ciphertext = encrypted.dropFirst(3)
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        defer { _ = plaintext.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = 0
        let status = derivedKey.withUnsafeBytes { key in ciphertext.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key.baseAddress, key.count, iv, bytes.baseAddress, ciphertext.count, &plaintext, plaintext.count, &count)
        }
        }
        guard status == kCCSuccess, count > 0 else { return nil }
        return Data(plaintext.prefix(count))
    }
}

/// Legacy decoder and cache-binding seam. Production supplies no foreign
/// Keychain reader, even during Connect; the injected decoder remains available
/// for regression fixtures. Interactive sign-in uses Pacer's WebKit session.
final class ClaudeDesktopCredentialReader: @unchecked Sendable {
    typealias Configuration = ClaudeDesktopCredentialStore.Configuration
    private let lock = NSRecursiveLock()
    private let configuration: @Sendable () -> Configuration?
    private let password: @Sendable () throws -> Data?
    private let cached: @Sendable (String, String?, String?) throws -> ClaudeOAuthCredential?
    private let remember: @Sendable (ClaudeOAuthCredential, String, String?) -> Bool
    private let forget: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private var interactionAvailable: Bool
    private var derivedKey: Data?
    private var keyAccount: String?
    private var issuedAccount: String?
    private var issuedCiphertextFingerprint: String?

    convenience init(userHome: URL, allowInteraction: Bool) {
        let home = userHome.appendingPathComponent("Library/Application Support/Claude")
        let location = ClaudeQuotaCredentialCache.location(home: home, source: "desktop")
        // No production path may read another app's keychain, even Connect.
        self.init(allowInteraction: false,
            configuration: { ClaudeDesktopCredentialStore.configuration(userHome: userHome) },
            password: { throw ClaudeQuotaError.keychainAccessRequired },
            cached: { account, scope, fingerprint in
                try ClaudeQuotaCredentialCache.read(location: location,
                    accountBinding: ClaudeQuotaCredentialCache.accountBinding(home: home, account: account), expectedScope: scope,
                    expectedCiphertextFingerprint: fingerprint)
            }, remember: { credential, account, fingerprint in
                ClaudeQuotaCredentialCache.write(credential, location: location,
                    accountBinding: ClaudeQuotaCredentialCache.accountBinding(home: home, account: account), ciphertextFingerprint: fingerprint)
            }, forget: { ClaudeQuotaCredentialCache.remove(location: location) })
    }

    init(allowInteraction: Bool, configuration: @escaping @Sendable () -> Configuration?,
         password: @escaping @Sendable () throws -> Data?,
         cached: @escaping @Sendable (String, String?, String?) throws -> ClaudeOAuthCredential?,
         remember: @escaping @Sendable (ClaudeOAuthCredential, String, String?) -> Bool,
         forget: @escaping @Sendable () -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.interactionAvailable = allowInteraction; self.configuration = configuration
        self.password = password; self.cached = cached; self.remember = remember; self.forget = forget; self.now = now
    }

    func finishConnectionAttempt() { lock.lock(); interactionAvailable = false; lock.unlock() }

    func read() throws -> ClaudeOAuthCredential? {
        lock.lock(); defer { lock.unlock() }
        guard let current = configuration() else { clearKey(); forget(); return nil }
        if keyAccount != current.account { clearKey() }
        if derivedKey == nil {
            if interactionAvailable {
                interactionAvailable = false
                guard var secret = try password() else { throw ClaudeQuotaError.keychainAccessRequired }
                defer { secret.resetBytes(in: 0..<secret.count) }
                guard let key = ClaudeDesktopCredentialStore.deriveKey(password: secret) else { return nil }
                derivedKey = key; keyAccount = current.account
            } else {
                let fingerprint = current.identity == nil ? ClaudeQuotaDecoder.digest(current.ciphertext) : nil
                if let value = try cached(current.account, current.identity?.scope, fingerprint) {
                    issuedAccount = current.account; issuedCiphertextFingerprint = fingerprint; return value
                }
                throw ClaudeQuotaError.keychainAccessRequired
            }
        }
        guard let key = derivedKey,
              let plaintext = ClaudeDesktopCredentialStore.decryptV10(current.ciphertext, derivedKey: key) else {
            clearKey(); throw ClaudeQuotaError.keychainAccessRequired
        }
        guard let value = ClaudeDesktopCredentialStore.decodeCache(plaintext, activeAccount: current.account,
                                                                  expectedIdentity: current.identity, now: now()) else { return nil }
        issuedAccount = current.account
        issuedCiphertextFingerprint = current.identity == nil ? ClaudeQuotaDecoder.digest(current.ciphertext) : nil
        return value
    }

    func rememberVerified(_ credential: ClaudeOAuthCredential) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = configuration(), current.account == issuedAccount,
              current.identity == nil || current.identity?.scope == credential.scope else { return false }
        let fingerprint = current.identity == nil ? ClaudeQuotaDecoder.digest(current.ciphertext) : nil
        guard fingerprint == issuedCiphertextFingerprint else { return false }
        // The account was checked again after the live request. A changed account
        // cannot associate a previous credential with this cache slot.
        if let account = keyAccount, account != current.account { return false }
        return remember(credential, current.account, fingerprint)
    }

    func invalidate() { lock.lock(); clearKey(); forget(); interactionAvailable = false; lock.unlock() }
    func shutdown() { lock.lock(); clearKey(); interactionAvailable = false; lock.unlock() }
    private func clearKey() {
        let count = derivedKey?.count ?? 0
        derivedKey?.resetBytes(in: 0..<count)
        derivedKey = nil; keyAccount = nil; issuedAccount = nil; issuedCiphertextFingerprint = nil
    }
    deinit { clearKey() }
}
