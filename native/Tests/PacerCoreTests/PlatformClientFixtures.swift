#if os(Windows)
import Foundation
import PacerCore
@testable import PacerEngineSupport

// Exercise the same record parser with the original synthetic Mac directory
// layout. Installation discovery stays in the Mac-only integration cases.
extension ClaudeApplicationResolver {
    static func remoteMirrorSessionIDs(claudeHome: URL, userHome: URL) -> Set<String> {
        ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: claudeHome,
            defaultClaudeHome: userHome.appendingPathComponent(".claude"),
            directory: userHome.appendingPathComponent("Library/Application Support/Claude"), files: WindowsFileSystem())
    }
    static func desktopSessionID(for sessionID: String, sourceHostID: String?, userHome: URL,
                                sourceTarget: RemoteActivityTarget? = nil) async -> String? {
        await desktopSessionID(for: sessionID, sourceHostID: sourceHostID, userHome: userHome, sourceTarget: sourceTarget) { _, _ in nil }
    }
    static func desktopSessionID(for sessionID: String, sourceHostID: String?, userHome: URL,
                                sourceTarget: RemoteActivityTarget? = nil,
                                resolve: @escaping @Sendable (String, Int?) async -> ClaudeSSHRoute?) async -> String? {
        let target = sourceTarget.map {
            ClaudeDesktopRecords.SourceTarget(id: $0.id, host: $0.effectiveSSHHost, port: $0.sshPort,
                hasValidArguments: $0.sshArguments() != nil)
        }
        return await ClaudeDesktopRecords.desktopSessionID(for: sessionID, sourceHostID: sourceHostID,
            directory: userHome.appendingPathComponent("Library/Application Support/Claude"), files: WindowsFileSystem(),
            sourceTarget: target, resolve: resolve)
    }
}

extension ClaudeCredentialStore {
    static func identity(userHome: URL, home: URL) -> ClaudeAccountIdentity? {
        identity(userHome: userHome, home: home, files: WindowsFileSystem())
    }
    static func read(userHome: URL, home: URL, environment: [String: String],
                     cachedCredential: (@Sendable (ClaudeAccountIdentity) throws -> ClaudeOAuthCredential?)? = nil,
                     now: Date = Date()) throws -> ClaudeOAuthCredential? {
        try read(userHome: userHome, home: home, environment: environment,
            cachedCredential: cachedCredential, now: now, files: WindowsFileSystem())
    }
}
#endif
