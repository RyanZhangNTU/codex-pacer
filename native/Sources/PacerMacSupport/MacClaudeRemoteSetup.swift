import Foundation
import Darwin
import PacerCore

extension ClaudeRemoteSetup {
    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: TimeInterval = 15) {
        self.init(executable: executable, timeout: timeout, makeOperation: { MacClaudeRemoteSetupOperation(executable: $0, arguments: $1) })
    }
}

/// Nonblocking output keeps the actor responsive to cancellation, shutdown and
/// the fixed timeout even when an SSH peer never closes its output pipe.
private final class MacClaudeRemoteSetupOperation: ClaudeRemoteSetupOperation, @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var bytes = Data()
    private var eof = false
    private var started = false
    private var closed = false
    private var stopped: ClaudeRemoteSetup.Failure?
    private var stopping = false
    private var ownership: OwnedProcessTermination?

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    var failure: ClaudeRemoteSetup.Failure? {
        lock.lock(); defer { lock.unlock() }; return stopped
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if let stopped { throw stopped }
        do { try process.run() }
        catch { throw ClaudeRemoteSetup.Failure.connectionFailed }
        let child = process
        ownership = OwnedProcessTermination { [weak child] in
            if let child, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        started = true
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            stopLocked(.setupFailed); throw ClaudeRemoteSetup.Failure.setupFailed
        }
    }

    func result() throws -> (data: Data, exitStatus: Int32)? {
        lock.lock(); defer { lock.unlock() }
        if let stopped { throw stopped }
        guard started, !closed else { throw ClaudeRemoteSetup.Failure.cancelled }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !eof {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress!, $0.count)
            }
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                if bytes.count > 4096 { stopLocked(.invalidResponse); throw ClaudeRemoteSetup.Failure.invalidResponse }
            } else if count == 0 { eof = true }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { stopLocked(.invalidResponse); throw ClaudeRemoteSetup.Failure.invalidResponse }
        }
        guard !process.isRunning, eof else { return nil }
        return (bytes, process.terminationStatus)
    }

    func abort(_ failure: ClaudeRemoteSetup.Failure) {
        lock.lock(); defer { lock.unlock() }; stopLocked(failure)
    }

    private func stopLocked(_ failure: ClaudeRemoteSetup.Failure) {
        if stopped == nil { stopped = failure }
        if started, process.isRunning, !stopping {
            stopping = true
            process.terminate()
            // A peer ignoring EOF/SIGTERM cannot leave Pacer's SSH process
            // alive. This targets the exact Process created by this operation.
            let child = process, ownership = ownership
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                _ = ownership
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        closeLocked()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if started, process.isRunning { stopLocked(.cancelled) }
        else { closeLocked() }
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    }
}
