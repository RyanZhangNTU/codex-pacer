#if os(Windows)
import Foundation
import PacerCore

struct WindowsChildProcessLauncher: ChildProcessLauncher {
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection {
        WindowsChildProcess(request: request, output: output, ended: ended)
    }
}

private final class WindowsChildProcess: ChildProcessConnection, @unchecked Sendable {
    private let process: WindowsCodexProcess
    init(request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void, ended: @escaping @Sendable () -> Void) {
        process = WindowsCodexProcess(executable: request.executable, arguments: request.arguments,
            environment: request.environment, received: { output($0) }, closed: { ended() })
    }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32? { process.terminationStatus }
    var exited: ShutdownSignal { process.exited }
    var ioClosed: ShutdownSignal { process.ioClosed }
    func errorMessage() -> String { process.errorMessage }
    func write(_ data: Data) throws { if !process.write(data) { throw CodexClientError.disconnected } }
    func close() { process.stop() }
    func terminateImmediately() { process.terminateImmediately() }
}
#endif
