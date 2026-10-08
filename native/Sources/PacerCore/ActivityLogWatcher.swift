import Foundation
import Darwin

/// Bounded vnode watches for incremental request accounting. No polling timer,
/// no transcript retention, and no whole-history scan on an idle machine.
public final class ActivityLogWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.codexpacer.request-log-watch", qos: .utility)
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private var pendingSince: TimeInterval?
    private var needsDiscovery = false
    private var interval: TimeInterval
    private let changed: @Sendable (Bool) -> Void
    public init(interval: TimeInterval = 5, changed: @escaping @Sendable (Bool) -> Void) {
        self.interval = interval; self.changed = changed
    }
    public func update(_ urls: [URL], interval: TimeInterval, flushPending: Bool = false) {
        queue.async { [self] in
            let previous = self.interval
            self.interval = min(5, max(0.1, interval))
            let directories = urls.filter { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeDirectory }.prefix(4)
            let desired = Set(urls.filter { $0.pathExtension == "jsonl" }.prefix(32)).union(directories)
            for (url, source) in sources where !desired.contains(url) { source.cancel(); sources.removeValue(forKey: url) }
            for url in desired where sources[url] == nil {
                let fd = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
                source.setCancelHandler { Darwin.close(fd) }
                let directory = directories.contains(url)
                source.setEventHandler { [weak self, weak source] in
                    guard let self else { return }
                    if let source, !source.data.intersection([.rename, .delete]).isEmpty {
                        source.cancel(); self.sources.removeValue(forKey: url)
                    }
                    self.needsDiscovery = self.needsDiscovery || directory
                    guard self.pending == nil else { return }
                    self.pendingSince = ProcessInfo.processInfo.systemUptime
                    self.schedulePending(after: self.interval)
                }
                sources[url] = source; source.resume()
            }
            if pending != nil, flushPending || previous != self.interval {
                let elapsed = ProcessInfo.processInfo.systemUptime - (pendingSince ?? ProcessInfo.processInfo.systemUptime)
                schedulePending(after: flushPending ? 0 : max(0, self.interval - elapsed))
            }
        }
    }
    private func schedulePending(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let discover = self.needsDiscovery
            self.needsDiscovery = false; self.pending = nil; self.pendingSince = nil
            self.changed(discover)
        }
        pending = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    public func stop() {
        queue.async { [self] in
            pending?.cancel(); pending = nil; pendingSince = nil; needsDiscovery = false
            for source in sources.values { source.cancel() }; sources.removeAll()
        }
    }
    deinit { pending?.cancel(); for source in sources.values { source.cancel() } }
}
