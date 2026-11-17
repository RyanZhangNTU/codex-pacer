import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PacerCore

private actor ClaudeCookieProvider {
    let bridge: ClaudeWebBridge, context: String
    private(set) var failure: ClaudeQuotaError?
    init(bridge: ClaudeWebBridge, context: String) { self.bridge = bridge; self.context = context }
    func read() async -> ClaudeWebSession? {
        failure = nil
        do { return try await bridge.read(context: context) }
        catch { failure = (error as? ClaudeQuotaError) ?? .connectionFailed; return nil }
    }
    func stop() async { await bridge.cancel(context: context) }
}

actor BridgedClaudeQuotaClient: ClaudeQuotaConnection {
    private let cookies: ClaudeCookieProvider
    private let client: ClaudeWebQuotaClient
    init(bridge: ClaudeWebBridge, home: URL, organization: String, context: String,
         userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         metadataProvider: ClaudeWebQuotaClient.MetadataProvider? = nil,
         transport: ClaudeWebQuotaClient.Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let provider = ClaudeCookieProvider(bridge: bridge, context: context); cookies = provider
        #if os(Windows)
        let metadata: ClaudeWebQuotaClient.MetadataProvider = metadataProvider ?? { WindowsClaudeAccountBinding.observe(userHome: userHome, home: home) }
        #else
        let metadata: ClaudeWebQuotaClient.MetadataProvider = metadataProvider ?? { ClaudeWebQuotaClient.observedBinding(userHome: userHome, home: home) }
        #endif
        if let transport {
            client = ClaudeWebQuotaClient(cookieProvider: { await provider.read() }, metadataProvider: metadata,
                selectedOrganizationProvider: { organization.isEmpty ? nil : organization }, transport: transport, now: now)
        } else {
            #if os(Windows)
            let direct = WindowsClaudeHTTP.client(timeout: ProviderQuotaRefreshPolicy.replyTimeout)
            client = ClaudeWebQuotaClient(cookieProvider: { await provider.read() }, metadataProvider: metadata,
                selectedOrganizationProvider: { organization.isEmpty ? nil : organization },
                transport: Self.browserTransport(bridge: bridge, context: context) { try await direct.data(for: $0) },
                now: now, invalidateTransport: { direct.invalidate() })
            #else
            client = ClaudeWebQuotaClient(cookieProvider: { await provider.read() }, home: home, userHome: userHome,
                selectedOrganizationProvider: { organization.isEmpty ? nil : organization }, metadataProvider: metadata)
            #endif
        }
    }
    /// Reads go through Pacer's own browser profile when the host offers it: the
    /// browser that passed claude.ai's verification is the one Cloudflare cleared,
    /// and the engine's HTTPS client was challenged again after every sign-in (#243).
    /// The browser sends its own cookies; the request's are not forwarded.
    static func browserTransport(bridge: ClaudeWebBridge, context: String,
                                 direct: @escaping ClaudeWebQuotaClient.Transport) -> ClaudeWebQuotaClient.Transport {
        { request in
            guard await bridge.fetchesInBrowser else { return try await direct(request) }
            guard let url = request.url, (request.httpMethod ?? "GET") == "GET", url.scheme == "https", url.host == "claude.ai",
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClaudeQuotaError.invalidReply }
            let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
            return try await bridge.fetch(context: context, path: path).response(for: url)
        }
    }
    func readQuota() async throws -> QuotaSnapshot {
        do { return try await client.readQuota() }
        catch {
            try Task.checkCancellation()
            if let failure = await cookies.failure { throw failure }
            throw (error as? ClaudeQuotaError) ?? .connectionFailed
        }
    }
    func currentAccountScope() async -> String? { await client.currentAccountScope() }
    func organizations() async -> [ClaudeWebOrganization] { await client.organizations() }
    func currentSource() async -> ClaudeQuotaSource? { await client.currentSource() }
    func nextRetryAt() async -> Date? { await client.nextRetryAt() }
    func shutdown() async { await client.shutdown(); await cookies.stop() }
}

extension ClaudeQuotaServices {
    static func live(bridge: ClaudeWebBridge) -> Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/ClaudeCurrentCycle", isDirectory: true)
        return .init(makeClient: { home, organization, context in
            BridgedClaudeQuotaClient(bridge: bridge, home: home, organization: organization, context: context)
        }, history: QuotaHistoryStore(directory: directory, files: WindowsRecoveringHistoryFiles(kind: .quota)))
    }
}
