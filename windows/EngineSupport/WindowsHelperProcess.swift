import Foundation

struct WindowsHelperProcessLauncher: HelperProcessLauncher {
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        WindowsHelperProcess(request, output: output, ended: ended)
    }
}

private final class WindowsHelperProcess: ChildProcessConnection, @unchecked Sendable {
    private let process: WindowsCodexProcess
    private let lock = NSLock()
    private var closed = false
    init(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
         ended: @escaping @Sendable () async -> Void) {
        process = WindowsCodexProcess(executable: request.executable, arguments: request.arguments,
            environment: request.environment, received: output, closed: ended)
    }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32? { process.terminationStatus }
    var exited: ShutdownSignal { process.exited }
    var ioClosed: ShutdownSignal { process.ioClosed }
    func errorMessage() -> String { process.errorMessage }
    func write(_ data: Data) throws { if !process.write(data) { throw CodexClientError.disconnected } }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock()
        process.finishInput()
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { if process.isRunning { process.stop() } }
    }
    func terminateImmediately() { process.terminateImmediately() }
}
