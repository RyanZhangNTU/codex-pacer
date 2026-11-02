import Darwin
import Foundation
import PacerCore

public struct MacHelperProcessLauncher: HelperProcessLauncher {
    public init() {}
    public func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                       ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        try MacHelperProcess(request, output: output, ended: ended)
    }
}

private final class MacHelperProcess: ChildProcessConnection, @unchecked Sendable {
    private let process: Process
    private let input: FileHandle, output: FileHandle
    private let reader: PipeChunkReader
    private let receive: @Sendable (Data) async -> Void
    private let ended: @Sendable () async -> Void
    private let lock = NSLock()
    private let closeQueue = DispatchQueue(label: "pacer.helper.close", qos: .utility)
    private var closed = false
    private var ownership: OwnedProcessTermination?
    let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
    init(_ request: ChildProcessRequest, output receive: @escaping @Sendable (Data) async -> Void,
         ended: @escaping @Sendable () async -> Void) throws {
        let process = Process(), input = Pipe(), output = Pipe()
        self.process = process; self.input = input.fileHandleForWriting; self.output = output.fileHandleForReading
        self.reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        self.receive = receive; self.ended = ended
        process.executableURL = request.executable; process.arguments = request.arguments; process.environment = request.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let exited = self.exited
        process.terminationHandler = { _ in exited.finish() }
        let fd = input.fileHandleForWriting.fileDescriptor, flags = Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        _ = Darwin.fcntl(fd, F_SETNOSIGPIPE, 1)
        arm()
        do { try process.run() }
        catch { close(); exited.finish(); throw error }
        ownership = OwnedProcessTermination { [weak self] in self?.terminateImmediately() }
    }
    private func arm() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        output.readabilityHandler = { [weak self] handle in
            guard let self, let bytes = self.reader.read() else { return }
            handle.readabilityHandler = nil
            Task { [self] in
                if bytes.isEmpty { await self.ended() }
                else { await self.receive(bytes); self.arm() }
            }
        }
    }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32? { process.isRunning ? nil : process.terminationStatus }
    func errorMessage() -> String { "" }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, data.count <= 64 * 1024 else { throw POSIXError(.EPIPE) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE) }
        }
    }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock()
        closeQueue.async { [self] in
            try? input.close(); reader.stop(); output.readabilityHandler = nil; try? output.close(); ioClosed.finish()
        }
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [self] in terminateImmediately() }
    }
    func terminateImmediately() { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
}
