import Foundation

/// Raw file facts. Hosts deliver events without batching or polling.
public struct ActivityFileEvent: Sendable {
    public let requiresDiscovery: Bool
    public let invalidated: Bool
    public init(requiresDiscovery: Bool = false, invalidated: Bool = false) {
        self.requiresDiscovery = requiresDiscovery; self.invalidated = invalidated
    }
}

public protocol ActivityFileWatch: AnyObject, Sendable { func stop() }
public protocol ActivityFileEvents: Sendable {
    func watch(_ url: URL, isDirectory: Bool,
               changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)?
}

/// Bounded file watches and one pending debounce. Stop and replacement discard
/// late events; update can reattach entries invalidated by rename or deletion.
public final class ActivityLogWatcher: @unchecked Sendable {
    private struct Watch { let identity: UUID; let source: any ActivityFileWatch }
    private let queue = DispatchQueue(label: "com.codexpacer.request-log-watch", qos: .utility)
    private let files: any PlatformFileSystem
    private let events: any ActivityFileEvents
    private var sources: [URL: Watch] = [:]
    private var pending: DispatchWorkItem?
    private var pendingSince: TimeInterval?
    private var pendingEvents: [URL: Bool] = [:]
    private var revision: UInt64 = 0
    private var interval: TimeInterval
    private let maximumDirectoryWatches: Int
    private let changed: @Sendable (Bool) -> Void

    public init(files: any PlatformFileSystem, events: any ActivityFileEvents,
                interval: TimeInterval = 5, maximumDirectoryWatches: Int = 4,
                changed: @escaping @Sendable (Bool) -> Void) {
        self.files = files; self.events = events
        self.interval = min(5, max(0.1, interval))
        self.maximumDirectoryWatches = min(99, max(1, maximumDirectoryWatches)); self.changed = changed
    }
    public func update(_ urls: [URL], interval: TimeInterval, flushPending: Bool = false) {
        queue.async { [self] in
            let previous = self.interval
            self.interval = min(5, max(0.1, interval))
            let directories = Set(urls.filter { files.metadata($0)?.isDirectory == true }.prefix(maximumDirectoryWatches))
            let desired = Set(urls.filter { ["jsonl", "zstd"].contains($0.pathExtension) }.prefix(32)).union(directories)
            for url in Array(sources.keys) where !desired.contains(url) { sources.removeValue(forKey: url)?.source.stop() }
            pendingEvents = pendingEvents.filter { desired.contains($0.key) }
            if pendingEvents.isEmpty { cancelPending() }
            for url in desired where sources[url] == nil {
                let identity = UUID()
                guard let source = events.watch(url, isDirectory: directories.contains(url), changed: { [weak self] event in
                    self?.queue.async { [weak self] in self?.receive(event, url: url, identity: identity) }
                }) else { continue }
                sources[url] = Watch(identity: identity, source: source)
            }
            if pending != nil, flushPending || previous != self.interval {
                let elapsed = ProcessInfo.processInfo.systemUptime - (pendingSince ?? ProcessInfo.processInfo.systemUptime)
                schedulePending(after: flushPending ? 0 : max(0, self.interval - elapsed))
            }
        }
    }
    private func receive(_ event: ActivityFileEvent, url: URL, identity: UUID) {
        guard sources[url]?.identity == identity else { return }
        if event.invalidated { sources.removeValue(forKey: url)?.source.stop() }
        pendingEvents[url] = (pendingEvents[url] ?? false) || event.requiresDiscovery
        guard pending == nil else { return }
        pendingSince = ProcessInfo.processInfo.systemUptime
        schedulePending(after: interval)
    }
    private func schedulePending(after delay: TimeInterval) {
        pending?.cancel(); revision &+= 1
        let token = revision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == token else { return }
            let discover = self.pendingEvents.values.contains(true)
            self.pendingEvents.removeAll(); self.pending = nil; self.pendingSince = nil
            self.changed(discover)
        }
        pending = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func cancelPending() {
        revision &+= 1; pending?.cancel(); pending = nil; pendingSince = nil
    }
    public func stop() {
        queue.async { [self] in
            cancelPending(); pendingEvents.removeAll()
            for source in sources.values { source.source.stop() }; sources.removeAll()
        }
    }
    /// Queue synchronization and a numeric handle bound, with no path disclosure.
    public func activeWatchCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: sources.count) }
        }
    }
    deinit { pending?.cancel(); for source in sources.values { source.source.stop() } }
}
