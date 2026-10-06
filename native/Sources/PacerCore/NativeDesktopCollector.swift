import Foundation
import Darwin

/// One owned Unix socket on a utility queue. The local path uses no Python
/// process and delivers only sanitized events and pending-request identifiers.
final class NativeDesktopCollector: @unchecked Sendable {
    let id: UUID
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    private let home: URL
    private let hosts: Set<String>
    private let localRuntime: Bool
    private let onFrame: @Sendable (Data) -> Void
    private let onClosed: @Sendable () -> Void
    init(id: UUID = UUID(), home: URL, hosts: Set<String>, localRuntime: Bool = true, onFrame: @escaping @Sendable (Data) -> Void,
         onClosed: @escaping @Sendable () -> Void) {
        self.id = id; self.home = home; self.hosts = hosts; self.localRuntime = localRuntime; self.onFrame = onFrame; self.onClosed = onClosed
    }
    func start() throws {
        let path = home.appendingPathComponent("ipc/ipc.sock")
        for (url, type) in [(path.deletingLastPathComponent(), FileAttributeType.typeDirectory), (path, .typeSocket)] {
            let fields = try FileManager.default.attributesOfItem(atPath: url.path)
            guard fields[.type] as? FileAttributeType == type,
                  (fields[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let mode = fields[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw POSIXError(.EACCES) }
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { let error = errno; Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        lock.lock(); descriptor = fd; let stopped = cancelled; lock.unlock()
        if stopped { finish(fd); return }
        DispatchQueue.global(qos: .utility).async { [self] in run(fd) }
    }
    func stop() {
        lock.lock(); cancelled = true
        if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func finish(_ fd: Int32) {
        lock.lock()
        if descriptor == fd { descriptor = -1; Darwin.close(fd) }
        lock.unlock()
    }
    private func read(_ count: Int, fd: Int32) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            let size = data.withUnsafeMutableBytes { raw in Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0) }
            if size > 0 { offset += size }
            else if size < 0 && errno == EINTR { continue }
            else { throw POSIXError(.EPIPE) }
        }
        return data
    }
    private func send(_ value: [String: Any], fd: Int32) throws {
        let body = try JSONSerialization.data(withJSONObject: value)
        var length = UInt32(body.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(body)
        var offset = 0
        while offset < data.count {
            let size = data.withUnsafeBytes { raw in Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if size > 0 { offset += size }
            else if size < 0 && errno == EINTR { continue }
            else { throw POSIXError(.EPIPE) }
        }
    }
    private func receive(_ fd: Int32) throws -> Data {
        let header = try read(4, fd: fd)
        let count = Int(UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24)
        guard count > 0, count <= 16 * 1024 * 1024 else { throw JSONFieldView.Failure.limit }
        return try read(count, fd: fd)
    }
    private func run(_ fd: Int32) {
        defer { finish(fd); onClosed() }
        do {
            var session = try NativeDesktopSession(hosts: hosts, localRuntime: localRuntime) { [self] value in try send(value, fd: fd) }
            defer {
                // EOF can arrive during the 250ms batch interval. Deliver the
                // last valid events before signalling closure to the consumer.
                try? session.publishEvents()
                for frame in session.takeFrames() { onFrame(frame) }
                session.close()
            }
            let queue = kqueue()
            guard queue >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(queue) }
            let directory = Darwin.open(home.path, O_EVTONLY | O_CLOEXEC)
            defer { if directory >= 0 { Darwin.close(directory) } }
            var registrations = [kevent64_s(ident: UInt64(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: 0, ext: (0, 0))]
            if directory >= 0 {
                registrations.append(kevent64_s(ident: UInt64(directory), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                    fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_DELETE), data: 0, udata: 0, ext: (0, 0)))
            }
            guard Darwin.kevent64(queue, &registrations, Int32(registrations.count), nil, 0, 0, nil) == 0 else { throw POSIXError(.EIO) }
            var routingFile: Int32 = -1
            defer { if routingFile >= 0 { Darwin.close(routingFile) } }
            func reopenRoutingWatch() throws {
                if routingFile >= 0 { Darwin.close(routingFile) }
                routingFile = Darwin.open(home.appendingPathComponent(".codex-global-state.json").path, O_EVTONLY | O_CLOEXEC)
                if routingFile >= 0 {
                    var change = kevent64_s(ident: UInt64(routingFile), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                        fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_DELETE), data: 0, udata: 0, ext: (0, 0))
                    guard Darwin.kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else { throw POSIXError(.EIO) }
                }
            }
            try reopenRoutingWatch()
            var routing = DesktopRouteHints(), routingDirty = true, reopenRouting = false, nextRoutingRead = Date.distantPast
            let opened = Date(); var nextStatus = Date.distantPast, nextFlush = Date.distantPast, iterations = 0
            while !stopped {
                iterations += 1
                let now = Date()
                try session.service(at: now)
                if routingDirty && now >= nextRoutingRead {
                    if reopenRouting { try reopenRoutingWatch(); reopenRouting = false }
                    try session.discover(routing.changed(home: home, hosts: hosts))
                    routingDirty = false; nextRoutingRead = now.addingTimeInterval(0.25)
                }
                if !session.ready && now.timeIntervalSince(opened) > 5 { throw POSIXError(.ETIMEDOUT) }
                if session.hasEvents && now >= nextFlush { try session.publishEvents(); nextFlush = now.addingTimeInterval(0.25) }
                if now >= nextStatus { try session.status(loopIterations: iterations); nextStatus = now.addingTimeInterval(15) }
                for frame in session.takeFrames() { onFrame(frame) }
                var delay = min(15, max(0.01, nextStatus.timeIntervalSinceNow))
                if session.hasEvents { delay = min(delay, max(0.01, nextFlush.timeIntervalSinceNow)) }
                if !session.ready { delay = min(delay, max(0.01, 5 - Date().timeIntervalSince(opened))) }
                if routingDirty { delay = min(delay, max(0.01, nextRoutingRead.timeIntervalSinceNow)) }
                if let service = session.nextServiceDate { delay = min(delay, max(0.01, service.timeIntervalSinceNow)) }
                var timeout = timespec(tv_sec: Int(delay), tv_nsec: Int((delay - floor(delay)) * 1_000_000_000))
                var changed = [kevent64_s](repeating: kevent64_s(), count: 3)
                let result = Darwin.kevent64(queue, nil, 0, &changed, Int32(changed.count), 0, &timeout)
                if result < 0 && errno == EINTR { continue }
                guard result >= 0 else { throw POSIXError(.EIO) }
                let filesystem = changed.prefix(Int(result)).filter { $0.filter == Int16(EVFILT_VNODE) }
                if !filesystem.isEmpty {
                    // The directory catches atomic replacement; the file itself
                    // catches in-place writes, which do not alter its directory.
                    if !routingDirty { nextRoutingRead = max(nextRoutingRead, Date().addingTimeInterval(0.025)) }
                    routingDirty = true
                    if filesystem.contains(where: { (directory >= 0 && $0.ident == UInt64(directory)) || $0.fflags & UInt32(NOTE_RENAME | NOTE_DELETE) != 0 }) { reopenRouting = true }
                }
                if changed.prefix(Int(result)).contains(where: { $0.filter == Int16(EVFILT_READ) }) {
                    try session.receive(receive(fd))
                    // Pending questions and approvals are delivered immediately,
                    // independently of the 250ms token/activity batch.
                    for frame in session.takeFrames() { onFrame(frame) }
                }
            }
        } catch { /* Only availability is reported; wire content is never logged. */ }
    }
}
