import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum ClaudeQuotaSource: String, Codable, Equatable, Sendable {
    case statusLine, oauthUsage, desktopHistory, webSession

    public var label: String {
        switch self {
        case .statusLine: return L10n.text("claude.quota.source_statusline")
        case .oauthUsage: return L10n.text("claude.quota.source_oauth")
        case .desktopHistory: return L10n.text("claude.quota.source_history")
        case .webSession: return L10n.text("claude.quota.source_web")
        }
    }
}

/// Errors contain no underlying response text, token, account identity or URL.
public enum ClaudeQuotaError: Error, LocalizedError, Equatable {
    case notLoggedIn, credentialsExpired, unavailable, invalidReply, denied, timedOut, connectionFailed, accountChanged, keychainAccessRequired, webChallenge, organizationSelectionRequired

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L10n.text("claude.quota.not_logged_in")
        case .credentialsExpired: return L10n.text("claude.quota.credentials_expired")
        case .unavailable: return L10n.text("claude.quota.unavailable")
        case .invalidReply: return L10n.text("claude.quota.invalid_reply")
        case .denied: return L10n.text("claude.quota.denied")
        case .timedOut: return L10n.text("claude.quota.timed_out")
        case .connectionFailed: return L10n.text("claude.quota.connection_failed")
        case .accountChanged: return L10n.text("claude.quota.account_changed")
        case .keychainAccessRequired: return L10n.text("claude.quota.keychain_access_required")
        case .webChallenge: return L10n.text("claude.quota.web_challenge")
        case .organizationSelectionRequired: return L10n.text("claude.quota.organization_required")
        }
    }
}

public enum ClaudeQuotaDecoder {
    public static func decodeUsage(_ data: Data, capturedAt: Date = Date(),
                                   accountScope: String? = nil, plan: String? = nil) throws -> QuotaSnapshot {
        let object = try dictionary(data)
        let fields = object["rate_limits"] as? [String: Any] ?? object
        let buckets = buckets(from: fields, percentageKey: "utilization", plan: plan)
        guard buckets.contains(where: { $0.windows.contains { $0.usedPercent != nil } }) else {
            throw ClaudeQuotaError.unavailable
        }
        return QuotaSnapshot(buckets: buckets, capturedAt: capturedAt, accountScope: accountScope, resetCredits: nil)
    }

    public static func decodeStatusLine(_ data: Data, capturedAt: Date = Date(),
                                        accountScope: String? = nil) throws -> QuotaSnapshot {
        let object = try dictionary(data)
        let payload = object["payload"] as? [String: Any] ?? object
        guard let fields = payload["rate_limits"] as? [String: Any] else { throw ClaudeQuotaError.unavailable }
        let buckets = buckets(from: fields, percentageKey: "used_percentage", plan: nil)
        guard buckets.contains(where: { $0.windows.contains { $0.usedPercent != nil } }) else {
            throw ClaudeQuotaError.unavailable
        }
        return QuotaSnapshot(buckets: buckets, capturedAt: capturedAt, accountScope: accountScope, resetCredits: nil)
    }

