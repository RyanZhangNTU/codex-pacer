import Foundation
import PacerCore

/// Concurrent stream connections share one outstanding browser read. Completed
/// replies are not cached: each later binding check reads the owned profile again.
actor ClaudeCloudCookieProvider {
    private let bridge: ClaudeWebBridge, input: ClaudeCloudServices.Input
    private var pending: (UUID, Task<ClaudeWebSession?, Never>)?
    private var pinned = false, invalidated = false, stopped = false
    private var scope: String?
    init(bridge: ClaudeWebBridge, input: ClaudeCloudServices.Input) { self.bridge = bridge; self.input = input }
    func read() async -> ClaudeWebSession? {
        guard !stopped, !invalidated, !Task.isCancelled else { return nil }
        let id: UUID, task: Task<ClaudeWebSession?, Never>
        if let value = pending { (id, task) = value }
        else {
            id = UUID(); task = Task { [weak self] in await self?.readOnce() }
            pending = (id, task)
        }
        let value = await task.value
        if pending?.0 == id { pending = nil }
        return !stopped && !invalidated && !Task.isCancelled ? value : nil
    }
    private func readOnce() async -> ClaudeWebSession? {
        let value: ClaudeWebSession?
        do { value = try await bridge.read(context: input.context) }
        catch { return nil }
        guard !stopped, !invalidated, !Task.isCancelled else { return nil }
        let organization = ClaudeWebQuotaDecoder.uuid(input.organization.isEmpty ? value?.organizationID : input.organization)
        let observed = value.map { ClaudeQuotaDecoder.digest($0.sessionHash + "|" + (organization ?? "")) }
        if pinned, observed != scope {
            invalidated = true
            Task { await input.changedScope() }
            return nil
        }
        if !pinned {
            pinned = true; scope = observed
            guard await input.observedScope(observed), !stopped, !invalidated, !Task.isCancelled else { return nil }
        }
        return value
    }
    func stop() async {
        stopped = true; pending?.1.cancel(); pending = nil
        await bridge.cancel(context: input.context)
    }
}

actor BridgedClaudeCloudClient: ClaudeCloudConnection {
    private let cookies: ClaudeCloudCookieProvider
    private let monitor: ClaudeCloudProjectMonitor
    private var stopped = false
    init(bridge: ClaudeWebBridge, input: ClaudeCloudServices.Input,
         transport: ClaudeCloudProjectMonitor.Transport? = nil, streamLines: ClaudeCloudReplyStreams.Lines? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        let cookies = ClaudeCloudCookieProvider(bridge: bridge, input: input); self.cookies = cookies
        if let transport {
            monitor = ClaudeCloudProjectMonitor(cookieProvider: { await cookies.read() },
                selectedOrganization: { input.organization.isEmpty ? nil : input.organization }, localSessions: input.localSessions,
                transport: transport, streamLines: streamLines, now: now)
        } else {
            monitor = ClaudeCloudProjectMonitor(cookieProvider: { await cookies.read() },
                selectedOrganization: { input.organization.isEmpty ? nil : input.organization }, localSessions: input.localSessions)
        }
    }
    func start(expanded: Bool, update: @escaping ClaudeCloudProjectMonitor.Update) async {
        guard !stopped else { return }; await monitor.start(expanded: expanded, update: update)
    }
    func setExpanded(_ value: Bool) async { guard !stopped else { return }; await monitor.setExpanded(value) }
    func refresh() async { guard !stopped else { return }; await monitor.refresh() }
    func shutdown() async {
        stopped = true; await cookies.stop(); await monitor.shutdown()
    }
}

extension ClaudeCloudServices {
    static func live(bridge: ClaudeWebBridge) -> Self {
        .init(makeClient: { input in BridgedClaudeCloudClient(bridge: bridge, input: input) })
    }
}
