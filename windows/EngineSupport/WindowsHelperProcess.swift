import Foundation
import PacerCore

struct WindowsHelperProcessLauncher: HelperProcessLauncher {
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        try WindowsHelperProcess(request, output: output, ended: ended)
    }
}

final class WindowsHelperProcess: ChildProcessConnection, @unchecked Sendable {
    private let process: WindowsCodexProcess
    private let lock = NSLock()
    private var closed = false
    private let privateErrors: Bool
    init(_ request: ChildProcessRequest, initialInput: Data = Data(), privateErrors: Bool = false,
         output: @escaping @Sendable (Data) async -> Void, ended: @escaping @Sendable () async -> Void) throws {
        self.privateErrors = privateErrors
        process = WindowsCodexProcess(executable: request.executable, arguments: request.arguments,
            environment: request.environment, received: output, closed: ended)
        for start in stride(from: 0, to: initialInput.count, by: 60 * 1024) {
            guard process.write(initialInput.subdata(in: start..<min(initialInput.count, start + 60 * 1024))) else {
                process.stop(); throw CodexClientError.disconnected
            }
        }
    }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32? { process.terminationStatus }
    var exited: ShutdownSignal { process.exited }
    var ioClosed: ShutdownSignal { process.ioClosed }
    func errorMessage() -> String { privateErrors ? "SSH connection unavailable" : process.errorMessage }
    func write(_ data: Data) throws { if !process.write(data) { throw CodexClientError.disconnected } }
    /// One-shot commands finish stdin without the streaming helper's close deadline.
    func finishInput() { process.finishInput() }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock()
        process.finishInput()
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { if process.isRunning { process.stop() } }
    }
    func terminateImmediately() { process.terminateImmediately() }
}
