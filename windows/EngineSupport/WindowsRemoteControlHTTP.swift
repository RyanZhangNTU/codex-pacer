#if os(Windows)
import Foundation
import FoundationNetworking
import PacerCore

enum WindowsRemoteControlHTTP {
    static let maximumBytes = 512 * 1024
    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration? = nil) async throws -> Data {
        guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", let host = url.host,
              host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { throw CodexClientError.invalidResponse }
        return try await Read(configuration: configuration).run(request).0
    }
    static func claudeQuota(_ request: URLRequest, configuration: URLSessionConfiguration? = nil) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET", let url = request.url, url.scheme == "https", url.host == "api.anthropic.com",
              url.path == "/api/oauth/usage", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { throw ClaudeQuotaError.invalidReply }
        return try await Read(configuration: configuration, maximumBytes: 2 * 1024 * 1024, acceptsStatuses: true).run(request)
    }
    private final class Read: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let configuration: URLSessionConfiguration
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var response: HTTPURLResponse?
        private let maximumBytes: Int, acceptsStatuses: Bool
        private var session: URLSession?, task: URLSessionDataTask?
        private var bytes = Data(), accepted = false, finished = false
        init(configuration: URLSessionConfiguration?, maximumBytes: Int = WindowsRemoteControlHTTP.maximumBytes, acceptsStatuses: Bool = false) {
            let config = configuration ?? .ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
            self.configuration = config
            self.maximumBytes = maximumBytes; self.acceptsStatuses = acceptsStatuses
        }
        func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    let task = session.dataTask(with: request); self.session = session; self.task = task
                    lock.unlock(); task.resume()
                }
            } onCancel: { self.finish(.failure(CancellationError())) }
        }
        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation, session = session, task = task
            self.continuation = nil; self.session = nil; self.task = nil; bytes = Data()
            lock.unlock()
            task?.cancel(); session?.invalidateAndCancel(); continuation?.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(CodexClientError.invalidResponse)); return }
            guard response.statusCode == 200 || acceptsStatuses else { completionHandler(.cancel); finish(.failure(RemoteControlCatalog.CatalogError.status(response.statusCode))); return }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                completionHandler(.cancel); finish(.failure(CodexClientError.invalidResponse)); return
            }
            lock.lock(); self.response = response; accepted = !finished; let allow = accepted; lock.unlock()
            completionHandler(allow ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard data.count <= maximumBytes - bytes.count else {
                lock.unlock(); finish(.failure(CodexClientError.invalidResponse)); return
            }
            bytes.append(data); lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let result = bytes, accepted = accepted, response = response; lock.unlock()
            if let error { finish(.failure(error)) }
            else if accepted, let response { finish(.success((result, response))) }
            else { finish(.failure(CodexClientError.invalidResponse)) }
        }
    }
}
#endif
