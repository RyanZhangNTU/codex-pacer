#if os(Windows)
import Foundation
import PacerCore
import FoundationNetworking

/// Delivers a Claude message stream's bounded lines to the original cloud
/// stream parser. FoundationNetworking has no URLSession.AsyncBytes on Windows,
/// and its open responses busy-loop a thread. Each stream is read through
/// WinHTTP on a thread that waits for data, directly, through an HTTP proxy, or
/// through the loopback relay for SOCKS and authenticated proxies. Only HTTPS
/// proxies and forms WinHTTP cannot express keep URLSession.
enum WindowsClaudeCloudStream {
    struct Options: Sendable {
        /// The longest wait for the connection or for the next bytes, like
        /// URLSession's request timeout. An idle stream still sends keepalives.
        var idleTimeout: TimeInterval = 60
        /// Like URLSession's resource timeout; polling reopens the stream.
        var lifetime: TimeInterval = 24 * 3600
        var proxy: @Sendable (String) -> Result<WindowsHTTPProxy.Route, WindowsHTTPStream.Failure> = { WindowsHTTPProxy.forHTTPS(host: $0) }
        var compatibilityConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
        /// Where an allowed request connects. Tests use a loopback fixture.
        var target: @Sendable (URL) -> WindowsHTTPStream.Target? = { WindowsHTTPStream.httpsTarget($0) }
    }

    static func lines(_ options: Options = .init()) -> ClaudeCloudReplyStreams.Lines {
        { request in
            AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
                guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
                guard allowed(request), let url = request.url, let target = options.target(url) else {
                    continuation.finish(throwing: ClaudeCloudFailure.invalidReply); return
                }
                guard case .success(let route) = options.proxy(target.host) else {
                    continuation.finish(throwing: ClaudeCloudFailure.connection); return
                }
                guard let fields = WindowsHTTPStream.fields(of: request) else { continuation.finish(throwing: ClaudeCloudFailure.invalidReply); return }
                if case .urlSession = route {
                    let read = WindowsURLSessionCloudStream()
                    continuation.onTermination = { _ in read.cancel() }
                    read.start(request, options: options, continuation: continuation)
                    return
                }
                let proxy: String?, relay: WindowsProxyRelay?
                switch route {
                case .winHTTP(let value): proxy = value; relay = nil
                case .relay(let upstream):
                    // Never a direct connection: without a relay the stream fails.
                    guard let value = WindowsProxyRelay(upstream, target: target, timeout: options.idleTimeout) else {
                        continuation.finish(throwing: ClaudeCloudFailure.connection); return
                    }
                    proxy = value.address; relay = value
                case .urlSession: continuation.finish(throwing: ClaudeCloudFailure.connection); return
                }
                guard let transport = WindowsHTTPStream() else {
                    relay?.close(); continuation.finish(throwing: ClaudeCloudFailure.connection); return
                }
                continuation.onTermination = { _ in transport.cancel() }
                let thread = Thread {
                    read(url, target: target, headers: fields.headers, agent: fields.agent, proxy: proxy, options: options,
                         transport: transport, continuation: continuation)
                    relay?.close()
                }
                thread.name = "Claude cloud stream"
                thread.start()
            }
        }
    }

    static func allowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == "claude.ai",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.fragment == nil, request.httpMethod == "GET",
              url.absoluteString.utf8.count <= 2048,
              url.path.hasPrefix("/v1/code/channels/"), url.path.hasSuffix("/messages/stream") else { return false }
        return true
    }

    private static func read(_ url: URL, target: WindowsHTTPStream.Target, headers: [(name: String, value: String)],
                             agent: String, proxy: String?, options: Options, transport: WindowsHTTPStream,
                             continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        defer { transport.close() }
        func fail(_ failure: WindowsHTTPStream.Failure) {
            continuation.finish(throwing: failure == .cancelled ? CancellationError() : ClaudeCloudFailure.connection)
        }
        let ends = Date().addingTimeInterval(options.lifetime)
        let status: Int
        switch transport.open(target, headers: headers, agent: agent, proxy: proxy, timeout: options.idleTimeout) {
        case .success(let value): status = value
        case .failure(let failure): fail(failure); return
        }
        // Redirects are never followed, even to the same origin.
        guard !(300..<400).contains(status) else { continuation.finish(throwing: ClaudeCloudFailure.invalidReply); return }
        var fields: [String: String] = [:]
        for name in ["Content-Type", "Retry-After"] { fields[name] = transport.header(name) }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else {
            continuation.finish(throwing: ClaudeCloudFailure.invalidReply); return
        }
        if let failure = ClaudeCloudFailure(streamResponse: response, at: Date()) { continuation.finish(throwing: failure); return }
        var buffer = ClaudeCloudLineBuffer()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = ends.timeIntervalSinceNow
            guard remaining > 0 else { continuation.finish(throwing: ClaudeCloudFailure.connection); return }
            switch transport.read(into: &bytes, timeout: min(options.idleTimeout, remaining)) {
            case .failure(let failure): fail(failure); return
            case .success(0): continuation.finish(); return
            case .success(let count):
                do {
                    for byte in bytes[..<count] {
                        guard let line = try buffer.append(byte) else { continue }
                        switch continuation.yield(line) {
                        case .enqueued: break
                        // A slow consumer must not retain unbounded reply text or
                        // silently lose a line. Polling still owns task lifecycle.
                        case .dropped: continuation.finish(throwing: ClaudeCloudFailure.connection); return
                        case .terminated: return
                        @unknown default: continuation.finish(throwing: ClaudeCloudFailure.connection); return
                        }
                    }
                } catch { continuation.finish(throwing: ClaudeCloudFailure.invalidReply); return }
            }
        }
    }
}
#endif
