import Foundation

public struct ClaudeSSHRoute: Equatable, Sendable {
    public init(hostname: String, user: String, port: Int) {
        self.hostname = hostname; self.user = user; self.port = port
    }
    public let hostname: String
    public let user: String
    public let port: Int
}


public enum ClaudeDesktopRecords {
    public struct Record: Equatable, Sendable {
        public let desktopID: String, cliID: String
        public let isLocal: Bool
        public let cloudIDs: Set<String>
    }
    /// Hosts may supply several package roots; mixed active accounts cannot
    /// borrow each other's local mappings or mirror exclusions.
    public static func load(configFiles: [URL], files: any PlatformFileSystem) -> [Record] {
        struct Config: Decodable { let lastKnownAccountUuid: String? }
        var seen = Set<URL>(), bases: [(URL, UUID)] = []
        for file in configFiles.prefix(16) where seen.insert(file.standardizedFileURL).inserted {
            guard let bytes = ClaudeCredentialStore.boundedData(at: file, files: files),
                  let config = try? JSONDecoder().decode(Config.self, from: bytes),
                  let text = config.lastKnownAccountUuid, let account = UUID(uuidString: text) else { continue }
            bases.append((file.deletingLastPathComponent(), account))
        }
        guard Set(bases.map { $0.1 }).count == 1 else { return [] }
        return bases.flatMap { desktopMetadata(directory: $0.0, files: files) }.compactMap { row in
            guard let cli = row.canonicalCLI else { return nil }
            let cloud = (row.bridgeSessionIds ?? []) + [row.remoteControlSpawn?.ccrSessionId].compactMap { $0 }
            return Record(desktopID: row.sessionId, cliID: cli, isLocal: row.sshConfig == nil && row.wslConfig == nil,
                cloudIDs: Set(cloud.map(ClaudeCloudProjectState.bareID)))
        }
    }
    public static func localSessionID(for sessionID: String, records: [Record]) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else { return nil }
        let local = records.filter { $0.cliID == uuid.uuidString.lowercased() && $0.isLocal }
        let ids = Set(local.map(\.desktopID))
        return ids.count == 1 ? ids.first : nil
    }
    public struct SourceTarget: Sendable {
        public let id: String
        public let host: String
        public let port: Int?
        public let hasValidArguments: Bool
        public init(id: String, host: String, port: Int?, hasValidArguments: Bool) {
            self.id = id; self.host = host; self.port = port; self.hasValidArguments = hasValidArguments
        }
    }
    /// Desktop mirrors SSH/WSL transcripts into its default local Claude home.
    /// Exclude only a unique active-profile remote context; never infer a host
    /// from a UUID shared by independently observed local/SSH sessions.
    public static func remoteMirrorSessionIDs(claudeHome: URL,
                                             defaultClaudeHome: URL, directory: URL, files: any PlatformFileSystem) -> Set<String> {
        remoteMirrorSessionIDs(claudeHome: claudeHome, defaultClaudeHome: defaultClaudeHome, directories: [directory], files: files)
    }
    public static func remoteMirrorSessionIDs(claudeHome: URL,
                                             defaultClaudeHome: URL, directories: [URL], files: any PlatformFileSystem) -> Set<String> {
        guard claudeHome.standardizedFileURL == defaultClaudeHome.standardizedFileURL else { return [] }
        let records = Dictionary(grouping: Set(directories.prefix(16)).flatMap { desktopMetadata(directory: $0, files: files) }, by: { $0.canonicalCLI! })
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
    public static func desktopSessionID(for sessionID: String, sourceHostID: String?, directory: URL, files: any PlatformFileSystem, sourceTarget: SourceTarget? = nil,
                                resolve: @escaping @Sendable (String, Int?) async -> ClaudeSSHRoute?) async -> String? {
        guard sessionID.count == 36, let session = UUID(uuidString: sessionID) else { return nil }
        let records = await Task.detached(priority: .utility) { desktopMetadata(directory: directory, files: files) }.value
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
              sourceTarget.map({ $0.id == sourceHostID && $0.hasValidArguments }) ?? true,
              let target = await resolve(sourceTarget?.host ?? alias, sourceTarget?.port) else { return nil }
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
    public static func cloudSessionIDs(directory: URL, files: any PlatformFileSystem) -> Set<String> {
        Set(desktopMetadata(directory: directory, files: files).flatMap { ($0.bridgeSessionIds ?? []) + [$0.remoteControlSpawn?.ccrSessionId].compactMap { $0 } }
            .map(ClaudeCloudProjectState.bareID))
    }

    private static func desktopMetadata(directory base: URL, files: any PlatformFileSystem) -> [DesktopSessionMetadata] {
        struct DesktopConfig: Decodable { let lastKnownAccountUuid: String? }
        guard let configData = ClaudeCredentialStore.boundedData(at: base.appendingPathComponent("config.json"), files: files),
              let config = try? JSONDecoder().decode(DesktopConfig.self, from: configData),
              let account = config.lastKnownAccountUuid, UUID(uuidString: account) != nil else { return [] }
        let root = base.appendingPathComponent("claude-code-sessions").appendingPathComponent(account)
        func directory(_ url: URL) -> Bool { files.metadata(url)?.isDirectory == true }
        guard directory(root) else { return [] }
        let organizations = ((try? files.entries(in: root)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && directory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(16)
        var result: [DesktopSessionMetadata] = [], checked = 0
        for org in organizations {
            let records = ((try? files.entries(in: org)) ?? [])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("local_") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in records {
                guard checked < 128 else { return result }
                checked += 1
                let name = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: String(name.dropFirst("local_".count))) != nil,
                      files.metadata(file)?.isRegularFile == true,
                      let data = ClaudeCredentialStore.boundedData(at: file, files: files),
                      let metadata = try? JSONDecoder().decode(DesktopSessionMetadata.self, from: data), metadata.sessionId == name,
                      metadata.canonicalCLI != nil else { continue }
                result.append(metadata)
            }
        }
        return result
    }

}
