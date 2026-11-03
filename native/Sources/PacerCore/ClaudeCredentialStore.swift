import Foundation

public enum ClaudeCredentialStore {
    private static let identities = FileSignatureCache<ClaudeAccountIdentity?>()
    /// Claude's profile file is large and is consulted on every quota refresh.
    public static func identity(userHome: URL, home: URL, files: any PlatformFileSystem) -> ClaudeAccountIdentity? {
        let config = home.lastPathComponent == ".claude" && home.deletingLastPathComponent() == userHome
            ? userHome.appendingPathComponent(".claude.json") : home.appendingPathComponent(".claude.json")
        return identities.value(for: config, metadata: files.metadata(config)) { parseIdentity(config, files: files) }
    }
    private static func parseIdentity(_ config: URL, files: any PlatformFileSystem) -> ClaudeAccountIdentity? {
        guard let data = boundedData(at: config, files: files), let object = try? ClaudeQuotaDecoder.dictionary(data),
              let account = object["oauthAccount"] as? [String: Any],
              let accountID = account["accountUuid"] as? String, !accountID.isEmpty, accountID.count <= 256,
              let orgID = account["organizationUuid"] as? String, !orgID.isEmpty, orgID.count <= 256 else { return nil }
        return ClaudeAccountIdentity(accountID: accountID,
            scope: ClaudeQuotaDecoder.digest("claude|" + accountID.lowercased() + "|" + orgID.lowercased()), organizationID: orgID)
    }

    public static func read(userHome: URL, home: URL, environment: [String: String],
                     cachedCredential: (@Sendable (ClaudeAccountIdentity) throws -> ClaudeOAuthCredential?)? = nil,
                     now: Date = Date(), files: any PlatformFileSystem) throws -> ClaudeOAuthCredential? {
        let active = identity(userHome: userHome, home: home, files: files)
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], validToken(token) {
            return ClaudeOAuthCredential(token: token, expiresAt: nil, plan: nil,
                                         scope: ClaudeQuotaDecoder.digest("claude-token|" + token))
        }
        var cacheFailure: Error?
        if let active {
            do {
                let value = try cachedCredential?(active)
                if let value, value.expiresAt.map({ $0 > now }) ?? true { return value }
            } catch { cacheFailure = error }
        }
        if let data = boundedData(at: home.appendingPathComponent(".credentials.json"), files: files),
           let value = decode(data, active: active) { return value }
        if let cacheFailure { throw cacheFailure }
        if active != nil { throw ClaudeQuotaError.keychainAccessRequired }
        return nil
    }

    private static func decode(_ data: Data, active: ClaudeAccountIdentity?) -> ClaudeOAuthCredential? {
        guard let object = try? ClaudeQuotaDecoder.dictionary(data),
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, validToken(token) else { return nil }
        let expires = ClaudeQuotaDecoder.number(oauth["expiresAt"]).flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil
        }
        let rawPlan = oauth["subscriptionType"] as? String
        let plan = rawPlan.flatMap { ["pro", "max", "team", "enterprise"].contains($0) ? $0 : nil }
        return ClaudeOAuthCredential(token: token, expiresAt: expires, plan: plan,
                                     scope: active?.scope ?? ClaudeQuotaDecoder.digest("claude-token|" + token))
    }

    public static func rememberVerified(_ credential: ClaudeOAuthCredential, userHome: URL, home: URL,
                                 files: any PlatformFileSystem,
                                 save: @Sendable (ClaudeOAuthCredential, ClaudeAccountIdentity) -> Bool) -> Bool {
        guard let active = identity(userHome: userHome, home: home, files: files), active.scope == credential.scope else { return false }
        return save(credential, active)
    }

    public static func boundedData(at url: URL, files: any PlatformFileSystem) -> Data? {
        let maximum = 2 * 1024 * 1024
        guard let metadata = files.metadata(url), metadata.size <= UInt64(maximum),
              let data = try? files.read(url, offset: 0, maximumBytes: maximum + 1), data.count <= maximum else { return nil }
        return data
    }

    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 16_384 && !token.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// CLI-only installations have the same one-shot connection boundary. An
/// explicit read may retain its access token in memory for reply verification;
/// quiet reads can never fall through to the foreign Claude Code keychain item.
public final class ClaudeCLICredentialReader: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let quiet: @Sendable () throws -> ClaudeOAuthCredential?
    private let interactive: @Sendable () throws -> ClaudeOAuthCredential?
    private let identity: @Sendable () -> String?
    private let forget: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private var interactionAvailable: Bool
    private var memory: ClaudeOAuthCredential?
    private var memoryIdentity: String?

    public init(allowInteraction: Bool, quiet: @escaping @Sendable () throws -> ClaudeOAuthCredential?,
         interactive: @escaping @Sendable () throws -> ClaudeOAuthCredential?,
         identity: @escaping @Sendable () -> String?, forget: @escaping @Sendable () -> Void,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.interactionAvailable = allowInteraction; self.quiet = quiet; self.interactive = interactive
        self.identity = identity; self.forget = forget; self.now = now
    }

    public func read() throws -> ClaudeOAuthCredential? {
        lock.lock(); defer { lock.unlock() }
        let active = identity()
        if memory != nil && memoryIdentity != active { memory = nil; memoryIdentity = nil; forget() }
        if let memory, memory.expiresAt.map({ $0 > now() }) ?? true { return memory }
        memory = nil; memoryIdentity = nil
        // Connect selects the freshly authorized source once. A stale file or
        // copied token must not consume the attempt with 401 before this read.
        if interactionAvailable {
            interactionAvailable = false
            let value = try interactive()
            guard identity() == active else { throw ClaudeQuotaError.accountChanged }
            memory = value; memoryIdentity = active
            return value
        }
        var failure: Error = ClaudeQuotaError.keychainAccessRequired
        do {
            if let value = try quiet() {
                if value.expiresAt.map({ $0 <= now() }) == true { throw ClaudeQuotaError.credentialsExpired }
                return value
            }
        } catch { failure = error }
        throw failure
    }

    public func finishConnectionAttempt() { lock.lock(); interactionAvailable = false; lock.unlock() }
    public func shutdown() { lock.lock(); memory = nil; memoryIdentity = nil; interactionAvailable = false; lock.unlock() }
    public func invalidate() { lock.lock(); shutdown(); forget(); lock.unlock() }
}
