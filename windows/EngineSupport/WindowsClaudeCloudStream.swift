#if os(Windows)
import Foundation
import FoundationNetworking

/// FoundationNetworking has no URLSession.AsyncBytes on Windows. This adapter
/// delivers the same bounded lines to the original cloud stream parser.
final class WindowsClaudeCloudStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    // URLSession serializes delegate callbacks. Cancellation never touches this buffer.
    private var buffer = ClaudeCloudLineBuffer()
    private var accepted = false
    private var ended = false

    static func lines(configuration: URLSessionConfiguration) -> ClaudeCloudReplyStreams.Lines {
        { request in
            AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
                let exchange = WindowsClaudeCloudStream()
                continuation.onTermination = { _ in exchange.cancel() }
                exchange.start(request, configuration: configuration, continuation: continuation)
            }
        }
    }

    private static func allowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == "claude.ai",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.fragment == nil, request.httpMethod == "GET",
              url.absoluteString.utf8.count <= 2048,
              url.path.hasPrefix("/v1/code/channels/"), url.path.hasSuffix("/messages/stream") else { return false }
        return true
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
        guard Self.allowed(request) else { continuation.finish(throwing: ClaudeCloudFailure.invalidReply); return }
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = request; request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        lock.lock()
        guard !ended else {
            lock.unlock(); task.cancel(); session.invalidateAndCancel(); continuation.finish(throwing: CancellationError()); return
        }
        self.continuation = continuation; self.session = session; self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() { finish(CancellationError()) }

    private func finish(_ error: Error? = nil) {
        lock.lock()
        let continuation = self.continuation, session = self.session, task = self.task
        ended = true
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == "claude.ai" else {
            completionHandler(.cancel); finish(ClaudeCloudFailure.invalidReply); return
        }
        if let failure = ClaudeCloudFailure(streamResponse: response, at: Date()) {
            completionHandler(.cancel); finish(failure); return
        }
        accepted = true; completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        guard accepted, let continuation else { return }
        do {
            for byte in data {
                guard let line = try buffer.append(byte) else { continue }
                switch continuation.yield(line) {
                case .enqueued: break
                // A slow consumer must not retain unbounded reply text or
                // silently lose a line. Polling still owns task lifecycle.
                case .dropped: finish(ClaudeCloudFailure.connection); return
                case .terminated: cancel(); return
                @unknown default: finish(ClaudeCloudFailure.connection); return
                }
            }
        } catch { finish(ClaudeCloudFailure.invalidReply) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish((error as? URLError)?.code == .cancelled ? CancellationError() : ClaudeCloudFailure.connection)
        } else { finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(ClaudeCloudFailure.invalidReply)
    }
}
#endif
