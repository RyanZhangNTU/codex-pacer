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
    public func sshArguments(terminal: Bool = false) -> [String]? {
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil,
              ClaudeSSHRouteResolver.validDestination(effectiveSSHHost),
              sshPort.map({ (1...65535).contains($0) }) ?? true,
              sshIdentityFile.map(Self.validIdentityFile) ?? true else { return nil }
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
    public static func claudeConfigured(codexHome: URL, claudeHome: URL,
                                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [RemoteActivityTarget] {
        await ClaudeSSHDiscovery.shared.configured(codexHome: codexHome, claudeHome: claudeHome, userHome: userHome)
    }
    /// Initial Codex routes are available without suspended SSH route reads.
    public static func claudeCodexTargets(home: URL) -> [RemoteActivityTarget] {
        configured(home: home).map { .init(id: $0.id, name: $0.name, alias: $0.alias, home: "~/.claude") }
    }
    private static let configurations = FileSignatureCache<[RemoteActivityTarget]?>()
    /// Codex's global state can exceed a megabyte; reparse it only when it changes.
    static func readConfiguration(home: URL) -> [RemoteActivityTarget]? {
        let file = home.appendingPathComponent(".codex-global-state.json")
        return configurations.value(for: file) { parseConfiguration(file) }
    }
    private static func parseConfiguration(_ file: URL) -> [RemoteActivityTarget]? {
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
