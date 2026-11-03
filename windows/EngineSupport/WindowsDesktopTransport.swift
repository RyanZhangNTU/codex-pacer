#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

/// An authenticated local transport, independent of Desktop's wire protocol.
/// Holding this object for each I/O keeps its handle alive until cancellation
/// completes. Reads and writes are each serialized; one of each may run together.
final class WindowsDesktopTransport: @unchecked Sendable {
    enum Failure: Error, Equatable { case unavailable, identityMismatch, invalidEndpoint, closed, timedOut, cancelled, invalidFrame }
    private let handle: UnsafeMutableRawPointer
    private let reader = NSLock(), writer = NSLock()
    init(endpoint: String, peerRoot: URL, packageFamily: String? = nil, timeout: UInt32 = 1000) throws {
        guard peerRoot.isFileURL else { throw Failure.invalidEndpoint }
        let root = WindowsCodexExecutableDiscovery.path(peerRoot.standardizedFileURL)
        guard timeout > 0 && timeout <= 5000, endpoint.utf8.count <= 100, !endpoint.isEmpty,
              endpoint.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              root.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil,
              root.utf16.count < 32768, !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              packageFamily == nil || (!packageFamily!.isEmpty && packageFamily!.utf16.count < 255 && !packageFamily!.utf16.contains(0)) else { throw Failure.invalidEndpoint }
        let name = Array(endpoint.utf16) + [0], folder = Array(root.utf16) + [0]
        var reason: Int32 = 0
        let connected: UnsafeMutableRawPointer?
        if let packageFamily {
            connected = pacer_pipe_open(name, folder, Array(packageFamily.utf16) + [0], timeout, &reason)
        } else { connected = pacer_pipe_open(name, folder, nil, timeout, &reason) }
        guard let connected else { throw reason == 2 ? Failure.identityMismatch : Failure.unavailable }
        handle = connected
    }
    deinit { pacer_pipe_close(handle) }
    func cancel() { withExtendedLifetime(self) { pacer_pipe_cancel(handle) } }
    var peerIdentity: WindowsProcessIdentity? {
        var identity = pacer_process_identity()
        guard withExtendedLifetime(self, { pacer_pipe_peer_identity(handle, &identity) }) != 0 else { return nil }
        return .init(pid: identity.pid, started: identity.started)
    }
    static func connectCodex(packageLocations: () -> [URL] = WindowsCodexExecutableDiscovery.packageLocations) throws -> WindowsDesktopTransport {
        var identityMismatch = false
        for root in packageLocations().prefix(12) {
            do { return try WindowsDesktopTransport(endpoint: "codex-ipc", peerRoot: root.appendingPathComponent("app"), packageFamily: "OpenAI.Codex_2p2nqsd0c76g0") }
            catch Failure.identityMismatch { identityMismatch = true }
        }
        throw identityMismatch ? Failure.identityMismatch : Failure.unavailable
    }
    func readExactly(_ count: Int, deadline: Date? = nil) throws -> Data {
        reader.lock(); defer { reader.unlock() }
        return try read(count, until: deadline.map { expiry($0.timeIntervalSinceNow) })
    }
    private func read(_ count: Int, until: UInt64?, waitForInitialData: Bool = true) throws -> Data {
        guard count > 0 && count <= 1024 * 1024 else { throw Failure.invalidFrame }
        var data = Data(count: count), offset = 0
        while offset < count {
            let timeout = try until.map(milliseconds) ?? (offset == 0 && waitForInitialData ? UInt32.max : 2000)
            let read = withExtendedLifetime(self) {
                data.withUnsafeMutableBytes { bytes in
                    pacer_pipe_read(handle, bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count - offset, timeout)
                }
            }
            guard read > 0 else { throw failure(read) }
            offset += Int(read)
        }
        return data
    }
    func write(_ data: Data, deadline: Date = Date().addingTimeInterval(2)) throws {
        writer.lock(); defer { writer.unlock() }
        guard !data.isEmpty, data.count <= 1024 * 1024 else { throw Failure.invalidFrame }
        var offset = 0
        let limit = expiry(deadline.timeIntervalSinceNow)
        while offset < data.count {
            let timeout = try milliseconds(limit)
            let sent = withExtendedLifetime(self) {
                data.withUnsafeBytes { bytes in
                    pacer_pipe_write(handle, bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), data.count - offset, timeout)
                }
            }
            guard sent > 0 else { throw failure(sent) }
            offset += Int(sent)
        }
    }
    func send(_ value: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: value)
        guard body.count <= 1024 * 1024 - 4 else { throw Failure.invalidFrame }
        let length = UInt32(body.count)
        var data = Data([UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 24)])
        data.append(body); try write(data)
    }
    func receive(observedTurnIDs: Set<String> = []) throws -> DesktopFrameDecoder.Frame {
        reader.lock(); defer { reader.unlock() }
        let header = try read(4, until: nil)
        let count = Int(UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24)
        // Like NativeDesktopCollector, limit retained metadata, not the wire
        // history size. The shared decoder reads at most 64 KiB at a time.
        guard count > 0 else { throw Failure.invalidFrame }
        var decoder = DesktopFrameDecoder(byteCount: count, observedTurnIDs: observedTurnIDs) { [self] amount in
            try read(amount, until: nil, waitForInitialData: false)
        }
        return try decoder.decode()
    }
    // Convert the caller's deadline once. A wall-clock adjustment must not
    // extend an explicit in-flight read/write budget. Ordinary frame reads
    // use NativeDesktopCollector's two-second timeout per underlying read.
    private func expiry(_ seconds: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(30, seconds.isFinite ? seconds : 0)) * 1_000_000_000)
    }
    private func milliseconds(_ end: UInt64) throws -> UInt32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard end > now else { throw Failure.timedOut }
        return UInt32(min(5000, max(1, ceil(Double(end - now) / 1_000_000))))
    }
    private func failure(_ result: Int64) -> Failure { result == -3 ? .cancelled : result == -2 ? .timedOut : .closed }
}
#endif
