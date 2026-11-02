#if os(Windows)
import Foundation
import CWindowsSupport

/// Recursive directory notifications on the Windows thread pool. Idle sources
/// have no polling loop; changed files use the original 1/5 second policy.
final class WindowsActivityLogWatcher: @unchecked Sendable {
    private final class Signal: @unchecked Sendable {
        weak var owner: WindowsActivityLogWatcher?
        let directory: URL
        let identity: UUID
        let discovery: Bool
        init(owner: WindowsActivityLogWatcher, directory: URL, identity: UUID, discovery: Bool) {
            self.owner = owner; self.directory = directory; self.identity = identity; self.discovery = discovery
        }
        func deliver(valid: Bool) {
            owner?.queue.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                owner.changed(directory: self.directory, identity: self.identity, valid: valid, discovery: self.discovery)
            }
        }
    }
    private final class Watch {
        let handle: UnsafeMutableRawPointer
        let signal: Unmanaged<Signal>
        init(handle: UnsafeMutableRawPointer, signal: Unmanaged<Signal>) { self.handle = handle; self.signal = signal }
        deinit { pacer_close_directory_watch(handle); signal.release() }
    }
    private let queue = DispatchQueue(label: "com.codexpacer.windows.log-watch", qos: .utility)
    private var watches: [URL: [Watch]] = [:]
    private var pending: DispatchWorkItem?
    private var pendingSince: TimeInterval?
    private var pendingRevision: UInt64 = 0
    private var needsDiscovery = false
    private var interval: TimeInterval = ActivityRefreshPolicy.collapsed.interval
    private var stopped = false
    private let changed: @Sendable (Bool) -> Void
    init(changed: @escaping @Sendable (Bool) -> Void) { self.changed = changed }

    func update(_ directories: [URL], interval: TimeInterval, flushPending: Bool = false) {
        queue.async { [self] in
            guard !stopped else { return }
            let previous = self.interval
            self.interval = min(5, max(0.1, interval))
            // The engine supplies three specific source roots, never the user's
            // home directory. Keep an independent ceiling at this boundary.
            let desired = Set(directories.filter(\.isFileURL).prefix(8).map(\.standardizedFileURL))
            if desired != Set(watches.keys), pending != nil {
                pendingRevision &+= 1; pending?.cancel(); pending = nil; pendingSince = nil; needsDiscovery = false
            }
            for directory in Array(watches.keys) where !desired.contains(directory) { watches.removeValue(forKey: directory) }
            for directory in desired where watches[directory] == nil {
                let path = Array(directory.withUnsafeFileSystemRepresentation { String(cString: $0!) }.utf16) + [0]
                let identity = UUID()
                var group: [Watch] = []
                for discovery in [false, true] {
                    let signal = Unmanaged.passRetained(Signal(owner: self, directory: directory, identity: identity, discovery: discovery))
                    let handle = path.withUnsafeBufferPointer {
                        pacer_watch_directory($0.baseAddress, discovery ? 1 : 0, signal.toOpaque()) { context, valid in
                            guard let context else { return }
                            Unmanaged<Signal>.fromOpaque(context).takeUnretainedValue().deliver(valid: valid != 0)
                        }
                    }
                    if let handle { group.append(Watch(handle: handle, signal: signal)) }
                    else { signal.release() }
                }
                if group.count == 2 { watches[directory] = group }
            }
            if pending != nil, flushPending || previous != self.interval {
                let elapsed = ProcessInfo.processInfo.systemUptime - (pendingSince ?? ProcessInfo.processInfo.systemUptime)
                schedule(after: flushPending ? 0 : max(0, self.interval - elapsed))
            }
        }
    }
    private func changed(directory: URL, identity: UUID, valid: Bool, discovery: Bool) {
        guard !stopped, watches[directory]?.first?.signal.takeUnretainedValue().identity == identity else { return }
        if !valid { watches.removeValue(forKey: directory) }
        needsDiscovery = needsDiscovery || discovery || !valid
        guard pending == nil else { return }
        pendingSince = ProcessInfo.processInfo.systemUptime
        schedule(after: interval)
    }
    private func schedule(after delay: TimeInterval) {
        pending?.cancel(); pendingRevision &+= 1
        let revision = pendingRevision
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.pendingRevision == revision else { return }
            self.pending = nil; self.pendingSince = nil
            let discovery = self.needsDiscovery; self.needsDiscovery = false
            self.changed(discovery)
        }
        pending = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func stop() {
        queue.async { [self] in
            stopped = true; pendingRevision &+= 1
            pending?.cancel(); pending = nil; pendingSince = nil; needsDiscovery = false
            watches.removeAll()
        }
    }
    func activeWatchCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: watches.count) }
        }
    }
    deinit { pending?.cancel() }
}
#endif