    private static func buckets(from fields: [String: Any], percentageKey: String, plan: String?) -> [QuotaBucket] {
        func window(_ field: String, id: String, minutes: Int) -> QuotaWindow? {
            guard let value = fields[field] as? [String: Any] else { return nil }
            let used = number(value[percentageKey]).flatMap { $0 >= 0 ? $0 : nil }
            let reset = date(value["resets_at"])
            guard used != nil || reset != nil else { return nil }
            return QuotaWindow(id: id, usedPercent: used, durationMinutes: minutes, resetsAt: reset)
        }
        let primary = window("five_hour", id: "claude/primary", minutes: 300)
        let secondary = window("seven_day", id: "claude/secondary", minutes: 10080)
        var result: [QuotaBucket] = []
        let global = [primary, secondary].compactMap { $0 }
        if !global.isEmpty { result.append(QuotaBucket(id: "claude", name: "Claude", plan: plan, windows: global, credits: nil)) }
        for (field, model) in [("seven_day_sonnet", "sonnet"), ("seven_day_opus", "opus")] {
            let id = "claude/\(model)"
            if let value = window(field, id: id + "/secondary", minutes: 10080) {
                result.append(QuotaBucket(id: id, name: "Claude " + model.capitalized, plan: plan, windows: [value], credits: nil))
            }
        }
        // Newer usage responses report model-specific weekly allocations as limits.
        for value in (fields["limits"] as? [[String: Any]] ?? []).prefix(32) {
            guard value["kind"] as? String == "weekly_scoped",
                  let scope = value["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty, name.count <= 80,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let percent = number(value["percent"]), percent >= 0 else { continue }
            let id = "claude/model/" + digest(name)
            guard !result.contains(where: { $0.id == id }) else { continue }
            let value = QuotaWindow(id: id + "/secondary", usedPercent: percent, durationMinutes: 10080,
                                    resetsAt: date(value["resets_at"]))
            result.append(QuotaBucket(id: id, name: name, plan: plan, windows: [value], credits: nil))
        }
        return result
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeQuotaError.invalidReply
        }
        return value
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0, seconds < 253_402_300_800 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String, text.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct ClaudeOAuthCredential: Sendable {
    let token: String
    let expiresAt: Date?
    let plan: String?
    let scope: String
}

struct ClaudeAccountIdentity: Sendable {
    let accountID: String
    let scope: String
    let organizationID: String
}

public actor ClaudeQuotaClient {
    public nonisolated static func credentialCacheDiagnostics(action: String) -> [String: Bool] {
        ClaudeKeychainCacheQA.perform(action)
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let statusLineURL: URL
    private let credentialProvider: @Sendable () throws -> ClaudeOAuthCredential?
    private let desktopCredentialProvider: (@Sendable () throws -> ClaudeOAuthCredential?)?
    private let identityProvider: @Sendable () -> (scope: String, organizationID: String)?
    private let transport: Transport
    private let session: URLSession?
    private let rememberCredential: @Sendable (Int, ClaudeOAuthCredential) -> Bool
    private let invalidateCredential: @Sendable (Int) -> Void
    private let finishConnectionAttempt: @Sendable () -> Void
    private let discardCredentialMemory: @Sendable () -> Void
    private let persistVerifiedCredentials: Bool
    private let now: @Sendable () -> Date
    private var quotaTask: Task<QuotaSnapshot, Error>?
    private var verifiedScope: String?
    private var savedConnection: Bool?
    private var source: ClaudeQuotaSource?
    private struct VerifiedAuthentication {
        let providerIndex: Int
        let scope: String
        let tokenFingerprint: String
    }
    private var verifiedAuthentication: VerifiedAuthentication?
    private struct Throttle {
        let providerIndex: Int
        let scope: String
        let tokenFingerprint: String
        let retryAt: Date
    }
    private var throttle: Throttle?

    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                home: URL? = nil, statusLineURL: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 12, allowKeychainInteraction: Bool = false) {
        let claudeHome = home ?? environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? userHome.appendingPathComponent(".claude")
        persistVerifiedCredentials = allowKeychainInteraction
        let environmentHome = environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? userHome.appendingPathComponent(".claude")
        var selectedEnvironment = environment
        if claudeHome.standardizedFileURL != environmentHome.standardizedFileURL {
            selectedEnvironment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        }
        let credentialEnvironment = selectedEnvironment
        let usesEnvironmentToken = !(credentialEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty
        self.statusLineURL = statusLineURL ?? claudeHome.appendingPathComponent("pacer/claude-statusline.json")
        identityProvider = {
            // An explicitly supplied token has no verified binding to the saved
            // CLI profile. Isolate it by token and do not borrow profile caches.
            usesEnvironmentToken ? nil : ClaudeCredentialStore.identity(userHome: userHome, home: claudeHome)
                .map { ($0.scope, $0.organizationID) }
        }
        let usesDefaultHome = claudeHome.standardizedFileURL == userHome.appendingPathComponent(".claude").standardizedFileURL
        let desktopEligible = usesDefaultHome && !usesEnvironmentToken && ClaudeDesktopCredentialStore.configuration(userHome: userHome) != nil
        let cliReader = ClaudeCLICredentialReader(userHome: userHome, home: claudeHome, environment: credentialEnvironment,
                                                 allowInteraction: allowKeychainInteraction && !desktopEligible)
        credentialProvider = { try cliReader.read() }
        let desktopReader: ClaudeDesktopCredentialReader?
        if usesDefaultHome && !usesEnvironmentToken {
            let reader = ClaudeDesktopCredentialReader(userHome: userHome, allowInteraction: allowKeychainInteraction)
            desktopReader = reader
            desktopCredentialProvider = { try reader.read() }
        } else {
            desktopReader = nil
            desktopCredentialProvider = nil
        }
        rememberCredential = { index, credential in
            if index == 1 { return desktopReader?.rememberVerified(credential) ?? false }
            return ClaudeCredentialStore.rememberVerified(credential, userHome: userHome, home: claudeHome)
        }
        invalidateCredential = { index in
            if index == 1 { desktopReader?.invalidate() }
            else { cliReader.invalidate() }
        }
        finishConnectionAttempt = { desktopReader?.finishConnectionAttempt(); cliReader.finishConnectionAttempt() }
        discardCredentialMemory = { desktopReader?.shutdown(); cliReader.shutdown() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(60, max(1, timeout))
        configuration.timeoutIntervalForResource = min(65, max(2, timeout + 3))
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeQuotaSessionDelegate(), delegateQueue: nil)
        self.session = session
        transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ClaudeQuotaError.invalidReply }
            return (data, response)
        }
        now = { Date() }
    }

    init(statusLineURL: URL,
         credentialProvider: @escaping @Sendable () throws -> ClaudeOAuthCredential?,
         desktopCredentialProvider: (@Sendable () throws -> ClaudeOAuthCredential?)? = nil,
         identityProvider: @escaping @Sendable () -> (scope: String, organizationID: String)?,
         transport: @escaping Transport, now: @escaping @Sendable () -> Date,
         persistVerifiedCredentials: Bool = false,
         rememberCredential: @escaping @Sendable (Int, ClaudeOAuthCredential) -> Bool = { _, _ in true },
         invalidateCredential: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.statusLineURL = statusLineURL
        self.credentialProvider = credentialProvider; self.identityProvider = identityProvider
        self.desktopCredentialProvider = desktopCredentialProvider
        self.transport = transport; self.now = now
        self.rememberCredential = rememberCredential; self.invalidateCredential = invalidateCredential
        self.persistVerifiedCredentials = persistVerifiedCredentials
        finishConnectionAttempt = {}; discardCredentialMemory = {}
        session = nil
    }

    public func currentAccountScope() -> String? { verifiedScope }
    public func currentSource() -> ClaudeQuotaSource? { source }
    public func connectionSaved() -> Bool? { savedConnection }
    public func nextRetryAt() -> Date? { throttle?.retryAt }

    /// The passive source never requests HTTP or reads a keychain item. A sample
    /// keeps its original timestamp and must match the current observed profile.
    public func readStatusLineOnly() -> QuotaSnapshot? {
        let capturedAt = now()
        guard let value = statusLine(identity: identityProvider(), now: capturedAt),
              !value.isStale(at: capturedAt, interval: 60) else { return nil }
        verifiedScope = value.accountScope; source = .statusLine
        verifiedAuthentication = nil; savedConnection = nil
        return value
    }

    public func readQuota() async throws -> QuotaSnapshot {
        if let quotaTask { return try await quotaTask.value }
        let task = Task { try await fetchQuota() }
        quotaTask = task
        defer { quotaTask = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    public func shutdown() async {
        quotaTask?.cancel(); quotaTask = nil; verifiedScope = nil; source = nil; verifiedAuthentication = nil
        throttle = nil
        savedConnection = nil
        discardCredentialMemory()
        session?.invalidateAndCancel()
    }

    private func fetchQuota() async throws -> QuotaSnapshot {
        defer { finishConnectionAttempt() }
        let previousSource = source, previousAuthentication = verifiedAuthentication
        source = nil; verifiedScope = nil; verifiedAuthentication = nil
        try Task.checkCancellation()
        let identity = identityProvider()
        let capturedAt = now()
        let providers = [credentialProvider] + (desktopCredentialProvider.map { [$0] } ?? [])
        // A recent supported sample remains usable while the private service
        // asks this authentication context to wait. Preserve its backoff for
        // the next read that actually needs the private endpoint.
        if let value = statusLine(identity: identity, now: capturedAt),
           !value.isStale(at: capturedAt, interval: 60) {
            verifiedScope = value.accountScope; source = .statusLine
            if previousAuthentication?.scope == value.accountScope { verifiedAuthentication = previousAuthentication }
            return value
        }
        if let pending = throttle, pending.retryAt > capturedAt,
           providers.indices.contains(pending.providerIndex),
           let current = try? providers[pending.providerIndex](), current.scope == pending.scope,
           ClaudeQuotaDecoder.digest(current.token) == pending.tokenFingerprint,
           pending.providerIndex != 0 || identity == nil || identity?.scope == pending.scope {
            if let previous = previousAuthentication, previous.providerIndex == pending.providerIndex,
               previous.scope == pending.scope, previous.tokenFingerprint == pending.tokenFingerprint {
                verifiedScope = previous.scope; source = previousSource; verifiedAuthentication = previous
            }
            throw ClaudeQuotaError.unavailable
        }
        // A changed token/account or an elapsed deadline must not carry another
        // authentication context's server backoff into the new request.
        throttle = nil
        var failure: Error = ClaudeQuotaError.notLoggedIn
        var attempted: (index: Int, credential: ClaudeOAuthCredential)?
        var order = Array(providers.indices)
        var preferred: ClaudeOAuthCredential?
        if let previous = previousAuthentication, providers.indices.contains(previous.providerIndex),
           let current = try? providers[previous.providerIndex](), current.scope == previous.scope,
           ClaudeQuotaDecoder.digest(current.token) == previous.tokenFingerprint {
            order.removeAll { $0 == previous.providerIndex }
            order.insert(previous.providerIndex, at: 0)
            preferred = current
        }
        for index in order {
          let provider = providers[index]
          do {
            let resolvedCredential: ClaudeOAuthCredential?
            if index == previousAuthentication?.providerIndex, let preferred { resolvedCredential = preferred }
            else { resolvedCredential = try provider() }
            if let credential = resolvedCredential {
                if credential.expiresAt.map({ $0 <= capturedAt }) == true { throw ClaudeQuotaError.credentialsExpired }
                attempted = (index, credential)
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
                request.httpMethod = "GET"
                request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                // The same private, version-sensitive endpoint used by the installed
                // Claude Desktop. Credentials and responses remain in memory.
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                switch response.statusCode {
                case 200: break
                case 401: invalidateCredential(index); throw ClaudeQuotaError.notLoggedIn
                case 403: invalidateCredential(index); throw ClaudeQuotaError.denied
                case 429:
                    if let retryAt = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now()) {
                        throttle = Throttle(providerIndex: index, scope: credential.scope,
                            tokenFingerprint: ClaudeQuotaDecoder.digest(credential.token), retryAt: retryAt)
                    }
                    throw ClaudeQuotaError.unavailable
                default: throw ClaudeQuotaError.connectionFailed
                }
                if index == 0 {
                    let currentIdentity = identityProvider()
                    guard currentIdentity?.scope == identity?.scope else { throw ClaudeQuotaError.accountChanged }
                }
                guard let current = try provider(),
                      current.scope == credential.scope,
                      ClaudeQuotaDecoder.digest(current.token) == ClaudeQuotaDecoder.digest(credential.token) else {
                    throw ClaudeQuotaError.accountChanged
                }
                let value = try ClaudeQuotaDecoder.decodeUsage(data, capturedAt: now(), accountScope: credential.scope,
                                                              plan: credential.plan)
                if persistVerifiedCredentials { savedConnection = rememberCredential(index, current) }
                verifiedScope = value.accountScope; source = .oauthUsage
                verifiedAuthentication = VerifiedAuthentication(providerIndex: index, scope: credential.scope,
                                                                tokenFingerprint: ClaudeQuotaDecoder.digest(credential.token))
                return value
            }
          } catch is CancellationError { throw CancellationError() }
          catch let error as ClaudeQuotaError {
            if error == .accountChanged { invalidateCredential(index); throw error }
            failure = error
            // Desktop is a separate authenticated client. Try its already stored
            // token only when CLI credentials are absent, expired or rejected.
            if ![.notLoggedIn, .credentialsExpired, .keychainAccessRequired].contains(error) { break }
          } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            failure = error.code == .timedOut ? ClaudeQuotaError.timedOut : ClaudeQuotaError.connectionFailed
            break
          } catch { failure = ClaudeQuotaError.connectionFailed; break }
        }
        try Task.checkCancellation()
        // An auth failure must not resurrect a previous account's cached quota.
        let transient = (failure as? ClaudeQuotaError).map {
            [ClaudeQuotaError.connectionFailed, .timedOut, .invalidReply, .unavailable].contains($0)
        } ?? false
        if transient, let active = identityProvider(), active.scope == identity?.scope {
            if let value = statusLine(identity: active, now: capturedAt) {
                verifiedScope = value.accountScope; source = .statusLine
                return value
            }
        }
        if let error = failure as? ClaudeQuotaError,
           [.connectionFailed, .timedOut, .invalidReply, .unavailable].contains(error),
           let previous = previousAuthentication, let attempt = attempted,
           previous.providerIndex == attempt.index, previous.scope == attempt.credential.scope,
           previous.tokenFingerprint == ClaudeQuotaDecoder.digest(attempt.credential.token),
           let current = try? providers[attempt.index](), current.scope == previous.scope,
           ClaudeQuotaDecoder.digest(current.token) == previous.tokenFingerprint,
           attempt.index != 0 || identityProvider()?.scope == identity?.scope {
            // Let the presentation retain its last real sample with its original
            // freshness timestamp during a transient outage of the same account.
            verifiedScope = previous.scope; verifiedAuthentication = previous; source = previousSource
        }
        throw failure
    }

    private func statusLine(identity: (scope: String, organizationID: String)?, now: Date) -> QuotaSnapshot? {
        guard let data = boundedData(at: statusLineURL), let envelope = try? ClaudeQuotaDecoder.dictionary(data),
              let seconds = ClaudeQuotaDecoder.number(envelope["captured_at"]), seconds > 0 else { return nil }
        let stamp = Date(timeIntervalSince1970: seconds)
        guard stamp <= now.addingTimeInterval(5), now.timeIntervalSince(stamp) <= 300,
              let scope = envelope["account_scope"] as? String,
              scope.count == 64, scope.allSatisfy({ $0.isHexDigit }), scope == identity?.scope else { return nil }
        return try? ClaudeQuotaDecoder.decodeStatusLine(data, capturedAt: stamp, accountScope: scope)
    }

    private func boundedData(at url: URL) -> Data? { ClaudeCredentialStore.boundedData(at: url) }

    static func retryDate(_ header: String?, now: Date) -> Date? {
        guard let header, header.count <= 128 else { return nil }
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval: TimeInterval
        if let seconds = Double(text), seconds.isFinite { interval = seconds }
        else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: text) else { return nil }
            interval = date.timeIntervalSince(now)
        }
        guard interval > 0 else { return nil }
        return now.addingTimeInterval(min(600, interval))
    }
}

