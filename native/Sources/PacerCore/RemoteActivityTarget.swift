import Foundation

public struct RemoteActivityTarget: Equatable, Sendable {
    public let id: String
    public let name: String
    public let alias: String
    public let home: String

    public static func configured(home: URL) -> [RemoteActivityTarget] { readConfiguration(home: home) ?? [] }
    static func readConfiguration(home: URL) -> [RemoteActivityTarget]? {
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = value["codex-managed-remote-connections"] as? [[String: Any]] else { return nil }
        let flags = value["remote-connection-auto-connect-by-host-id"] as? [String: Bool] ?? [:]
        let routes = value["app-server-migrated-pinned-thread-ids-by-host"] as? [String: Any] ?? [:]
        return connections.compactMap { c in
            guard c["source"] as? String == "discovered", let id = c["hostId"] as? String,
                  id.hasPrefix("remote-ssh-discovered:"), flags[id] == true,
                  let alias = c["alias"] as? String,
                  alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$"#, options: .regularExpression) != nil else { return nil }
            let path = routes.keys.first { $0.hasPrefix(id + ":/") }.map { String($0.dropFirst(id.count + 1)) } ?? "~/.codex"
            return RemoteActivityTarget(id: id, name: c["displayName"] as? String ?? alias, alias: alias, home: path)
        }.prefix(8).map { $0 }
    }
}
