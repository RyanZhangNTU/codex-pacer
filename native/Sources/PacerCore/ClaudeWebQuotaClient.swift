import Foundation

/// Supplied only by Pacer's own WebKit profile. Cookie values stay in memory;
/// neither this adapter nor its quota history writes or imports browser cookies.
public struct ClaudeWebSession: Sendable {
    public let cookieHeader: String
    public let sessionHash: String
    public let organizationID: String?
    public let userAgent: String?
    public init(cookieHeader: String, sessionHash: String, organizationID: String? = nil, userAgent: String? = nil) {
        self.cookieHeader = cookieHeader; self.sessionHash = sessionHash; self.organizationID = organizationID
        self.userAgent = userAgent
    }
}

public struct ClaudeWebOrganization: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public init(id: String, name: String? = nil) { self.id = id; self.name = name }
}

public struct ClaudeWebAccountBinding: Equatable, Sendable {
    public let accountID: String?
    public let organizationID: String?
    public let conflictingAccounts: Bool
    public init(accountID: String? = nil, organizationID: String? = nil, conflictingAccounts: Bool = false) {
        self.accountID = accountID; self.organizationID = organizationID; self.conflictingAccounts = conflictingAccounts
    }
}

public enum ClaudeWebQuotaDecoder {
    static func uuid(_ text: String?) -> String? {
        guard let text, text.count == 36 else { return nil }
        return UUID(uuidString: text)?.uuidString.lowercased()
    }

    public static func accountID(_ data: Data) throws -> String {
        let fields = try ClaudeQuotaDecoder.dictionary(data)
        let account = fields["account"] as? [String: Any] ?? fields
        guard let id = uuid(account["uuid"] as? String) else { throw ClaudeQuotaError.invalidReply }
        return id
    }

    public static func organizations(_ data: Data) throws -> [ClaudeWebOrganization] {
        guard data.count <= 2 * 1024 * 1024,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty, rows.count <= 64 else { throw ClaudeQuotaError.invalidReply }
        var result: [ClaudeWebOrganization] = [], seen = Set<String>()
        for row in rows {
            guard let id = uuid(row["uuid"] as? String), seen.insert(id).inserted else { throw ClaudeQuotaError.invalidReply }
            let name = (row["name"] as? String).flatMap {
                !$0.isEmpty && $0.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? $0 : nil
            }
            result.append(ClaudeWebOrganization(id: id, name: name))
        }
        return result
    }

    static func sessionKey(_ value: ClaudeWebSession) -> String? {
        guard !value.cookieHeader.isEmpty, value.cookieHeader.utf8.count <= 65_536,
              !value.cookieHeader.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.sessionHash.count == 64, value.sessionHash.allSatisfy(\.isHexDigit) else { return nil }
        let candidates = value.cookieHeader.split(separator: ";").compactMap { part -> String? in
            let field = part.trimmingCharacters(in: .whitespaces), pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pieces.count == 2 && pieces[0] == "sessionKey" ? String(pieces[1]) : nil
        }
        guard candidates.count == 1, let key = candidates.first, ClaudeCredentialStore.validToken(key),
              ClaudeQuotaDecoder.digest(key) == value.sessionHash.lowercased() else { return nil }
        return key
    }

    static func isChallenge(_ data: Data, response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" { return true }
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true { return true }
        let prefix = String(data: data.prefix(4096), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
    }
}

/// Read-only requests to claude.ai using an independently signed-in Pacer web
/// session. No Claude/Safari/Chrome keychain access or credential extraction.
public actor ClaudeWebQuotaClient {
    public typealias CookieProvider = @Sendable () async -> ClaudeWebSession?
    public typealias MetadataProvider = @Sendable () -> ClaudeWebAccountBinding
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Identity {
        let sessionHash: String
        let account: String
        let organizations: [ClaudeWebOrganization]
    }
    private struct Throttle { let sessionHash: String; let binding: ClaudeWebAccountBinding; let retryAt: Date }
    private let cookieProvider: CookieProvider
    private let metadataProvider: MetadataProvider
    private let selectedOrganizationProvider: @Sendable () -> String?
    private let transport: Transport
    private let session: URLSession?
    private let now: @Sendable () -> Date
    private var identity: Identity?
    private var verifiedScope: String?
    private var verifiedSessionHash: String?
    private var verifiedBinding: ClaudeWebAccountBinding?
    private var source: ClaudeQuotaSource?
    private var throttle: Throttle?
    private var task: Task<QuotaSnapshot, Error>?

    public init(cookieProvider: @escaping CookieProvider, home: URL? = nil,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                selectedOrganizationProvider: @escaping @Sendable () -> String? = { nil },
                metadataProvider: MetadataProvider? = nil, timeout: TimeInterval = 12) {
        self.cookieProvider = cookieProvider; self.selectedOrganizationProvider = selectedOrganizationProvider
        let home = home ?? userHome.appendingPathComponent(".claude")
        self.metadataProvider = metadataProvider ?? { Self.observedBinding(userHome: userHome, home: home) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = min(30, max(1, timeout))
        configuration.timeoutIntervalForResource = min(35, max(2, timeout + 3))
        let session = URLSession(configuration: configuration, delegate: ClaudeWebQuotaRedirectDelegate(), delegateQueue: nil)
        self.session = session
        transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ClaudeQuotaError.invalidReply }
            return (data, response)
        }
        now = { Date() }
    }

