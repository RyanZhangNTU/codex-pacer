#if os(Windows)
import Foundation
import FoundationNetworking
import PacerCore

/// Claude OAuth usage for WSL profiles, read through WinHTTP (see
/// `WindowsHTTPClient`). Only the response is returned; no cookies,
/// credentials or responses are kept, and redirects are not followed.
enum WindowsClaudeUsageHTTP {
    static let maximumBytes = 2 * 1024 * 1024
    static let usage = WindowsHTTPClient(.init(idleTimeout: ProviderQuotaRefreshPolicy.replyTimeout,
        totalTimeout: ProviderQuotaRefreshPolicy.replyTimeout + 3, maximumBytes: maximumBytes))

    static func claudeQuota(_ request: URLRequest, client: WindowsHTTPClient = usage) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", url.host == "api.anthropic.com",
              url.path == "/api/oauth/usage", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { throw ClaudeQuotaError.invalidReply }
        do { return try await client.data(for: request) }
        catch let error as URLError where error.code == .dataLengthExceedsMaximum { throw ClaudeQuotaError.invalidReply }
    }
}
#endif
