import Foundation
import PacerCore

extension ClaudeQuotaClient {
    public nonisolated static func credentialCacheDiagnostics(action: String) -> [String: Bool] {
        ClaudeKeychainCacheQA.perform(action)
    }
    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                home: URL? = nil, statusLineURL: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = ProviderQuotaRefreshPolicy.replyTimeout, allowKeychainInteraction: Bool = false) {
        let claudeHome = home ?? environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? userHome.appendingPathComponent(".claude")
        let environmentHome = environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? userHome.appendingPathComponent(".claude")
        var selectedEnvironment = environment
        if claudeHome.standardizedFileURL != environmentHome.standardizedFileURL {
            selectedEnvironment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        }
        let credentialEnvironment = selectedEnvironment
        let usesEnvironmentToken = !(credentialEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty
        let usesDefaultHome = claudeHome.standardizedFileURL == userHome.appendingPathComponent(".claude").standardizedFileURL
        let desktopEligible = usesDefaultHome && !usesEnvironmentToken && ClaudeDesktopCredentialStore.configuration(userHome: userHome) != nil
        let cliReader = ClaudeCLICredentialReader(userHome: userHome, home: claudeHome, environment: credentialEnvironment,
            allowInteraction: allowKeychainInteraction && !desktopEligible)
        let desktopReader = usesDefaultHome && !usesEnvironmentToken
            ? ClaudeDesktopCredentialReader(userHome: userHome, allowInteraction: allowKeychainInteraction) : nil
        let desktopCredentialProvider: (@Sendable () throws -> ClaudeOAuthCredential?)?
        if let desktopReader { desktopCredentialProvider = { try desktopReader.read() } }
        else { desktopCredentialProvider = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(60, max(1, timeout))
        configuration.timeoutIntervalForResource = min(65, max(2, timeout + 3))
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeQuotaSessionDelegate(), delegateQueue: nil)
        self.init(statusLineURL: statusLineURL ?? claudeHome.appendingPathComponent("pacer/claude-statusline.json"), files: MacFileSystem(),
            credentialProvider: { try cliReader.read() },
            desktopCredentialProvider: desktopCredentialProvider,
            identityProvider: {
                usesEnvironmentToken ? nil : ClaudeCredentialStore.identity(userHome: userHome, home: claudeHome)
                    .map { ($0.scope, $0.organizationID) }
            }, transport: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ClaudeQuotaError.invalidReply }
                return (data, response)
            }, now: { Date() }, persistVerifiedCredentials: allowKeychainInteraction,
            rememberCredential: { index, credential in
                if index == 1 { return desktopReader?.rememberVerified(credential) ?? false }
                return ClaudeCredentialStore.rememberVerified(credential, userHome: userHome, home: claudeHome)
            }, invalidateCredential: { index in
                if index == 1 { desktopReader?.invalidate() } else { cliReader.invalidate() }
            }, finishConnectionAttempt: { desktopReader?.finishConnectionAttempt(); cliReader.finishConnectionAttempt() },
            discardCredentialMemory: { desktopReader?.shutdown(); cliReader.shutdown() },
            invalidateTransport: { session.invalidateAndCancel() })
    }
}

private final class ClaudeQuotaSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