private final class ClaudeQuotaSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A compatibility read may not forward a stored bearer token elsewhere.
        completionHandler(nil)
    }
}

enum ClaudeCredentialStore {
    private static let identities = FileSignatureCache<ClaudeAccountIdentity?>()
    /// Claude's profile file is large and is consulted on every quota refresh.
    static func identity(userHome: URL, home: URL) -> ClaudeAccountIdentity? {
        let config = home.lastPathComponent == ".claude" && home.deletingLastPathComponent() == userHome
            ? userHome.appendingPathComponent(".claude.json") : home.appendingPathComponent(".claude.json")
        return identities.value(for: config) { parseIdentity(config) }
    }
    private static func parseIdentity(_ config: URL) -> ClaudeAccountIdentity? {
        guard let data = boundedData(at: config), let object = try? ClaudeQuotaDecoder.dictionary(data),
              let account = object["oauthAccount"] as? [String: Any],
              let accountID = account["accountUuid"] as? String, !accountID.isEmpty, accountID.count <= 256,
              let orgID = account["organizationUuid"] as? String, !orgID.isEmpty, orgID.count <= 256 else { return nil }
        return ClaudeAccountIdentity(accountID: accountID,
            scope: ClaudeQuotaDecoder.digest("claude|" + accountID.lowercased() + "|" + orgID.lowercased()), organizationID: orgID)
    }

