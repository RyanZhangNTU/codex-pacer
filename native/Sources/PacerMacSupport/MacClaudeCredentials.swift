import Foundation
import LocalAuthentication
import PacerCore

extension ClaudeCredentialStore {
    public static func identity(userHome: URL, home: URL) -> ClaudeAccountIdentity? {
        identity(userHome: userHome, home: home, files: MacFileSystem())
    }
    public static func boundedData(at url: URL) -> Data? { boundedData(at: url, files: MacFileSystem()) }
    public static func read(userHome: URL, home: URL, environment: [String: String], allowInteraction: Bool = false,
                            cachedCredential: (@Sendable (ClaudeAccountIdentity) throws -> ClaudeOAuthCredential?)? = nil,
                            now: Date = Date()) throws -> ClaudeOAuthCredential? {
        try read(userHome: userHome, home: home, environment: environment, cachedCredential: cachedCredential ?? { active in
            try ClaudeQuotaCredentialCache.read(location: ClaudeQuotaCredentialCache.location(home: home, source: "cli"),
                accountBinding: ClaudeQuotaCredentialCache.accountBinding(home: home, account: active.accountID),
                expectedScope: active.scope, now: now)
        }, now: now, files: MacFileSystem())
    }
    public static func rememberVerified(_ credential: ClaudeOAuthCredential, userHome: URL, home: URL) -> Bool {
        rememberVerified(credential, userHome: userHome, home: home, files: MacFileSystem()) { credential, active in
            ClaudeQuotaCredentialCache.write(credential, location: ClaudeQuotaCredentialCache.location(home: home, source: "cli"),
                accountBinding: ClaudeQuotaCredentialCache.accountBinding(home: home, account: active.accountID))
        }
    }
    public static func invalidate(userHome: URL, home: URL) {
        ClaudeQuotaCredentialCache.remove(location: ClaudeQuotaCredentialCache.location(home: home, source: "cli"))
    }
    public static func authenticationContext(allowInteraction: Bool = false) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return context
    }
}

extension ClaudeCLICredentialReader {
    public convenience init(userHome: URL, home: URL, environment: [String: String], allowInteraction: Bool) {
        self.init(allowInteraction: allowInteraction,
            quiet: { try ClaudeCredentialStore.read(userHome: userHome, home: home, environment: environment, allowInteraction: false) },
            interactive: { try ClaudeCredentialStore.read(userHome: userHome, home: home, environment: environment, allowInteraction: true) },
            identity: { ClaudeCredentialStore.identity(userHome: userHome, home: home)?.scope },
            forget: { ClaudeCredentialStore.invalidate(userHome: userHome, home: home) })
    }
}

extension ClaudeDesktopCredentialStore {
    public static func configuration(userHome: URL) -> Configuration? {
        configuration(at: userHome.appendingPathComponent("Library/Application Support/Claude/config.json"),
            files: MacFileSystem(), identity: {
                ClaudeCredentialStore.identity(userHome: userHome, home: userHome.appendingPathComponent(".claude"))
            })
    }
    public static func read(userHome: URL, allowInteraction: Bool = false) throws -> ClaudeOAuthCredential? {
        try ClaudeDesktopCredentialReader(userHome: userHome, allowInteraction: allowInteraction).read()
    }
}

extension ClaudeDesktopCredentialReader {
    public convenience init(userHome: URL, allowInteraction: Bool) {
        let home = userHome.appendingPathComponent("Library/Application Support/Claude")
        let location = ClaudeQuotaCredentialCache.location(home: home, source: "desktop")
        // Production never reads another app's keychain, including during Connect.
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
    public convenience init(allowInteraction: Bool, configuration: @escaping @Sendable () -> Configuration?,
                            password: @escaping @Sendable () throws -> Data?,
                            cached: @escaping @Sendable (String, String?, String?) throws -> ClaudeOAuthCredential?,
                            remember: @escaping @Sendable (ClaudeOAuthCredential, String, String?) -> Bool,
                            forget: @escaping @Sendable () -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(allowInteraction: allowInteraction, configuration: configuration, password: password, cached: cached,
            remember: remember, forget: forget,
            deriveKey: { ClaudeDesktopCredentialStore.deriveKey(password: $0) },
            decrypt: { ClaudeDesktopCredentialStore.decryptV10($0, derivedKey: $1) }, now: now)
    }
}
