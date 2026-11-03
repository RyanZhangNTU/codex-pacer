import Foundation

/// Host callbacks provide reads, never the order in which sources are tried.
public struct ClaudeQuotaReadServices: Sendable {
    public let passive: @Sendable () async -> QuotaSnapshot?
    public let webAvailable: @Sendable () async -> Bool
    public let makeWeb: @Sendable () async -> any ClaudeQuotaConnection
    public let compatibility: any ClaudeQuotaConnection
    public init(passive: @escaping @Sendable () async -> QuotaSnapshot?,
                webAvailable: @escaping @Sendable () async -> Bool,
                makeWeb: @escaping @Sendable () async -> any ClaudeQuotaConnection,
                compatibility: any ClaudeQuotaConnection) {
        self.passive = passive; self.webAvailable = webAvailable
        self.makeWeb = makeWeb; self.compatibility = compatibility
    }
}

/// A passive status-line reading wins over web credentials and compatibility
/// sources. Every suspension checks ownership before trying the next source.
public actor PrioritizedClaudeQuotaConnection: ClaudeQuotaConnection {
    private let services: ClaudeQuotaReadServices
    private let generation = QuotaWorkGeneration()
    private var web: (any ClaudeQuotaConnection)?
    private var selected: (any ClaudeQuotaConnection)?
    private var source: ClaudeQuotaSource?
    private var passiveScope: String?
    public init(services: ClaudeQuotaReadServices) { self.services = services }
    public func readQuota() async throws -> QuotaSnapshot {
        let revision = generation.capture()
        func check() throws {
            try Task.checkCancellation()
            guard generation.contains(revision) else { throw CancellationError() }
        }
        let passive = await services.passive()
        try check()
        if let passive {
            source = .statusLine; passiveScope = passive.accountScope; selected = nil
            return passive
        }
        let available = await services.webAvailable()
        try check()
        let connection: any ClaudeQuotaConnection
        if available {
            if let web { connection = web }
            else {
                let created = await services.makeWeb()
                do { try check() }
                catch { await ShutdownDeadline().perform([{ await created.shutdown() }]); throw error }
                web = created; connection = created
            }
        } else { connection = services.compatibility }
        selected = connection; passiveScope = nil
        let reading = try await connection.readQuota()
        try check()
        let readSource = await connection.currentSource()
        try check(); source = readSource
        return reading
    }
    public func currentAccountScope() async -> String? {
        if let selected { return await selected.currentAccountScope() }
        return passiveScope
    }
    public func currentSource() async -> ClaudeQuotaSource? {
        if let selected { return await selected.currentSource() }
        return source
    }
    public func organizations() async -> [ClaudeWebOrganization] { await selected?.organizations() ?? [] }
    // The passive source remains readable while the selected network client is
    // throttled. That client's own read enforces Retry-After without HTTP.
    public func nextRetryAt() async -> Date? { nil }
    public nonisolated func invalidateSource() { generation.invalidate() }
    public func shutdown() async {
        invalidateSource()
        let legacy = services.compatibility, web = web
        self.web = nil; selected = nil; passiveScope = nil; source = nil
        await ShutdownDeadline().perform([{ await legacy.shutdown() }, { await web?.shutdown() }])
    }
}
