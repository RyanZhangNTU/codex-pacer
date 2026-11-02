import Foundation

public enum ClaudeApplicationResolver {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// Desktop mirrors SSH/WSL transcripts into its default local Claude home.
    /// Exclude only a unique active-profile remote context; never infer a host
    /// from a UUID shared by independently observed local/SSH sessions.
    public static func remoteMirrorSessionIDs(claudeHome: URL,
                                             userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        guard claudeHome.standardizedFileURL == userHome.appendingPathComponent(".claude").standardizedFileURL else { return [] }
        let records = Dictionary(grouping: desktopMetadata(userHome: userHome), by: { $0.canonicalCLI! })
        return Set(records.compactMap { id, contexts in
            guard contexts.count == 1, let context = contexts.first,
                  (context.sshConfig != nil) != (context.wslConfig != nil) else { return nil }
            if let ssh = context.sshConfig {
                guard !ssh.sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ssh.sshHost.utf8.count <= 256,
                      !ssh.sshHost.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      ssh.sshPort.map({ (1...65_535).contains($0) }) ?? true else { return nil }
            }
            return id
        })
    }

    /// Prefer an existing Desktop context only when its stored host route agrees
    /// with the source that supplied the observed CLI session. An SSH activity
    /// never borrows a local session's UUID or a connection's display name.
    public static func desktopSessionID(for sessionID: String, sourceHostID: String?,
                                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        sourceTarget: RemoteActivityTarget? = nil) async -> String? {
        await desktopSessionID(for: sessionID, sourceHostID: sourceHostID, userHome: userHome, sourceTarget: sourceTarget) { host, port in
            await ClaudeSSHRouteResolver.resolve(host: host, port: port)
        }
    }

    static func desktopSessionID(for sessionID: String, sourceHostID: String?, userHome: URL, sourceTarget: RemoteActivityTarget? = nil,
                                resolve: @escaping @Sendable (String, Int?) async -> ClaudeSSHRoute?) async -> String? {
        guard sessionID.count == 36, let session = UUID(uuidString: sessionID) else { return nil }
        let records = await Task.detached(priority: .utility) { desktopMetadata(userHome: userHome) }.value
        guard !Task.isCancelled else { return nil }
        let candidates = records.filter { $0.canonicalCLI == session.uuidString.lowercased() }
        if sourceHostID == nil {
            let local = candidates.filter { $0.sshConfig == nil && $0.wslConfig == nil }
            return Set(local.map(\.sessionId)).count == 1 ? local.first?.sessionId : nil
        }
        let prefix = "remote-ssh-discovered:"
        guard let sourceHostID, sourceHostID.hasPrefix(prefix) else { return nil }
        let alias = String(sourceHostID.dropFirst(prefix.count))
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil,
              sourceTarget.map({ $0.id == sourceHostID && $0.sshArguments() != nil }) ?? true,
              let target = await resolve(sourceTarget?.effectiveSSHHost ?? alias, sourceTarget?.sshPort) else { return nil }
        let remote = candidates.filter { $0.sshConfig != nil && $0.wslConfig == nil }
        guard remote.count <= 4 else { return nil }
        var matches = Set<String>()
        for metadata in remote {
            guard !Task.isCancelled else { return nil }
            guard let connection = metadata.sshConfig,
                  let route = await resolve(connection.sshHost, connection.sshPort), route == target else { continue }
            matches.insert(metadata.sessionId)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private struct DesktopSSHConfig: Decodable, Sendable { let sshHost: String; let sshPort: Int? }
    private struct DesktopContextMarker: Decodable, Sendable {
        private enum Keys: String, CodingKey { case distribution }
        init(from decoder: Decoder) throws { _ = try decoder.container(keyedBy: Keys.self) }
    }
    private struct DesktopRemoteSpawn: Decodable, Sendable { let ccrSessionId: String? }
    private struct DesktopSessionMetadata: Decodable, Sendable {
        let sessionId: String
        let cliSessionId: String?
        let sshConfig: DesktopSSHConfig?
        let wslConfig: DesktopContextMarker?
        let bridgeSessionIds: [String]?
        let remoteControlSpawn: DesktopRemoteSpawn?
        var canonicalCLI: String? { cliSessionId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() }
    }

    /// Cloud IDs of the sessions Desktop runs on this Mac, without their type
    /// prefix: a Project thread bound to one is already followed as a local task.
    public static func desktopCloudSessionIDs(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        Set(desktopMetadata(userHome: userHome).flatMap { ($0.bridgeSessionIds ?? []) + [$0.remoteControlSpawn?.ccrSessionId].compactMap { $0 } }
            .map(ClaudeCloudProjectState.bareID))
    }

    private static func desktopMetadata(userHome: URL) -> [DesktopSessionMetadata] {
        struct DesktopConfig: Decodable { let lastKnownAccountUuid: String? }
        let base = userHome.appendingPathComponent("Library/Application Support/Claude")
        guard let configData = ClaudeCredentialStore.boundedData(at: base.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(DesktopConfig.self, from: configData),
              let account = config.lastKnownAccountUuid, UUID(uuidString: account) != nil else { return [] }
        let root = base.appendingPathComponent("claude-code-sessions").appendingPathComponent(account)
        let manager = FileManager.default
        func directory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard directory(root) else { return [] }
        let organizations = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles])) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && directory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(16)
        var result: [DesktopSessionMetadata] = [], checked = 0
        for org in organizations {
            let files = ((try? manager.contentsOfDirectory(at: org, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("local_") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard checked < 128 else { return result }
                checked += 1
                let name = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: String(name.dropFirst("local_".count))) != nil,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let data = ClaudeCredentialStore.boundedData(at: file),
                      let metadata = try? JSONDecoder().decode(DesktopSessionMetadata.self, from: data), metadata.sessionId == name,
                      metadata.canonicalCLI != nil else { continue }
                result.append(metadata)
            }
        }
        return result
    }

}
