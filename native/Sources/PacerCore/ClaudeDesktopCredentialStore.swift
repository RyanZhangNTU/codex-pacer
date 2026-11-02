import Foundation

/// Read-only compatibility with the installed Claude Desktop's Electron v10
/// storage. No cookie/session keys, refresh tokens or writes are used.
public enum ClaudeDesktopCredentialStore {
    public struct Configuration: Sendable {
        public init(account: String, ciphertext: Data, identity: ClaudeAccountIdentity?) {
            self.account = account; self.ciphertext = ciphertext; self.identity = identity
        }
        public let account: String
        public let ciphertext: Data
        public let identity: ClaudeAccountIdentity?
    }

    public static func configuration(at configURL: URL, files: any PlatformFileSystem,
                                     identity: @Sendable () -> ClaudeAccountIdentity?) -> Configuration? {
        guard let data = ClaudeCredentialStore.boundedData(at: configURL, files: files),
              let config = try? ClaudeQuotaDecoder.dictionary(data),
              let account = config["lastKnownAccountUuid"] as? String, UUID(uuidString: account) != nil,
              let encrypted = config["oauth:tokenCacheV2"] as? String,
              let ciphertext = Data(base64Encoded: encrypted), ciphertext.starts(with: Data("v10".utf8)) else { return nil }
        let active = identity()
        guard active == nil || active?.accountID.caseInsensitiveCompare(account) == .orderedSame else { return nil }
        return Configuration(account: account.lowercased(), ciphertext: ciphertext, identity: active)
    }

    public static func decodeCache(_ data: Data, activeAccount: String,
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

}

/// Legacy decoder and cache-binding seam. Production supplies no foreign
/// Keychain reader, even during Connect; the injected decoder remains available
/// for regression fixtures. Interactive sign-in uses Pacer's WebKit session.
public final class ClaudeDesktopCredentialReader: @unchecked Sendable {
    public typealias Configuration = ClaudeDesktopCredentialStore.Configuration
    private let lock = NSRecursiveLock()
    private let configuration: @Sendable () -> Configuration?
    private let password: @Sendable () throws -> Data?
    private let cached: @Sendable (String, String?, String?) throws -> ClaudeOAuthCredential?
    private let remember: @Sendable (ClaudeOAuthCredential, String, String?) -> Bool
    private let forget: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let deriveKey: @Sendable (Data) -> Data?
    private let decrypt: @Sendable (Data, Data) -> Data?
    private var interactionAvailable: Bool
    private var derivedKey: Data?
    private var keyAccount: String?
    private var issuedAccount: String?
    private var issuedCiphertextFingerprint: String?

    public init(allowInteraction: Bool, configuration: @escaping @Sendable () -> Configuration?,
         password: @escaping @Sendable () throws -> Data?,
         cached: @escaping @Sendable (String, String?, String?) throws -> ClaudeOAuthCredential?,
         remember: @escaping @Sendable (ClaudeOAuthCredential, String, String?) -> Bool,
         forget: @escaping @Sendable () -> Void,
         deriveKey: @escaping @Sendable (Data) -> Data?, decrypt: @escaping @Sendable (Data, Data) -> Data?,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.interactionAvailable = allowInteraction; self.configuration = configuration
        self.deriveKey = deriveKey; self.decrypt = decrypt
        self.password = password; self.cached = cached; self.remember = remember; self.forget = forget; self.now = now
    }

    public func finishConnectionAttempt() { lock.lock(); interactionAvailable = false; lock.unlock() }

    public func read() throws -> ClaudeOAuthCredential? {
        lock.lock(); defer { lock.unlock() }
        guard let current = configuration() else { clearKey(); forget(); return nil }
        if keyAccount != current.account { clearKey() }
        if derivedKey == nil {
            if interactionAvailable {
                interactionAvailable = false
                guard var secret = try password() else { throw ClaudeQuotaError.keychainAccessRequired }
                defer { secret.resetBytes(in: 0..<secret.count) }
                guard let key = deriveKey(secret) else { return nil }
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
              let plaintext = decrypt(current.ciphertext, key) else {
            clearKey(); throw ClaudeQuotaError.keychainAccessRequired
        }
        guard let value = ClaudeDesktopCredentialStore.decodeCache(plaintext, activeAccount: current.account,
                                                                  expectedIdentity: current.identity, now: now()) else { return nil }
        issuedAccount = current.account
        issuedCiphertextFingerprint = current.identity == nil ? ClaudeQuotaDecoder.digest(current.ciphertext) : nil
        return value
    }

    public func rememberVerified(_ credential: ClaudeOAuthCredential) -> Bool {
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

    public func invalidate() { lock.lock(); clearKey(); forget(); interactionAvailable = false; lock.unlock() }
    public func shutdown() { lock.lock(); clearKey(); interactionAvailable = false; lock.unlock() }
    private func clearKey() {
        let count = derivedKey?.count ?? 0
        derivedKey?.resetBytes(in: 0..<count)
        derivedKey = nil; keyAccount = nil; issuedAccount = nil; issuedCiphertextFingerprint = nil
    }
    deinit { clearKey() }
}
