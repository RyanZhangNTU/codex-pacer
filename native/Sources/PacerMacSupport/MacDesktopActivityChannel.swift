import Foundation
import PacerCore

/// The Unix driver remains synchronous on its utility queue. One bounded
/// delivery task preserves frame order, backpressure and EOF ordering.
private final class MacDesktopChannelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private weak var collector: NativeDesktopCollector?
    func install(_ value: NativeDesktopCollector) { lock.lock(); collector = value; lock.unlock() }
    func stop() { lock.lock(); let value = collector; lock.unlock(); value?.stop() }
}

final class MacDesktopActivityChannel: DesktopActivityChannel, @unchecked Sendable {
    private let collector: NativeDesktopCollector
    private let continuation: AsyncStream<Data>.Continuation
    private let delivery: Task<Void, Never>
    init(home: URL, hosts: Set<String>, localRuntime: Bool, interval: TimeInterval,
         frame: @escaping @Sendable (Data) async -> Void, closed: @escaping @Sendable () async -> Void) {
        let frames = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = frames.continuation
        let slot = MacDesktopChannelSlot()
        let native = NativeDesktopCollector(home: home, hosts: hosts, localRuntime: localRuntime,
            batchInterval: interval, onFrame: { bytes in
                if case .dropped = frames.continuation.yield(bytes) { frames.continuation.finish(); slot.stop() }
            }, onClosed: { frames.continuation.finish() })
        collector = native; slot.install(native)
        delivery = Task {
            for await bytes in frames.stream {
                guard !Task.isCancelled else { return }
                await frame(bytes)
            }
            native.stop()
            if !Task.isCancelled { await closed() }
        }
    }
    func start() async throws {
        let native = collector
        try await Task.detached(priority: .utility) { try native.start() }.value
    }
    func setHosts(_ hosts: Set<String>) { collector.setHosts(hosts) }
    func discover(_ threads: [String]) { /* Mac routing and owner broadcasts supply discovery. */ }
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) { collector.setBatchInterval(seconds, flushPending: flushPending) }
    func stop() { collector.stop(); continuation.finish(); delivery.cancel() }
}
