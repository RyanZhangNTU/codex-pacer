import Foundation
import Darwin

/// Reads effective SSH routing only. It never connects, authenticates, writes
/// SSH configuration or retains any other configuration fields.
public enum ClaudeSSHRouteResolver {
    static let maximumOutputBytes = 64 * 1024

    public static func resolve(host: String, port: Int? = nil,
                        executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                        timeout: TimeInterval = 3) async -> ClaudeSSHRoute? {
        guard validDestination(host), port.map({ (1...65535).contains($0) }) ?? true,
              timeout.isFinite, timeout > 0, !Task.isCancelled else { return nil }
        var arguments = ["-G", "-o", "CanonicalizeHostname=no", "-o", "PermitLocalCommand=no",
                         "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"]
        if let port { arguments += ["-p", String(port)] }
        arguments += ["--", host]
        let operation = Operation(executable: executable, arguments: arguments, timeout: min(3, timeout))
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { operation.start($0) }
        }, onCancel: { operation.cancel() })
    }

    static func parse(_ data: Data) -> ClaudeSSHRoute? {
        ClaudeSSHRouteRules.parse(data, normalizeIPv6: normalizedIPv6)
    }
    static func validDestination(_ value: String) -> Bool {
        ClaudeSSHRouteRules.validDestination(value, normalizeIPv6: normalizedIPv6)
    }
    private static func normalizedIPv6(_ value: String) -> String? {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        var result = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let capacity = socklen_t(result.count)
        let converted = result.withUnsafeMutableBufferPointer { destination in
            withUnsafePointer(to: &address) { inet_ntop(AF_INET6, $0, destination.baseAddress!, capacity) != nil }
        }
        guard converted else { return nil }
        return String(decoding: result.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private final class Operation: @unchecked Sendable {
        private let queue = DispatchQueue(label: "pacer.claude.ssh-route", qos: .utility)
        private let process = Process()
        private let output = Pipe()
        private let timeout: TimeInterval
        private var continuation: CheckedContinuation<ClaudeSSHRoute?, Never>?
        private var source: DispatchSourceRead?
        private var deadline: DispatchWorkItem?
        private var bytes = Data()
        private var status: Int32?
        private var outputEnded = false
        private var finished = false
        private var ownership: OwnedProcessTermination?

        init(executable: URL, arguments: [String], timeout: TimeInterval) {
            self.timeout = timeout
            process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
        }

        func start(_ continuation: CheckedContinuation<ClaudeSSHRoute?, Never>) {
            queue.async { [self] in
                guard !finished else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let handle = output.fileHandleForReading, descriptor = handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                let descriptorFlags = fcntl(descriptor, F_GETFD)
                guard flags >= 0, descriptorFlags >= 0,
                      fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                      fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { finish(nil); return }
                let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                reader.setEventHandler { [weak self] in self?.readAvailable(descriptor) }
                reader.setCancelHandler { try? handle.close() }
                source = reader
                process.terminationHandler = { [weak self] child in
                    guard let self else { return }
                    let exitStatus = child.terminationStatus
                    self.queue.async { [self] in
                        guard !self.finished else { return }
                        self.status = exitStatus
                        self.completeIfReady()
                    }
                }
                do { try process.run() }
                catch { reader.resume(); finish(nil); return }
                let child = process
                ownership = OwnedProcessTermination { [weak child] in
                    if let child, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                }
                // Only the child owns the writing end after spawn; parent EOF
                // must not depend on this Pipe object's lifetime.
                try? output.fileHandleForWriting.close()
                reader.resume()
                let timer = DispatchWorkItem { [weak self] in self?.finish(nil) }
                deadline = timer; queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        }

        func cancel() { queue.async { [self] in finish(nil) } }

        private func readAvailable(_ descriptor: Int32) {
            guard !finished else { return }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let capacity = chunk.count
            while !finished {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, capacity) }
                if count > 0 {
                    guard bytes.count + count <= ClaudeSSHRouteResolver.maximumOutputBytes else { finish(nil); return }
                    bytes.append(contentsOf: chunk.prefix(count))
                } else if count == 0 {
                    outputEnded = true; completeIfReady(); return
                } else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else { finish(nil); return }
            }
        }

        private func completeIfReady() {
            guard outputEnded, let status else { return }
            finish(status == 0 ? ClaudeSSHRouteResolver.parse(bytes) : nil)
        }

        private func finish(_ result: ClaudeSSHRoute?) {
            guard !finished else { return }
            finished = true
            deadline?.cancel(); deadline = nil
            process.terminationHandler = nil
            if let source { self.source = nil; source.cancel() }
            else { try? output.fileHandleForReading.close() }
            try? output.fileHandleForWriting.close()
            bytes.removeAll(keepingCapacity: false)
            if process.isRunning {
                process.terminate()
                let child = process, ownership = ownership
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    _ = ownership
                    if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                }
            }
            let pending = continuation; continuation = nil
            pending?.resume(returning: result)
        }
    }
}
