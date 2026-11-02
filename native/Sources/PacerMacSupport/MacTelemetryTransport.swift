import Darwin
import Foundation
import PacerCore

public struct MacTelemetryTransport: TelemetryTransport {
    public init() {}
    public func listen(port: UInt16, backlog: Int,
                       accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws -> any TelemetryListener {
        try MacTelemetryListener(port: port, backlog: backlog, accepted: accepted)
    }
}

private func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
private func closeOnExec(_ fd: Int32) throws {
    let flags = Darwin.fcntl(fd, F_GETFD)
    guard flags >= 0, Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw socketError() }
}

private final class MacTelemetryListener: TelemetryListener, @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let queue = DispatchQueue(label: "pacer.claude.telemetry", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private let closed = DispatchSemaphore(value: 0)
    private var source: DispatchSourceRead?
    private let accepted: @Sendable (any TelemetryConnection) -> Void
    init(port: UInt16, backlog: Int, accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        var owned = true
        defer { if owned { Darwin.close(fd) } }
        try closeOnExec(fd)
        var reuse: Int32 = 1
        guard Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else { throw socketError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, Darwin.listen(fd, Int32(backlog)) == 0 else { throw socketError() }
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw socketError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }) == 0 else { throw socketError() }
        self.fd = fd; self.port = UInt16(bigEndian: address.sin_port); self.accepted = accepted
        queue.setSpecific(key: queueKey, value: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue), closed = self.closed
        self.source = source
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { Darwin.close(fd); closed.signal() }
        owned = false; source.resume()
    }
    private func acceptConnections() {
        // Yield the serial queue under a connection flood so cancellation wins.
        for _ in 0..<32 {
            lock.lock(); let active = source != nil; lock.unlock()
            guard active else { return }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            do { try MacTelemetryConnection.configure(client); accepted(MacTelemetryConnection(client)) }
            catch { Darwin.close(client) }
        }
    }
    func stop() {
        lock.lock(); let source = self.source; self.source = nil; lock.unlock()
        guard let source else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR); source.cancel()
        // Bound descriptor-release observation inside the overall 650 ms budget.
        if DispatchQueue.getSpecific(key: queueKey) == nil { _ = closed.wait(timeout: .now() + 0.05) }
    }
    deinit { stop() }
}

private final class MacTelemetryConnection: TelemetryConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    static func configure(_ fd: Int32) throws {
        try closeOnExec(fd)
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw socketError() }
        var noSignal: Int32 = 1, timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
              Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else { throw socketError() }
    }
    func read(maximumBytes: Int, timeout: TimeInterval) throws -> Data {
        lock.lock(); let fd = self.fd; lock.unlock()
        guard fd >= 0 else { throw TelemetryTransportFailure.closed }
        let microseconds = max(1, Int(min(5, max(0, timeout)) * 1_000_000))
        var timeout = timeval(tv_sec: microseconds / 1_000_000, tv_usec: Int32(microseconds % 1_000_000))
        guard Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else { throw socketError() }
        var bytes = [UInt8](repeating: 0, count: min(4096, max(1, maximumBytes)))
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw TelemetryTransportFailure.timeout }
            throw socketError()
        }
    }
    func write(_ data: Data) throws {
        lock.lock(); let fd = self.fd; lock.unlock()
        guard fd >= 0 else { throw TelemetryTransportFailure.closed }
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while offset < data.count, ProcessInfo.processInfo.systemUptime < deadline {
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { throw socketError() }
        }
        if offset < data.count { throw TelemetryTransportFailure.timeout }
    }
    func interrupt() { lock.lock(); defer { lock.unlock() }; if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) } }
    func close() { lock.lock(); let fd = self.fd; self.fd = -1; lock.unlock(); if fd >= 0 { Darwin.close(fd) } }
    deinit { close() }
}

extension ClaudeActivityTelemetry {
    public convenience init(port: UInt16 = 4319, onFrame: @escaping @Sendable (Data) -> Void) {
        self.init(port: port, transport: MacTelemetryTransport(), onFrame: onFrame)
    }
}