    init(cookieProvider: @escaping CookieProvider, metadataProvider: @escaping MetadataProvider,
         selectedOrganizationProvider: @escaping @Sendable () -> String? = { nil },
         transport: @escaping Transport, now: @escaping @Sendable () -> Date) {
        self.cookieProvider = cookieProvider; self.metadataProvider = metadataProvider
        self.selectedOrganizationProvider = selectedOrganizationProvider; self.transport = transport; self.now = now
        session = nil
    }

    public func currentAccountScope() -> String? { verifiedScope }
    public func currentSource() -> ClaudeQuotaSource? { source }
    public func nextRetryAt() -> Date? { throttle?.retryAt }
    public func organizations() -> [ClaudeWebOrganization] { identity?.organizations ?? [] }

    public func readQuota() async throws -> QuotaSnapshot {
        if let task { return try await task.value }
        let owned = Task { try await fetchQuota() }; task = owned
        defer { task = nil }
        return try await withTaskCancellationHandler(operation: { try await owned.value }, onCancel: { owned.cancel() })
    }

    public func shutdown() {
        task?.cancel(); task = nil; identity = nil; verifiedScope = nil; source = nil
        verifiedSessionHash = nil; verifiedBinding = nil; throttle = nil
        session?.invalidateAndCancel()
    }

