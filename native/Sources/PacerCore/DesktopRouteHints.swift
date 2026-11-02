import Foundation

/// Routing metadata is only a discovery hint, never task or completion evidence.
/// Desktop owners can already have followers and omit a new following broadcast.
/// Watch the small host/thread index instead of scanning conversation logs.
public struct DesktopRouteHints {
    private let files: any PlatformFileSystem
    private let owned: (URL) -> Bool
    public init(files: any PlatformFileSystem, owned: @escaping (URL) -> Bool) {
        self.files = files; self.owned = owned
    }
    private struct Stamp: Equatable {
        let identity: String
        let modified: Date
        let size: UInt64
    }
    private var stamp: Stamp?
    private var seen: Set<NativeDesktopSession.Key> = []

    public mutating func changed(home: URL, hosts: Set<String>) -> [NativeDesktopSession.Key] {
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard let metadata = files.metadata(file), metadata.isRegularFile, owned(file),
              metadata.size <= 8 * 1024 * 1024 else { return [] }
        let next = Stamp(identity: metadata.identity, modified: metadata.modified, size: metadata.size)
        guard next != stamp, let bytes = try? files.read(file, offset: 0, maximumBytes: 8 * 1024 * 1024 + 1),
              bytes.count <= 8 * 1024 * 1024,
              let fields = try? JSONFieldView.document(bytes).fields([
                "thread-project-membership-host-ids", "app-server-migrated-pinned-thread-ids-by-host"
              ]) else { return [] }
        var routes: Set<NativeDesktopSession.Key> = []
        func add(_ thread: String, _ host: String) {
            guard hosts.contains(host), let id = UUID(uuidString: thread) else { return }
            routes.insert(.init(host: host, thread: id.uuidString.lowercased()))
        }
        do {
            if let memberships = fields["thread-project-membership-host-ids"], memberships.isObject {
                try memberships.forEachField(maximumCount: 4096) { thread, host in
                    if let host = host.string() { add(thread, host) }
                }
            }
            if let pinned = fields["app-server-migrated-pinned-thread-ids-by-host"], pinned.isObject {
                try pinned.forEachField(maximumCount: 64) { route, threads in
                    guard let host = hosts.first(where: { route.hasPrefix($0 + ":/") }), threads.isArray else { return }
                    for thread in try threads.elements(maximumCount: 256) { if let id = thread.string() { add(id, host) } }
                }
            }
        } catch { return [] }
        let initial = stamp == nil
        let added = routes.subtracting(seen).sorted { $0.thread > $1.thread }
        stamp = next; seen = routes
        // Startup metadata also contains unloaded history. Bound that bootstrap;
        // later additions are independent so history never crowds out a new task.
        var counts: [String: Int] = [:]
        return added.filter { key in
            counts[key.host, default: 0] += 1
            return counts[key.host, default: 0] <= (initial ? 8 : 32)
        }
    }
}
