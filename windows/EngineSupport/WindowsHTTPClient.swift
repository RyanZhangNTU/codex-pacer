#if os(Windows)
import Foundation
import FoundationNetworking

/// Bounded GET requests through WinHTTP. SOCKS and authenticated proxies go
/// through `WindowsProxyRelay`; only HTTPS proxies and forms WinHTTP cannot
/// express keep URLSession and its CPU cost.
///
/// A URLSession request keeps one thread busy until it finishes (see
/// `WindowsHTTPStream`). Claude's cloud polling makes up to 16 requests every
/// 30 seconds, so those requests alone kept a core busy for seconds at a time.
/// Redirects are returned rather than followed, and nothing stores cookies,
/// credentials or responses.
final class WindowsHTTPClient: @unchecked Sendable {
    struct Options: Sendable {
        /// The longest wait for the connection or for the next bytes.
        var idleTimeout: TimeInterval
        var totalTimeout: TimeInterval
        var maximumBytes: Int
        /// Statuses whose body is read; other responses return with no body.
        var readsBody: @Sendable (Int) -> Bool = { _ in true }
        var proxy: @Sendable (String) -> Result<WindowsHTTPProxy.Route, WindowsHTTPStream.Failure> = { WindowsHTTPProxy.forHTTPS(host: $0) }
        var compatibilityConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
        /// Where a request connects. Tests use a loopback fixture.
        var target: @Sendable (URL) -> WindowsHTTPStream.Target? = { WindowsHTTPStream.httpsTarget($0) }
    }

    let options: Options
    private let lock = NSLock()
    private var active: [ObjectIdentifier: any WindowsHTTPRead] = [:]
    private var invalidated = false

    init(_ options: Options) { self.options = options }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, let target = options.target(url) else { throw URLError(.unsupportedURL) }
        guard case .success(let route) = options.proxy(target.host) else { throw URLError(.cannotConnectToHost) }
        guard let fields = WindowsHTTPStream.fields(of: request) else { throw URLError(.badURL) }
        if case .urlSession = route {
            let read = WindowsURLSessionRead(options)
            let key = try register(read)
            defer { _ = lock.withLock { active.removeValue(forKey: key) } }
            return try await read.run(request)
        }
        let proxy: String?, relay: WindowsProxyRelay?
        switch route {
        case .winHTTP(let value): proxy = value; relay = nil
        case .relay(let upstream):
            // Never a direct connection: without a relay the request fails.
            guard let value = WindowsProxyRelay(upstream, target: target, timeout: options.idleTimeout) else { throw URLError(.cannotConnectToHost) }
            proxy = value.address; relay = value
        case .urlSession: throw URLError(.cannotConnectToHost)
        }
        defer { relay?.close() }
        guard let transport = WindowsHTTPStream() else { throw URLError(.cannotConnectToHost) }
        let key = try register(transport)
        defer { lock.withLock { active[key] = nil } }
        let options = options
        let result: Result<(Data, HTTPURLResponse), Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    continuation.resume(returning: Self.run(url, target: target, fields: fields, proxy: proxy, options: options, transport: transport))
                }
                thread.name = "WinHTTP request"
                thread.start()
            }
        } onCancel: { transport.cancel() }
        if case .failure(let error as URLError) = result, error.code == .cancelled, Task.isCancelled { throw CancellationError() }
        return try result.get()
    }

    /// Cancels requests in progress; later requests fail as cancelled.
    func invalidate() {
        let transports = lock.withLock { invalidated = true; return Array(active.values) }
        transports.forEach { $0.cancel() }
    }

    private func register(_ read: any WindowsHTTPRead) throws -> ObjectIdentifier {
        try lock.withLock {
            guard !invalidated else { throw URLError(.cancelled) }
            let key = ObjectIdentifier(read)
            active[key] = read
            return key
        }
    }

    private static func run(_ url: URL, target: WindowsHTTPStream.Target, fields: (agent: String, headers: [(name: String, value: String)]),
                            proxy: String?, options: Options, transport: WindowsHTTPStream) -> Result<(Data, HTTPURLResponse), Error> {
        defer { transport.close() }
        func error(_ failure: WindowsHTTPStream.Failure, connecting: Bool) -> Error {
            switch failure {
            case .cancelled: return URLError(.cancelled)
            case .timedOut: return URLError(.timedOut)
            case .failed: return URLError(connecting ? .cannotConnectToHost : .networkConnectionLost)
            }
        }
        let ends = Date().addingTimeInterval(options.totalTimeout)
        let status: Int
        switch transport.open(target, headers: fields.headers, agent: fields.agent, proxy: proxy,
                              timeout: min(options.idleTimeout, options.totalTimeout)) {
        case .success(let value): status = value
        case .failure(let failure): return .failure(error(failure, connecting: true))
        }
        let headers = transport.headers() ?? [:]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return .failure(URLError(.badServerResponse))
        }
        guard options.readsBody(status) else { return .success((Data(), response)) }
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }),
           length > Int64(options.maximumBytes) { return .failure(URLError(.dataLengthExceedsMaximum)) }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = ends.timeIntervalSinceNow
            guard remaining > 0 else { return .failure(URLError(.timedOut)) }
            switch transport.read(into: &bytes, timeout: min(options.idleTimeout, remaining)) {
            case .failure(let failure): return .failure(error(failure, connecting: false))
            case .success(0): return .success((data, response))
            case .success(let count):
                guard count <= options.maximumBytes - data.count else { return .failure(URLError(.dataLengthExceedsMaximum)) }
                data.append(contentsOf: bytes[..<count])
            }
        }
    }
}
#endif
