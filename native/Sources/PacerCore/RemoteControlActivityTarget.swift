import Foundation

/// Saved routes discover hosts; only Desktop stream evidence creates activity.
public struct RemoteControlActivityTarget: Equatable, Sendable {
    public let id: String
    public let name: String

    public static func configured(home: URL) -> [RemoteControlActivityTarget] {
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let value = try? JSONFieldView.document(data),
              let fields = try? value.fields(["thread-project-membership-host-ids", "remote-projects", "added-remote-control-env-ids",
                                             "app-server-migrated-pinned-thread-ids-by-host", "selected-remote-host-id"]) else { return [] }
        var ids: Set<String> = []
        func add(_ host: String?) {
            guard let host, host.range(of: #"^remote-control:[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return }
            ids.insert(host)
        }
        let selected = fields["selected-remote-host-id"]?.string()
        add(selected)
        do {
            if let memberships = fields["thread-project-membership-host-ids"], memberships.isObject {
                try memberships.forEachField(maximumCount: 4096) { _, host in add(host.string()) }
            }
            if let projects = fields["remote-projects"], projects.isArray {
                for project in try projects.elements(maximumCount: 256) where project.isObject {
                    add(try project.fields(["hostId"])["hostId"]?.string())
                }
            }
            if let environments = fields["added-remote-control-env-ids"], environments.isArray {
                for environment in try environments.elements(maximumCount: 64) {
                    if let id = environment.string() { add("remote-control:" + id) }
                }
            }
            if let pinned = fields["app-server-migrated-pinned-thread-ids-by-host"], pinned.isObject {
                try pinned.forEachField(maximumCount: 64) { route, _ in
                    if let boundary = route.range(of: ":/") { add(String(route[..<boundary.lowerBound])) }
                }
            }
        } catch { return [] }
        let ordered = ids.sorted { lhs, rhs in
            if (lhs == selected) != (rhs == selected) { return lhs == selected }
            return lhs < rhs
        }
        return ordered.prefix(8).map { .init(id: $0, name: "Remote Control") }
    }
}