    static func read(userHome: URL, home: URL, environment: [String: String],
                     allowInteraction: Bool = false,
                     cachedCredential: (@Sendable (ClaudeAccountIdentity) throws -> ClaudeOAuthCredential?)? = nil,
                     now: Date = Date()) throws -> ClaudeOAuthCredential? {
        let active = identity(userHome: userHome, home: home)
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], validToken(token) {
            return ClaudeOAuthCredential(token: token, expiresAt: nil, plan: nil,
                                         scope: ClaudeQuotaDecoder.digest("claude-token|" + token))
        }
        var cacheFailure: Error?
        if let active {
            do {
                let value: ClaudeOAuthCredential?
                if let cachedCredential { value = try cachedCredential(active) }
                else {
                    value = try ClaudeQuotaCredentialCache.read(location: ClaudeQuotaCredentialCache.location(home: home, source: "cli"),
                        accountBinding: ClaudeQuotaCredentialCache.accountBinding(home: home, account: active.accountID), expectedScope: active.scope, now: now)
                }
                if let value, value.expiresAt.map({ $0 > now }) ?? true { return value }
            } catch { cacheFailure = error }
        }
        if let data = boundedData(at: home.appendingPathComponent(".credentials.json")),
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

    static func rememberVerified(_ credential: ClaudeOAuthCredential, userHome: URL, home: URL) -> Bool {
        guard let active = identity(userHome: userHome, home: home), active.scope == credential.scope else { return false }
        return ClaudeQuotaCredentialCache.write(credential, location: ClaudeQuotaCredentialCache.location(home: home, source: "cli"),
            accountBinding: ClaudeQuotaCredentialCache.accountBinding(home: home, account: active.accountID))
    }

