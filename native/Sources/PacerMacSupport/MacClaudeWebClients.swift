import Foundation
import PacerCore

extension ClaudeWebQuotaClient {
    public init(cookieProvider: @escaping CookieProvider, home: URL? = nil,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                selectedOrganizationProvider: @escaping @Sendable () -> String? = { nil },
                metadataProvider: MetadataProvider? = nil, timeout: TimeInterval = ProviderQuotaRefreshPolicy.replyTimeout) {
        let home = home ?? userHome.appendingPathComponent(".claude")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = min(30, max(1, timeout))
        configuration.timeoutIntervalForResource = min(35, max(2, timeout + 3))
        let session = URLSession(configuration: configuration, delegate: ClaudeWebQuotaRedirectDelegate(), delegateQueue: nil)
        self.init(cookieProvider: cookieProvider,
            metadataProvider: metadataProvider ?? { Self.observedBinding(userHome: userHome, home: home) },
            selectedOrganizationProvider: selectedOrganizationProvider,
            transport: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ClaudeQuotaError.invalidReply }
                return (data, response)
            }, now: { Date() }, invalidateTransport: { session.invalidateAndCancel() })
    }
    public nonisolated static func observedBinding(userHome: URL, home: URL) -> ClaudeWebAccountBinding {
        observedBinding(userHome: userHome, home: home,
            desktopConfiguration: userHome.appendingPathComponent("Library/Application Support/Claude/config.json"),
            files: MacFileSystem())
    }
}

extension ClaudeCloudProjectMonitor {
    public init(cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider,
                selectedOrganization: @escaping @Sendable () -> String? = { nil },
                localSessions: @escaping LocalSessions = { ClaudeApplicationResolver.desktopCloudSessionIDs() },
                timeout: TimeInterval = 12) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = min(30, max(1, timeout))
        configuration.timeoutIntervalForResource = min(35, max(2, timeout + 3))
        let session = URLSession(configuration: configuration, delegate: ClaudeCloudRedirectDelegate(), delegateQueue: nil)
        let streaming = URLSessionConfiguration.ephemeral
        streaming.httpCookieStorage = nil; streaming.urlCache = nil; streaming.httpShouldSetCookies = false
        streaming.timeoutIntervalForRequest = 60; streaming.timeoutIntervalForResource = 24 * 3600
        let streamSession = URLSession(configuration: streaming, delegate: ClaudeCloudRedirectDelegate(), delegateQueue: nil)
        self.init(cookieProvider: cookieProvider, selectedOrganization: selectedOrganization, localSessions: localSessions,
            transport: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ClaudeCloudFailure.invalidReply }
                return (data, response)
            }, streamLines: ClaudeCloudReplyStreams.lines(session: streamSession), now: { Date() },
            invalidateTransport: { session.invalidateAndCancel(); streamSession.invalidateAndCancel() })
    }
}

private final class ClaudeWebQuotaRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class ClaudeCloudRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
