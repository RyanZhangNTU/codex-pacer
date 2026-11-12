import Foundation

public struct RemoteControlDirectoryStatus: Codable, Equatable, Sendable {
    public var refreshing = false
    public var refreshedAt: TimeInterval?
    public var failed = false
}

/// Saved routes add sources only before the account has a Remote Control
/// enrollment. After that, only its verified directory adds devices, as on
/// Windows. During revalidation the inbox keeps its previous bindings hidden.
/// A verified directory, a signed-out account or disabling monitoring confirms removal.
public struct RemoteControlSourceBindings: Equatable, Sendable {
    public let hostIDs: Set<String>
    public let authoritative: Bool
    public let accountScope: String?
    public let isRevalidating: Bool
    public init(hostIDs: Set<String>, authoritative: Bool, accountScope: String? = nil, isRevalidating: Bool = false) {
        self.hostIDs = hostIDs; self.authoritative = authoritative; self.accountScope = accountScope
        self.isRevalidating = isRevalidating
    }
}

/// Saved routes discover hosts; only Desktop stream evidence creates activity.
public struct RemoteControlActivityTarget: Equatable, Sendable {
    private static let configuredTargets = FileSignatureCache<[Self]>()
    public let id: String
    public let name: String
    public let online: Bool?

    public init(id: String, name: String, online: Bool? = nil) {
        self.id = id; self.name = name; self.online = online
    }

    public static func configured(home: URL) -> [RemoteControlActivityTarget] {
        let file = home.appendingPathComponent(".codex-global-state.json")
        return configuredTargets.value(for: file) { readConfigured(file) }
    }
    private static func readConfigured(_ file: URL) -> [RemoteControlActivityTarget] {
        guard let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let value = try? JSONFieldView.document(data),
              let fields = try? value.fields(["thread-project-membership-host-ids", "remote-projects", "added-remote-control-env-ids",
                                             "app-server-migrated-pinned-thread-ids-by-host", "selected-remote-host-id"]) else { return [] }
        var ids: Set<String> = []
        func add(_ host: String?) {
            let prefix = "remote-control:"
            guard let host, host.hasPrefix(prefix),
                  RemoteControlCatalogIdentity.validIdentifier(String(host.dropFirst(prefix.count))) else { return }
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
