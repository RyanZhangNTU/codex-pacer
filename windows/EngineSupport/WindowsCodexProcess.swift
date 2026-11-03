#if os(Windows)
import Foundation
import PacerCore
import Subprocess

/// Keeps Subprocess's execution and streams inside their closure. Requests
/// enter through a bounded channel; stdout is consumed serially with backpressure.
final class WindowsCodexProcess: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true, spawned = false
        private var status: Int32?
        private var launchError: String?
        private var stderr = Data()
        private var terminate: (@Sendable () -> Void)?
        func setTermination(_ action: (@Sendable () -> Void)?) { lock.lock(); defer { lock.unlock() }; terminate = action }
        func terminateImmediately() { lock.lock(); defer { lock.unlock() }; terminate?() }
        func didSpawn() { lock.lock(); defer { lock.unlock() }; spawned = true }
        func appendError(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            stderr.append(data)
            if stderr.count > 8192 { stderr = Data(stderr.suffix(8192)) }
        }
        func finish(status: Int32?, error: Error? = nil) {
            let detail = error.map { CodexDiagnosticText.description(of: $0) }
            lock.lock(); defer { lock.unlock() }
            running = false; self.status = status
            if !spawned { launchError = detail }
            else if let detail, stderr.isEmpty { stderr = Data(detail.utf8) }
        }
        func snapshot() -> (running: Bool, status: Int32?, launchError: String?, stderr: Data) {
            lock.lock(); defer { lock.unlock() }; return (running, status, launchError, stderr)
        }
    }
    private let state: State
    private let input: AsyncStream<Data>.Continuation
    private let worker: Task<Void, Never>
    let exited = ShutdownSignal()
    let ioClosed = ShutdownSignal()
    var isRunning: Bool { state.snapshot().running }
    var terminationStatus: Int32? { state.snapshot().status }
    var launchFailure: String? { state.snapshot().launchError }
    var errorMessage: String {
        let message = CodexDiagnosticText.sanitized(String(decoding: state.snapshot().stderr, as: UTF8.self), limit: 32768)
        return message.count > 1200 ? L10n.text("diagnostic.older_omitted", String(message.suffix(1200))) : message
    }
    init(executable: URL, arguments: [String], environment: [String: String],
         received: @escaping @Sendable (Data) async -> Void, closed: @escaping @Sendable () async -> Void) {
        let state = State(), channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.state = state; input = channel.continuation
        let exited = self.exited, ioClosed = self.ioClosed
        worker = Task {
            let ownership = UUID()
            WindowsOwnedProcesses.register(ownership) { state.terminateImmediately() }
            defer { WindowsOwnedProcesses.remove(ownership) }
            if Task.isCancelled || WindowsOwnedProcesses.isExiting {
                state.finish(status: nil)
                exited.finish(); ioClosed.finish()
                channel.continuation.finish()
                await closed()
                return
            }
            var options = PlatformOptions()
            WindowsConsole.hide(&options)
            options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .milliseconds(500))]
            do {
                let executablePath = WindowsCodexExecutableDiscovery.path(executable)
                let variables = environment.reduce(into: [Environment.Key: String]()) { $0[Environment.Key(stringLiteral: $1.key)] = $1.value }
                let result = try await Subprocess.run(.path(.init(executablePath)), arguments: Arguments(arguments),
                    environment: .custom(variables), platformOptions: options, input: .inputWriter, output: .sequence, error: .sequence) { execution in
                    state.didSpawn()
                    state.setTermination { try? execution.terminate(withExitCode: 1, toProcessGroup: true) }
                    // The library owns an isolated job, but closing its handle
                    // does not terminate descendants. Clean the whole job even
                    // when the immediate child exits before teardown starts.
                    defer { state.setTermination(nil); try? execution.terminate(withExitCode: 0, toProcessGroup: true) }
                    if WindowsOwnedProcesses.isExiting { throw CancellationError() }
                    try await withTaskCancellationHandler {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask {
                                defer { channel.continuation.finish() }
                                for try await bytes in execution.standardOutput {
                                    guard !Task.isCancelled else { return }
                                    await received(bytes.withUnsafeBytes { Data($0) })
                                }
                            }
                            group.addTask {
                                for try await bytes in execution.standardError {
                                    guard !Task.isCancelled else { return }
                                    state.appendError(bytes.withUnsafeBytes { Data($0) })
                                }
                            }
                            group.addTask {
                                for await data in channel.stream {
                                    guard !Task.isCancelled else { return }
                                    let written = try await execution.standardInputWriter.write(data)
                                    guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
                                }
                                try await execution.standardInputWriter.finish()
                            }
                            do { while let _ = try await group.next() {} }
                            catch { channel.continuation.finish(); group.cancelAll(); throw error }
                        }
                    } onCancel: {
                        try? execution.terminate(withExitCode: 0, toProcessGroup: true)
                    }
                }
                if case .exited(let code) = result.terminationStatus { state.finish(status: Int32(bitPattern: code)) }
            } catch { state.finish(status: nil, error: error) }
            channel.continuation.finish()
            exited.finish(); ioClosed.finish()
            await closed()
        }
    }
    func write(_ data: Data) -> Bool {
        guard data.count <= 64 * 1024, state.snapshot().running else { return false }
        if case .enqueued = input.yield(data) { return true }
        return false
    }
    func finishInput() { input.finish() }
    func stop() { input.finish(); worker.cancel(); state.terminateImmediately() }
    func terminateImmediately() { state.terminateImmediately() }
    func waitForExit() async { _ = await exited.wait(until: ShutdownDeadline()) }
    deinit { input.finish(); worker.cancel() }
}
#endif
