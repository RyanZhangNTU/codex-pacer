import Darwin
import Foundation
import PacerCore

private final class MacPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var active = true
    init(descriptor: Int32) {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }
    func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(descriptor, &bytes, 65536)
        if count > 0 { return Data(bytes.prefix(count)) }
        return count == 0 ? Data() : nil
    }
    func stop() { lock.lock(); active = false; lock.unlock() }
}

extension PipeChunkReader {
    public convenience init(descriptor: Int32) {
        let reader = MacPipeReader(descriptor: descriptor)
        self.init(read: { reader.read() }, stop: { reader.stop() })
    }
}

public struct MacChildProcessLauncher: ChildProcessLauncher {
    public init() {}
    public func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                       ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection {
        try MacChildProcess(request, output: output, ended: ended)
    }
}

private final class MacChildProcess: ChildProcessConnection, @unchecked Sendable {
    private let child: Process
    private let input: Pipe, output: Pipe, errors: Pipe
    private let reader: PipeChunkReader
    private let collector: ProcessErrorCollector
    private let lock = NSLock()
    private var closed = false
    let exited = ShutdownSignal()
    let ioClosed = ShutdownSignal()
    private let closeQueue = DispatchQueue(label: "pacer.child.close", qos: .utility)
    private var ownership: OwnedProcessTermination?

    init(_ request: ChildProcessRequest, output receive: @escaping @Sendable (Data) -> Void,
         ended: @escaping @Sendable () -> Void) throws {
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        let collector = ProcessErrorCollector(reader: PipeChunkReader(descriptor: errors.fileHandleForReading.fileDescriptor))
        self.child = child; self.input = input; self.output = output; self.errors = errors
        self.reader = reader; self.collector = collector
        child.executableURL = request.executable; child.arguments = request.arguments; child.environment = request.environment
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            if !collector.drain() { handle.readabilityHandler = nil }
        }
        output.fileHandleForReading.readabilityHandler = { _ in
            guard let data = reader.read() else { return }
            if data.isEmpty { ended() } else { receive(data) }
        }
        let exited = self.exited
        child.terminationHandler = { _ in exited.finish() }
        do { try child.run() }
        catch {
            exited.finish(); ioClosed.finish()
            reader.stop(); collector.stop()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw CodexClientError.launchFailed(path: request.executable.path, reason: CodexDiagnosticText.description(of: error))
        }
        ownership = OwnedProcessTermination { [weak self] in self?.terminateImmediately() }
    }
    var isRunning: Bool { child.isRunning }
    var terminationStatus: Int32? { child.isRunning ? nil : child.terminationStatus }
    func errorMessage() -> String { collector.message() }
    func write(_ data: Data) throws { try input.fileHandleForWriting.write(contentsOf: data) }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }; closed = true
        lock.unlock()
        let child = self.child
        DispatchQueue.global(qos: .userInitiated).async { if child.isRunning { child.terminate() } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [self] in
            terminateImmediately()
        }
        closeQueue.async { [self] in
            reader.stop(); collector.stop()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            ioClosed.finish()
        }
    }
    func terminateImmediately() {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
    }
}

extension CodexClient {
    public init(executable: URL, home: URL,
                arguments: [String] = ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"],
                timeout: TimeInterval = ProviderQuotaRefreshPolicy.replyTimeout, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(executable: executable, home: home, arguments: arguments, timeout: timeout, environment: environment,
            processes: MacChildProcessLauncher(), executables: MacExecutablePlatform(), files: MacFileSystem(),
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
    }
    public static func findExecutable(customPath: String = "") -> URL? {
        CodexExecutableResolver.discover(customPath: customPath).selected?.url
    }
}
