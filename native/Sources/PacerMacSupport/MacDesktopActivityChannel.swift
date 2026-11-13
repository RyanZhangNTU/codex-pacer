import Foundation
import Darwin
import PacerCore

/// The Unix driver remains synchronous on its utility queue. One bounded
/// delivery task preserves frame order, backpressure and EOF ordering.
private final class MacDesktopChannelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private weak var collector: NativeDesktopCollector?
    private var catalog: Task<Void, Never>?
    private var stopped = false
    func install(_ value: NativeDesktopCollector) { lock.lock(); collector = value; lock.unlock() }
    func observeDurable(home: URL, peer: pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, catalog == nil, let collector else { return }
        let publish: @Sendable (DurableActivityCatalog?) -> Void = { [weak collector] value in
            collector?.setDurableCatalog(value)
        }
        catalog = Task.detached(priority: .utility) {
            await MacDurableCatalog.observe(home: home, peer: peer, publish: publish,
                ipcObservations: { [weak collector] in collector?.durableIPCObservations ?? [:] },
                publishHistory: { [weak collector] scope, turns in collector?.setDurableHistory(scope: scope, turns: turns) },
                panelInView: { [weak collector] in collector?.batchesAtExpandedCadence ?? false })
        }
    }
    func stop() {
        lock.lock(); stopped = true
        let value = collector, task = catalog
        catalog = nil; lock.unlock()
        task?.cancel(); value?.stop()
    }
}

final class MacDesktopActivityChannel: DesktopActivityChannel, @unchecked Sendable {
    private let collector: NativeDesktopCollector
    private let continuation: AsyncStream<Data>.Continuation
    private let delivery: Task<Void, Never>
    private let slot: MacDesktopChannelSlot
    private let home: URL
    private let supportsDurable: Bool
    init(home: URL, hosts: Set<String>, localRuntime: Bool, interval: TimeInterval,
         frame: @escaping @Sendable (Data) async -> Void, closed: @escaping @Sendable () async -> Void) {
        let frames = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = frames.continuation
        let slot = MacDesktopChannelSlot()
        self.slot = slot; self.home = home; supportsDurable = hosts.contains(DurableActivityCatalog.hostID)
        let native = NativeDesktopCollector(home: home, hosts: hosts, localRuntime: localRuntime,
            batchInterval: interval, onFrame: { bytes in
                if case .dropped = frames.continuation.yield(bytes) { frames.continuation.finish(); slot.stop() }
            }, onClosed: { frames.continuation.finish() })
        collector = native; slot.install(native)
        delivery = Task {
            defer { slot.stop() }
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
        if supportsDurable, let peer = native.peerProcessID { slot.observeDurable(home: home, peer: peer) }
    }
    func setHosts(_ hosts: Set<String>) { collector.setHosts(hosts) }
    func discover(_ threads: [String]) { /* Mac routing and owner broadcasts supply discovery. */ }
    func discoverRemote(_ routes: [NativeDesktopSession.Key]) { collector.discoverRemote(routes) }
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) { collector.setBatchInterval(seconds, flushPending: flushPending) }
    func stop() { slot.stop(); continuation.finish(); delivery.cancel() }
}
