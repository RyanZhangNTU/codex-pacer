#if os(Windows)
import Foundation
import FoundationNetworking

/// Bounded reads for proxy configurations that WinHTTP cannot represent.
/// URLSession retains libcurl's proxy routing; no direct retry is made.
final class WindowsURLSessionRead: NSObject, WindowsHTTPRead, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let options: WindowsHTTPClient.Options
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?, task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var bytes = Data(), finished = false

    init(_ options: WindowsHTTPClient.Options) { self.options = options }

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let configuration = WindowsHTTPProxy.configuration(idleTimeout: options.idleTimeout, totalTimeout: options.totalTimeout,
                                                                       base: options.compatibilityConfiguration())
                    lock.lock()
                    guard !finished else { lock.unlock(); continuation.resume(throwing: URLError(.cancelled)); return }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    var request = request; request.httpShouldHandleCookies = false
                    let task = session.dataTask(with: request)
                    self.session = session; self.task = task
                    lock.unlock(); task.resume()
                }
            } onCancel: { self.cancel() }
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    func cancel() { finish(.failure(URLError(.cancelled))) }

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
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(URLError(.badServerResponse))); return
        }
        guard options.readsBody(response.statusCode) else {
            completionHandler(.cancel); finish(.success((Data(), response))); return
        }
        guard response.expectedContentLength <= Int64(options.maximumBytes) else {
            completionHandler(.cancel); finish(.failure(URLError(.dataLengthExceedsMaximum))); return
        }
        lock.lock(); let allow = !finished; if allow { self.response = response }; lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= options.maximumBytes - bytes.count else {
            lock.unlock(); finish(.failure(URLError(.dataLengthExceedsMaximum))); return
        }
        bytes.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let bytes = bytes, response = response; lock.unlock()
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((bytes, response))) }
        else { finish(.failure(URLError(.badServerResponse))) }
    }
}
#endif
