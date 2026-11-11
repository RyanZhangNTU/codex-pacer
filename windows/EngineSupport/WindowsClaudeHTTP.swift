#if os(Windows)
import Foundation
import PacerCore
import FoundationNetworking

/// Claude web reads use WinHTTP: URLSession keeps a thread busy for each
/// request in progress on Windows, and cloud polling makes many of them.
enum WindowsClaudeHTTP {
    /// Far above any project, session or usage reply; it only bounds memory.
    static let maximumBytes = 32 * 1024 * 1024
    static func client(timeout: TimeInterval) -> WindowsHTTPClient {
        WindowsHTTPClient(.init(idleTimeout: min(30, max(1, timeout)), totalTimeout: min(35, max(2, timeout + 3)),
                                maximumBytes: maximumBytes))
    }
}

extension ClaudeWebQuotaClient {
    public init(cookieProvider: @escaping CookieProvider, home: URL? = nil,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        selectedOrganizationProvider: @escaping @Sendable () -> String? = { nil },
        metadataProvider: MetadataProvider? = nil, timeout: TimeInterval = ProviderQuotaRefreshPolicy.replyTimeout) {
        let home = home ?? userHome.appendingPathComponent(".claude")
        let client = WindowsClaudeHTTP.client(timeout: timeout)
        self.init(cookieProvider: cookieProvider,
            metadataProvider: metadataProvider ?? { WindowsClaudeAccountBinding.observe(userHome: userHome, home: home) },
            selectedOrganizationProvider: selectedOrganizationProvider,
            transport: { request in try await client.data(for: request) }, now: { Date() }, invalidateTransport: { client.invalidate() })
    }
}

extension ClaudeCloudProjectMonitor {
    public init(cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider,
        selectedOrganization: @escaping @Sendable () -> String? = { nil },
        localSessions: @escaping LocalSessions = { [] }, timeout: TimeInterval = 12) {
        let client = WindowsClaudeHTTP.client(timeout: timeout)
        self.init(cookieProvider: cookieProvider, selectedOrganization: selectedOrganization, localSessions: localSessions,
            transport: { request in try await client.data(for: request) }, streamLines: WindowsClaudeCloudStream.lines(), now: { Date() },
            invalidateTransport: { client.invalidate() })
    }
}
#endif
