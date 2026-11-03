import Foundation

/// One monotonic budget for a whole shutdown, including every owned child.
public struct ShutdownDeadline: Sendable {
    public static let maximumWait: TimeInterval = 0.65
    let time: DispatchTime
    public init(timeout: TimeInterval = Self.maximumWait) {
        let bounded = timeout.isFinite ? min(Self.maximumWait, max(0, timeout)) : Self.maximumWait
        time = .now() + bounded
    }
    public var hasExpired: Bool { DispatchTime.now() >= time }

    /// Unstructured work may ignore cancellation. The deadline never joins it.
    @discardableResult public func perform(_ operations: [@Sendable () async -> Void]) async -> Bool {
        let work = operations.map { operation -> (Task<Void, Never>, ShutdownSignal) in
            let finished = ShutdownSignal()
            let task = Task { await operation(); finished.finish() }
            return (task, finished)
        }
        var completed = true
        for (task, finished) in work {
            if !(await finished.wait(until: self)) { completed = false; task.cancel() }
        }
        return completed
    }

    public func finish(readers: [ShutdownSignal], children: [any ChildProcessConnection]) async {
        var completed = true
        for signal in readers + children.map(\.exited) + children.map(\.ioClosed) {
            if !(await signal.wait(until: self)) { completed = false }
        }
        if !completed { for child in children { child.terminateImmediately() } }
    }
}

/// Completion observation with a deadline, independent of cooperative cancellation.
public final class ShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    public init() {}
    public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    public func finish() {
        lock.lock()
        finished = true
        let continuations = Array(waiting.values); waiting.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: true) }
    }
    public func wait(until deadline: ShutdownDeadline) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished { lock.unlock(); continuation.resume(returning: true); return }
            if deadline.hasExpired { lock.unlock(); continuation.resume(returning: false); return }
            let id = UUID()
            waiting[id] = continuation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline.time) { [self] in
                lock.lock(); let waiting = self.waiting.removeValue(forKey: id); lock.unlock()
                waiting?.resume(returning: false)
            }
        }
    }
}

/// A last-resort exit action for a child created by Pacer, never a process scan.
public final class OwnedProcessTermination: @unchecked Sendable {
    private final class Weak: @unchecked Sendable {
        weak var value: OwnedProcessTermination?
        init(_ value: OwnedProcessTermination) { self.value = value }
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var entries: [Weak] = []
    }
    private static let registry = Registry()
    private let terminate: @Sendable () -> Void
    public init(_ terminate: @escaping @Sendable () -> Void) {
        self.terminate = terminate
        Self.registry.lock.lock()
        Self.registry.entries.removeAll { $0.value == nil }
        Self.registry.entries.append(Weak(self))
        Self.registry.lock.unlock()
    }
    public static func terminateAll() {
        registry.lock.lock()
        let current = registry.entries.compactMap(\.value)
        registry.lock.unlock()
        for child in current { child.terminate() }
    }
}

/// A client's emergency stop remains callable while its actor is occupied.
final class OwnedChildProcesses: @unchecked Sendable {
    private final class Weak {
        weak var value: (any ChildProcessConnection)?
        init(_ value: any ChildProcessConnection) { self.value = value }
    }
    private let lock = NSLock()
    private var children: [Weak] = []
    func add(_ child: any ChildProcessConnection) {
        lock.lock(); children.removeAll { $0.value == nil }; children.append(Weak(child)); lock.unlock()
    }
    func terminate() {
        lock.lock(); let current = children.compactMap(\.value); lock.unlock()
        for child in current { child.terminateImmediately() }
    }
}
