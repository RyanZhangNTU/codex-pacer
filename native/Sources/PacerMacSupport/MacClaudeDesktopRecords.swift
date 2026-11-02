import Foundation
import PacerCore

extension ClaudeApplicationResolver {
    private static func desktopDirectory(_ userHome: URL) -> URL {
        userHome.appendingPathComponent("Library/Application Support/Claude")
    }
    public static func remoteMirrorSessionIDs(claudeHome: URL,
                                             userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: claudeHome,
            defaultClaudeHome: userHome.appendingPathComponent(".claude"), directory: desktopDirectory(userHome), files: MacFileSystem())
    }
    public static func desktopCloudSessionIDs(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        ClaudeDesktopRecords.cloudSessionIDs(directory: desktopDirectory(userHome), files: MacFileSystem())
    }
    public static func desktopSessionID(for sessionID: String, sourceHostID: String?,
                                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        sourceTarget: RemoteActivityTarget? = nil) async -> String? {
        await desktopSessionID(for: sessionID, sourceHostID: sourceHostID, userHome: userHome, sourceTarget: sourceTarget) { host, port in
            await ClaudeSSHRouteResolver.resolve(host: host, port: port)
        }
    }
    public static func desktopSessionID(for sessionID: String, sourceHostID: String?, userHome: URL,
                                        sourceTarget: RemoteActivityTarget? = nil,
                                        resolve: @escaping @Sendable (String, Int?) async -> ClaudeSSHRoute?) async -> String? {
        let target = sourceTarget.map {
            ClaudeDesktopRecords.SourceTarget(id: $0.id, host: $0.effectiveSSHHost, port: $0.sshPort,
                hasValidArguments: $0.sshArguments() != nil)
        }
        return await ClaudeDesktopRecords.desktopSessionID(for: sessionID, sourceHostID: sourceHostID,
            directory: desktopDirectory(userHome), files: MacFileSystem(), sourceTarget: target, resolve: resolve)
    }
}