    private func fetchQuota() async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        guard let cookies = await cookieProvider(), ClaudeWebQuotaDecoder.sessionKey(cookies) != nil else {
            clearIdentity(); throw ClaudeQuotaError.notLoggedIn
        }
        let binding = metadataProvider()
        try validateBinding(binding)
        if identity?.sessionHash != cookies.sessionHash { clearIdentity() }
        let initialSelection = selectedOrganizationProvider() ?? cookies.organizationID ?? binding.organizationID
        let selectedScope = identity.flatMap { value in ClaudeWebQuotaDecoder.uuid(initialSelection).map {
            ClaudeQuotaDecoder.digest("claude|" + value.account + "|" + $0)
        } }
        if selectedScope != verifiedScope { verifiedScope = nil; source = nil }
        if let pending = throttle, pending.retryAt > now(), pending.sessionHash == cookies.sessionHash, pending.binding == binding {
            throw ClaudeQuotaError.unavailable
        }
        throttle = nil
        do {
            if identity == nil {
                let account = try ClaudeWebQuotaDecoder.accountID(try await request(path: "/api/account", cookies: cookies, binding: binding))
                if let known = binding.accountID, ClaudeWebQuotaDecoder.uuid(known) != account { throw ClaudeQuotaError.accountChanged }
                let organizations = try ClaudeWebQuotaDecoder.organizations(try await request(path: "/api/organizations", cookies: cookies, binding: binding))
                identity = Identity(sessionHash: cookies.sessionHash, account: account, organizations: organizations)
            }
            guard let current = identity else { throw ClaudeQuotaError.invalidReply }
            if let known = binding.accountID, ClaudeWebQuotaDecoder.uuid(known) != current.account { throw ClaudeQuotaError.accountChanged }
            let selection = selectedOrganizationProvider() ?? cookies.organizationID ?? binding.organizationID
            guard let org = ClaudeWebQuotaDecoder.uuid(selection) else { throw ClaudeQuotaError.organizationSelectionRequired }
            guard current.organizations.contains(where: { $0.id == org }),
                  binding.organizationID == nil || ClaudeWebQuotaDecoder.uuid(binding.organizationID) == org else { throw ClaudeQuotaError.accountChanged }
            let expectedScope = ClaudeQuotaDecoder.digest("claude|" + current.account + "|" + org)
            if verifiedScope != expectedScope { verifiedScope = nil; source = nil }
            let path = "/api/organizations/" + org + "/usage"
            let usage = try await request(path: path + "?cedar_ember=1", fallbackPath: path, cookies: cookies, binding: binding)
            let after = await cookieProvider()
            guard !Task.isCancelled else { throw CancellationError() }
            guard let after, ClaudeWebQuotaDecoder.sessionKey(after) != nil,
                  after.sessionHash == cookies.sessionHash,
                  metadataProvider() == binding,
                  (selectedOrganizationProvider() ?? after.organizationID ?? binding.organizationID).flatMap({ ClaudeWebQuotaDecoder.uuid($0) }) == org else {
                throw ClaudeQuotaError.accountChanged
            }
            let value = try ClaudeQuotaDecoder.decodeUsage(usage, capturedAt: now(), accountScope: expectedScope)
            verifiedScope = expectedScope; verifiedSessionHash = cookies.sessionHash; verifiedBinding = binding; source = .webSession
            return value
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure: Error
            if let network = error as? URLError {
                if network.code == .cancelled { throw CancellationError() }
                failure = network.code == .timedOut ? ClaudeQuotaError.timedOut : ClaudeQuotaError.connectionFailed
            } else { failure = (error as? ClaudeQuotaError) ?? ClaudeQuotaError.connectionFailed }
            let kind = failure as? ClaudeQuotaError
            if kind == .notLoggedIn || kind == .accountChanged || kind == .denied { clearIdentity() }
            else {
                let currentCookies = await cookieProvider()
                let currentChoice = selectedOrganizationProvider() ?? currentCookies?.organizationID ?? metadataProvider().organizationID
                let scope = identity.flatMap { value in ClaudeWebQuotaDecoder.uuid(currentChoice).map { ClaudeQuotaDecoder.digest("claude|" + value.account + "|" + $0) } }
                if kind == .organizationSelectionRequired || currentCookies?.sessionHash != cookies.sessionHash ||
                    currentCookies.map({ ClaudeWebQuotaDecoder.sessionKey($0) == nil }) != false ||
                    verifiedSessionHash != cookies.sessionHash || verifiedBinding != metadataProvider() || scope != verifiedScope {
                    verifiedScope = nil; source = nil
                }
            }
            throw failure
        }
    }

    private func request(path: String, fallbackPath: String? = nil, cookies: ClaudeWebSession,
                         binding: ClaudeWebAccountBinding) async throws -> Data {
        guard path.hasPrefix("/api/"), path.utf8.count <= 256,
              let url = URL(string: "https://claude.ai" + path), url.scheme == "https", url.host == "claude.ai" else { throw ClaudeQuotaError.invalidReply }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let agent = cookies.userAgent, !agent.isEmpty, agent.count <= 512,
           !agent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard response.url?.scheme == "https", response.url?.host == "claude.ai",
              response.url?.port == nil || response.url?.port == 443,
              data.count <= 2 * 1024 * 1024 else { throw ClaudeQuotaError.invalidReply }
        if ClaudeWebQuotaDecoder.isChallenge(data, response: response) { throw ClaudeQuotaError.webChallenge }
        switch response.statusCode {
        case 200: return data
        case 401: throw ClaudeQuotaError.notLoggedIn
        case 429:
            if let retry = ClaudeQuotaClient.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now()) {
                throttle = Throttle(sessionHash: cookies.sessionHash, binding: binding, retryAt: retry)
            }
            throw ClaudeQuotaError.unavailable
        case 400, 403:
            if let fallbackPath { return try await self.request(path: fallbackPath, cookies: cookies, binding: binding) }
            throw response.statusCode == 403 ? ClaudeQuotaError.denied : ClaudeQuotaError.invalidReply
        default: throw ClaudeQuotaError.connectionFailed
        }
    }

    private func validateBinding(_ binding: ClaudeWebAccountBinding) throws {
        guard !binding.conflictingAccounts,
              binding.accountID == nil || ClaudeWebQuotaDecoder.uuid(binding.accountID) != nil,
              binding.organizationID == nil || ClaudeWebQuotaDecoder.uuid(binding.organizationID) != nil else {
            clearIdentity(); throw ClaudeQuotaError.accountChanged
        }
    }

    private func clearIdentity() {
        identity = nil; verifiedScope = nil; verifiedSessionHash = nil; verifiedBinding = nil; source = nil; throttle = nil
    }

    public nonisolated static func observedBinding(userHome: URL, home: URL) -> ClaudeWebAccountBinding {
        let cli = ClaudeCredentialStore.identity(userHome: userHome, home: home)
        var desktopAccount: String?
        if home.standardizedFileURL == userHome.appendingPathComponent(".claude").standardizedFileURL,
           let data = ClaudeCredentialStore.boundedData(at: userHome.appendingPathComponent("Library/Application Support/Claude/config.json")),
           let config = try? ClaudeQuotaDecoder.dictionary(data) {
            desktopAccount = ClaudeWebQuotaDecoder.uuid(config["lastKnownAccountUuid"] as? String)
        }
        let cliAccount = cli.flatMap { ClaudeWebQuotaDecoder.uuid($0.accountID) }
        return ClaudeWebAccountBinding(accountID: cliAccount ?? desktopAccount, organizationID: cli?.organizationID,
            conflictingAccounts: (cli != nil && cliAccount == nil) || (cliAccount != nil && desktopAccount != nil && cliAccount != desktopAccount))
    }
}

private final class ClaudeWebQuotaRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
