import Foundation
import CryptoKit

public struct RemoteActivityTarget: Equatable, Sendable {
    public let id: String
    public let name: String
    public let alias: String
    public let home: String
    /// Desktop can store a destination directly instead of an SSH config alias.
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
        configured(home: home).filter { $0.id.hasPrefix(ConnectionSource.sshPrefix) }
            .map { .init(id: $0.id, name: $0.name, alias: $0.alias, home: "~/.claude") }
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
        let maximumTargets = 8
        var discovered: [RemoteActivityTarget] = [], managed: [RemoteActivityTarget] = []
        var seen = Set<String>()
        for row in rows {
            if discovered.count == maximumTargets { break }
            guard let c = try? row.fields(["source", "hostId", "alias", "displayName", "hostname", "sshPort", "identity"]),
                  let id = c["hostId"]?.string(limit: 4096), flags[id] == true, !seen.contains(id) else { continue }
            var path: String {
                routes.first { $0.hasPrefix(id + ":/") }.map { String($0.dropFirst(id.count + 1)) } ?? "~/.codex"
            }
            switch c["source"]?.string() {
            case "discovered":
                guard id.hasPrefix(ConnectionSource.sshPrefix), let alias = c["alias"]?.string(),
                      alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil else { continue }
                discovered.append(.init(id: id, name: c["displayName"]?.string(limit: 4096) ?? alias, alias: alias, home: path))
            case "codex-managed":
                guard managed.count < maximumTargets, ConnectionSource.isManagedSSHSourceID(id),
                      let target = managedTarget(c, id: id, home: path) else { continue }
                managed.append(target)
            default:
                continue
            }
            seen.insert(id)
        }
        // Keep existing SSH aliases eligible for Codex and Claude within the shared cap.
        return discovered + managed.prefix(maximumTargets - discovered.count)
    }

    private static func managedTarget(_ fields: [String: JSONFieldView], id: String, home: String) -> RemoteActivityTarget? {
        guard let host = fields["hostname"]?.string(limit: 513), !host.isEmpty, host.utf8.count <= 512 else { return nil }
        let port: Int?
        if let value = fields["sshPort"], !value.isNull {
            guard let number = value.integer(), (1...65535).contains(number) else { return nil }
            port = number
        } else { port = nil }
        let identity: String?
        if let value = fields["identity"], !value.isNull {
            guard let path = value.string(limit: 4097), !path.isEmpty, path.utf8.count <= 4096 else { return nil }
            identity = path
        } else { identity = nil }
        let name = fields["displayName"]?.string()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.flatMap { value in
            !value.isEmpty && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? value : nil
        }
        // The app uses the original ID for thread links. The helper needs a bounded key.
        let alias = "codex-" + SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return .init(id: id, name: ConnectionSource.sshName(id, displayName: displayName), alias: alias, home: home,
                     sshDestination: host, sshPort: port, sshIdentityFile: identity)
    }
}
