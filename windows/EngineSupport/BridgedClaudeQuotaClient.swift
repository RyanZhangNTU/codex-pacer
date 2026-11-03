import Foundation

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
            client = ClaudeWebQuotaClient(cookieProvider: { await provider.read() }, home: home, userHome: userHome,
                selectedOrganizationProvider: { organization.isEmpty ? nil : organization }, metadataProvider: metadata)
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
        }, history: QuotaHistoryStore(directory: directory, files: WindowsFileSystem()))
    }
}
