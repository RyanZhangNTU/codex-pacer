#if os(Windows)
import Foundation
import CWindowsSupport

/// A loopback HTTP proxy for one request target, tunnelling through a SOCKS
/// proxy or an HTTP proxy with credentials, neither of which WinHTTP can use
/// itself. It only accepts that target, and its threads block on sockets, so
/// an open stream through it uses no CPU. Close it when the request ends.
final class WindowsProxyRelay: @unchecked Sendable {
    /// The `host:port` WinHTTP uses as its proxy.
    let address: String
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?

    init?(_ upstream: WindowsHTTPProxy.Upstream, target: WindowsHTTPStream.Target, timeout: TimeInterval) {
        var port: UInt16 = 0
        let milliseconds = UInt32(min(max(timeout, 0.001), 86_400) * 1000)
        guard let handle = pacer_proxy_relay_start(upstream.kind.rawValue, upstream.host, upstream.port,
                                                    upstream.username ?? "", upstream.password ?? "", upstream.username == nil ? 0 : 1,
                                                    target.host, target.port, milliseconds, &port), port > 0 else { return nil }
        self.handle = handle
        address = "127.0.0.1:\(port)"
    }
    deinit { close() }

    func close() {
        let handle = lock.withLock { () -> UnsafeMutableRawPointer? in defer { self.handle = nil }; return self.handle }
        if let handle { pacer_proxy_relay_close(handle) }
    }
}
#endif
