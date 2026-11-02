import Foundation
import PacerCore

extension RemoteControlCatalog {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public static func fetch(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexClientError.invalidResponse }
        guard response.statusCode == 200 else { throw CatalogError.status(response.statusCode) }
        guard response.expectedContentLength <= 512 * 1024 else { throw CodexClientError.invalidResponse }
        var data = Data()
        for try await byte in stream {
            guard data.count < 512 * 1024 else { throw CodexClientError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
