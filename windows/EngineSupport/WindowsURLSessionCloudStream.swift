#if os(Windows)
import Foundation
import FoundationNetworking
import PacerCore

/// The URLSession stream path for SOCKS, HTTPS and authenticated proxies.
/// It keeps the same line, buffering, redirect and cancellation policy.
final class WindowsURLSessionCloudStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var session: URLSession?, task: URLSessionDataTask?
    // URLSession serializes delegate callbacks; cancellation leaves the buffer alone.
    private var buffer = ClaudeCloudLineBuffer()
    private var accepted = false, ended = false

    func start(_ request: URLRequest, options: WindowsClaudeCloudStream.Options,
               continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        let configuration = WindowsHTTPProxy.configuration(idleTimeout: options.idleTimeout, totalTimeout: options.lifetime,
                                                           base: options.compatibilityConfiguration())
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = request; request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        lock.lock()
        guard !ended else {
            lock.unlock(); task.cancel(); session.invalidateAndCancel(); continuation.finish(throwing: CancellationError()); return
        }
        self.continuation = continuation; self.session = session; self.task = task
        lock.unlock(); task.resume()
    }

    func cancel() { finish(CancellationError()) }

    private func finish(_ error: Error? = nil) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        let continuation = continuation, session = session, task = task
        ended = true
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(ClaudeCloudFailure.invalidReply); return
        }
        guard !(300..<400).contains(response.statusCode) else {
            completionHandler(.cancel); finish(ClaudeCloudFailure.invalidReply); return
        }
        if let failure = ClaudeCloudFailure(streamResponse: response, at: Date()) {
            completionHandler(.cancel); finish(failure); return
        }
        accepted = true; completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let continuation = continuation; lock.unlock()
        guard accepted, let continuation else { return }
        do {
            for byte in data {
                guard let line = try buffer.append(byte) else { continue }
                switch continuation.yield(line) {
                case .enqueued: break
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
