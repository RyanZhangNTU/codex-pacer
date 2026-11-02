#if os(Windows)
import Foundation
import FoundationNetworking

private final class WindowsClaudeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum WindowsClaudeHTTP {
    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(30, max(1, timeout))
        configuration.timeoutIntervalForResource = min(35, max(2, timeout + 3))
        return configuration
    }
    static func session(timeout: TimeInterval) -> URLSession {
        URLSession(configuration: configuration(timeout: timeout), delegate: WindowsClaudeRedirectDelegate(), delegateQueue: nil)
    }
}

extension ClaudeWebQuotaClient {
    public init(cookieProvider: @escaping CookieProvider, home: URL? = nil,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        selectedOrganizationProvider: @escaping @Sendable () -> String? = { nil },
        metadataProvider: MetadataProvider? = nil, timeout: TimeInterval = 12) {
        let home = home ?? userHome.appendingPathComponent(".claude")
        let session = WindowsClaudeHTTP.session(timeout: timeout)
        self.init(cookieProvider: cookieProvider,
            metadataProvider: metadataProvider ?? { WindowsClaudeAccountBinding.observe(userHome: userHome, home: home) },
            selectedOrganizationProvider: selectedOrganizationProvider,
            transport: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ClaudeQuotaError.invalidReply }
                return (data, response)
            }, now: { Date() }, invalidateTransport: { session.invalidateAndCancel() })
    }
}

extension ClaudeCloudProjectMonitor {
    public init(cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider,
        selectedOrganization: @escaping @Sendable () -> String? = { nil },
        localSessions: @escaping LocalSessions = { [] }, timeout: TimeInterval = 12) {
        let session = WindowsClaudeHTTP.session(timeout: timeout)
        let streaming = WindowsClaudeHTTP.configuration(timeout: timeout)
        streaming.timeoutIntervalForRequest = 60; streaming.timeoutIntervalForResource = 24 * 3600
        self.init(cookieProvider: cookieProvider, selectedOrganization: selectedOrganization, localSessions: localSessions,
            transport: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ClaudeCloudFailure.invalidReply }
                return (data, response)
            }, streamLines: WindowsClaudeCloudStream.lines(configuration: streaming), now: { Date() },
            invalidateTransport: { session.invalidateAndCancel() })
    }
}
#endif
