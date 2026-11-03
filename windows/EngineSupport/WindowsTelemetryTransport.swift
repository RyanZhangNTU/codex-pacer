import Foundation
import PacerCore
import CWindowsSupport

struct WindowsTelemetryTransport: TelemetryTransport {
    private final class Accept: @unchecked Sendable {
        let accepted: @Sendable (any TelemetryConnection) -> Void
        init(_ accepted: @escaping @Sendable (any TelemetryConnection) -> Void) { self.accepted = accepted }
    }
    private final class Listener: TelemetryListener, @unchecked Sendable {
        let port: UInt16
        private let lock = NSLock()
        private var handle: UnsafeMutableRawPointer?
        init(_ handle: UnsafeMutableRawPointer, port: UInt16) { self.handle = handle; self.port = port }
        func stop() {
            lock.lock(); let handle = self.handle; self.handle = nil; lock.unlock()
            if let handle { pacer_telemetry_stop(handle) }
        }
        deinit { stop() }
    }
    func listen(port: UInt16, backlog: Int,
                accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws -> any TelemetryListener {
        let context = Unmanaged.passRetained(Accept(accepted))
        var actualPort: UInt16 = 0
        let handle = pacer_telemetry_listen(port, Int32(backlog), &actualPort, context.toOpaque(), { pointer, client in
            guard let client else { return }
            guard let pointer else { pacer_telemetry_close(client); return }
            Unmanaged<Accept>.fromOpaque(pointer).takeUnretainedValue().accepted(WindowsTelemetryConnection(client))
        }, { pointer in if let pointer { Unmanaged<Accept>.fromOpaque(pointer).release() } })
        guard let handle else { context.release(); throw TelemetryTransportFailure.unavailable }
        return Listener(handle, port: actualPort)
    }
}

private final class WindowsTelemetryConnection: TelemetryConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    init(_ handle: UnsafeMutableRawPointer) { self.handle = handle }
    func read(maximumBytes: Int, timeout: TimeInterval) throws -> Data {
        lock.lock(); let handle = self.handle; lock.unlock()
        guard let handle else { throw TelemetryTransportFailure.closed }
        var bytes = [UInt8](repeating: 0, count: min(4096, max(1, maximumBytes)))
        let milliseconds = UInt32(max(1, min(5, max(0, timeout)) * 1000))
        let count = bytes.withUnsafeMutableBufferPointer { pacer_telemetry_read(handle, $0.baseAddress, $0.count, milliseconds) }
        guard count >= 0 else { throw count == -2 ? TelemetryTransportFailure.timeout : .closed }
        return Data(bytes.prefix(Int(count)))
    }
    func write(_ data: Data) throws {
        lock.lock(); let handle = self.handle; lock.unlock()
        guard let handle else { throw TelemetryTransportFailure.closed }
        let written = data.withUnsafeBytes { pacer_telemetry_write(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        if written == 0 { throw TelemetryTransportFailure.closed }
    }
    func interrupt() { lock.lock(); defer { lock.unlock() }; if let handle { pacer_telemetry_interrupt(handle) } }
    func close() {
        lock.lock(); defer { lock.unlock() }
        if let handle { pacer_telemetry_close(handle); self.handle = nil }
    }
    deinit { close() }
}

extension ClaudeActivityTelemetry {
    convenience init(port: UInt16 = 4319, onFrame: @escaping @Sendable (Data) -> Void) {
        self.init(port: port, transport: WindowsTelemetryTransport(), onFrame: onFrame)
    }
}
