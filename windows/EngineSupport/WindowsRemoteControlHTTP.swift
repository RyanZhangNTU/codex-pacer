#if os(Windows)
import Foundation
import FoundationNetworking
import PacerCore

/// Remote Control catalogs and Claude OAuth usage, read through WinHTTP (see
/// `WindowsHTTPClient`). Only the response body is returned; no cookies,
/// credentials or responses are kept, and redirects are not followed.
enum WindowsRemoteControlHTTP {
    static let maximumBytes = 512 * 1024
    static let catalog = WindowsHTTPClient(.init(idleTimeout: 8, totalTimeout: 10, maximumBytes: maximumBytes, readsBody: { $0 == 200 }))
    static let usage = WindowsHTTPClient(.init(idleTimeout: 8, totalTimeout: 10, maximumBytes: 2 * 1024 * 1024))

    static func fetch(_ request: URLRequest, client: WindowsHTTPClient = catalog) async throws -> Data {
        guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", let host = url.host,
              host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { throw CodexClientError.invalidResponse }
        let (data, response) = try await read(request, client)
        guard response.statusCode == 200 else { throw RemoteControlCatalog.CatalogError.status(response.statusCode) }
        return data
    }
    static func claudeQuota(_ request: URLRequest, client: WindowsHTTPClient = usage) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", url.host == "api.anthropic.com",
              url.path == "/api/oauth/usage", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { throw ClaudeQuotaError.invalidReply }
        return try await read(request, client)
    }
    private static func read(_ request: URLRequest, _ client: WindowsHTTPClient) async throws -> (Data, HTTPURLResponse) {
        do { return try await client.data(for: request) }
        catch let error as URLError where error.code == .dataLengthExceedsMaximum { throw CodexClientError.invalidResponse }
    }
}
#endif
