import Foundation
import Darwin

/// Routing metadata is only a discovery hint, never task or completion evidence.
/// Desktop owners can already have followers and omit a new following broadcast.
/// Watch the small host/thread index instead of scanning conversation logs.
struct DesktopRouteHints {
    private struct Stamp: Equatable {
        let inode: UInt64
        let modified: Date
        let size: Int
    }
    private var stamp: Stamp?
    private var seen: Set<NativeDesktopSession.Key> = []

    mutating func changed(home: URL, hosts: Set<String>) -> [NativeDesktopSession.Key] {
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 8 * 1024 * 1024,
              let date = attributes[.modificationDate] as? Date else { return [] }
        let next = Stamp(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, modified: date, size: size)
        guard next != stamp, let bytes = try? Data(contentsOf: file),
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