    static func invalidate(userHome: URL, home: URL) {
        ClaudeQuotaCredentialCache.remove(location: ClaudeQuotaCredentialCache.location(home: home, source: "cli"))
    }

    static func boundedData(at url: URL) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        return data
    }

    static func authenticationContext(allowInteraction: Bool = false) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return context
    }

    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 16_384 && !token.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// CLI-only installations have the same one-shot connection boundary. An
/// explicit read may retain its access token in memory for reply verification;
/// quiet reads can never fall through to the foreign Claude Code keychain item.
final class ClaudeCLICredentialReader: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let quiet: @Sendable () throws -> ClaudeOAuthCredential?
    private let interactive: @Sendable () throws -> ClaudeOAuthCredential?
    private let identity: @Sendable () -> String?
    private let forget: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private var interactionAvailable: Bool
    private var memory: ClaudeOAuthCredential?
    private var memoryIdentity: String?

    convenience init(userHome: URL, home: URL, environment: [String: String], allowInteraction: Bool) {
        self.init(allowInteraction: allowInteraction,
            quiet: { try ClaudeCredentialStore.read(userHome: userHome, home: home, environment: environment, allowInteraction: false) },
            interactive: { try ClaudeCredentialStore.read(userHome: userHome, home: home, environment: environment, allowInteraction: true) },
            identity: { ClaudeCredentialStore.identity(userHome: userHome, home: home)?.scope },
            forget: { ClaudeCredentialStore.invalidate(userHome: userHome, home: home) })
    }

    init(allowInteraction: Bool, quiet: @escaping @Sendable () throws -> ClaudeOAuthCredential?,
         interactive: @escaping @Sendable () throws -> ClaudeOAuthCredential?,
         identity: @escaping @Sendable () -> String?, forget: @escaping @Sendable () -> Void,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.interactionAvailable = allowInteraction; self.quiet = quiet; self.interactive = interactive
        self.identity = identity; self.forget = forget; self.now = now
    }

    func read() throws -> ClaudeOAuthCredential? {
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

    func finishConnectionAttempt() { lock.lock(); interactionAvailable = false; lock.unlock() }
    func shutdown() { lock.lock(); memory = nil; memoryIdentity = nil; interactionAvailable = false; lock.unlock() }
    func invalidate() { lock.lock(); shutdown(); forget(); lock.unlock() }
}
