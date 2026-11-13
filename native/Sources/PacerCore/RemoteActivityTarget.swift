import Foundation

public struct RemoteActivityTarget: Equatable, Sendable {
    public let id: String
    public let name: String
    public let alias: String
    public let home: String
    /// Claude may store a destination directly instead of an SSH config alias.
    /// `alias` remains the stable, bounded source key used by existing state.
    public var sshDestination: String? = nil
    public var sshPort: Int? = nil
    public var sshIdentityFile: String? = nil

    public init(id: String, name: String, alias: String, home: String,
                sshDestination: String? = nil, sshPort: Int? = nil, sshIdentityFile: String? = nil) {
        self.id = id; self.name = name; self.alias = alias; self.home = home
        self.sshDestination = sshDestination; self.sshPort = sshPort; self.sshIdentityFile = sshIdentityFile
    }

    public var effectiveSSHHost: String { sshDestination ?? alias }

    /// Arguments are passed individually, never interpolated into a shell.
    public func sshArguments(terminal: Bool = false, validDestination: (String) -> Bool,
                             validIdentityFile: ((String) -> Bool)? = nil) -> [String]? {
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil,
              validDestination(effectiveSSHHost),
              sshPort.map({ (1...65535).contains($0) }) ?? true,
              sshIdentityFile.map(validIdentityFile ?? Self.validIdentityFile) ?? true else { return nil }
        var args = [terminal ? "-t" : "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"]
        if !terminal { args += ["-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"] }
        if let port = sshPort { args += ["-p", String(port)] }
        if let identity = sshIdentityFile { args += ["-i", (identity as NSString).expandingTildeInPath] }
        return args + ["--", effectiveSSHHost]
    }

    static func validIdentityFile(_ path: String) -> Bool {
        (path.hasPrefix("/") || path.hasPrefix("~/")) && path.utf8.count <= 4096 &&
            !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func configured(home: URL) -> [RemoteActivityTarget] { readConfiguration(home: home) ?? [] }
    public static func claudeConfigured(codexHome: URL, claudeHome: URL, userHome: URL,
                                        discovery: ClaudeSSHDiscovery) async -> [RemoteActivityTarget] {
        await discovery.configured(codexHome: codexHome, claudeHome: claudeHome, userHome: userHome)
    }
    /// Initial Codex routes are available without suspended SSH route reads.
    public static func claudeCodexTargets(home: URL) -> [RemoteActivityTarget] {
        configured(home: home).map { .init(id: $0.id, name: $0.name, alias: $0.alias, home: "~/.claude") }
    }
    /// Codex's global state can exceed a megabyte; reparse it only when it changes.
    static func readConfiguration(home: URL) -> [RemoteActivityTarget]? { CodexGlobalStateSummary.read(home: home).sshTargets }

    private static let rendererOwnerField = "electron-renderer-content-owner"
    private static let autoConnectField = "remote-connection-auto-connect-by-host-id"
    private static let homeRoutesField = "app-server-migrated-pinned-thread-ids-by-host"
    private static let scopedAutoConnectPrefix = "electron-account-remote-preference:\(autoConnectField):"
    private static let scopedHomeRoutesPrefix = "electron-owner-value:\(homeRoutesField):"
    static let globalStateFields: Set<String> = ["codex-managed-remote-connections", rendererOwnerField, autoConnectField, homeRoutesField]
    static let scopedFieldPrefixes = [scopedAutoConnectPrefix, scopedHomeRoutesPrefix]
    /// Any malformed connection row invalidates the list; malformed flags or routes read as absent.
    static func configuration(_ fields: [String: JSONFieldView]) -> [RemoteActivityTarget]? {
        guard let connections = fields["codex-managed-remote-connections"], connections.isArray,
              let rows = try? connections.elements(), rows.allSatisfy(\.isObject) else { return nil }
        let flagValues: JSONFieldView?, routeValues: JSONFieldView?
        if let owner = fields[rendererOwnerField] {
            // Scoped Desktop state must never inherit a previous account's settings.
            guard let scope = owner.string(limit: 65), scope.range(of: #"^[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { return [] }
            flagValues = fields[scopedAutoConnectPrefix + scope]
            routeValues = fields[scopedHomeRoutesPrefix + scope]
        } else {
            flagValues = fields[autoConnectField]
            routeValues = fields[homeRoutesField]
        }
        var flags: [String: Bool] = [:], routes: [String] = []
        do {
            if let value = flagValues, value.isObject {
                try value.forEachField(maximumCount: 4096) { id, flag in
                    guard let flag = flag.boolean() else { throw JSONFieldView.Failure.malformed }
                    flags[id] = flag
                }
            }
        } catch { flags = [:] }
        do {
            if let value = routeValues, value.isObject {
                try value.forEachField(maximumCount: 4096) { route, _ in routes.append(route) }
            }
        } catch { routes = [] }
        var targets: [RemoteActivityTarget] = []
        for row in rows where targets.count < 8 {
            guard let c = try? row.fields(["source", "hostId", "alias", "displayName"]),
                  c["source"]?.string() == "discovered", let id = c["hostId"]?.string(limit: 4096),
                  id.hasPrefix("remote-ssh-discovered:"), flags[id] == true,
                  let alias = c["alias"]?.string(),
                  alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$"#, options: .regularExpression) != nil else { continue }
            let path = routes.first { $0.hasPrefix(id + ":/") }.map { String($0.dropFirst(id.count + 1)) } ?? "~/.codex"
            targets.append(RemoteActivityTarget(id: id, name: c["displayName"]?.string(limit: 4096) ?? alias, alias: alias, home: path))
        }
        return targets
    }
}
