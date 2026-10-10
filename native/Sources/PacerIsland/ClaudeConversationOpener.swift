import AppKit
import PacerCore

/// Opening a saved session never sends a prompt or asks Claude to run a turn.
enum ClaudeConversationOpener {
    typealias DesktopLookup = @Sendable (String, String?) async -> String?

    @MainActor static func open(_ activity: SessionActivity, home: URL) async -> ActivityOpenOutcome {
        guard activity.provider == .claude, let session = activity.threadID,
              AgentProvider.claude.validatedSessionID(session) != nil else { return .failed(L10n.text("activity.open_failed")) }
        let desktopDestination = await desktopDestination(for: activity, home: home)
        if let destination = desktopDestination, let app = ClaudeApplicationResolver.find() {
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.open([destination], withApplicationAt: app,
                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error == nil ? .openedConversation : .failed(L10n.text("activity.open_failed")))
                }
            }
        }
        // Desktop's CLI launcher also needs a real TTY. Without a verified
        // Desktop mapping, open its resume command in Terminal.
        guard UUID(uuidString: session) != nil else { return .failed(L10n.text("activity.open_failed")) }
        let command: String
        if let source = activity.sourceHostID {
            let prefix = "remote-ssh-discovered:"
            guard source.hasPrefix(prefix) else { return .failed(L10n.text("activity.open_failed")) }
            let alias = String(source.dropFirst(prefix.count))
            guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil else { return .failed(L10n.text("activity.open_failed")) }
            guard let remoteCommand = ClaudeRemoteResume.command(sessionID: session) else { return .failed(L10n.text("activity.open_failed")) }
            command = "/usr/bin/ssh -t -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes -- " + quote(alias) + " " + quote(remoteCommand)
        } else {
            guard let executable = ClaudeApplicationResolver.findExecutable(),
                  let localCommand = localResumeCommand(executable: executable, session: session,
                    directory: activity.navigationDirectory, desktop: ClaudeApplicationResolver.find() != nil,
                    home: home) else { return .failed(L10n.text("activity.open_failed")) }
            command = localCommand
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-resume-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("Resume Claude.command")
            // Remove only this owned script on exit; never write project content.
            let text = "#!/bin/sh\ntrap 'rm -f -- \"$0\"; rmdir -- \"$(dirname \"$0\")\" 2>/dev/null' EXIT\n" + command + "\n"
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else {
                try? FileManager.default.removeItem(at: directory)
                return .failed(L10n.text("activity.open_failed"))
            }
            return .dispatchedTerminal
        } catch { return .failed(L10n.text("activity.open_failed")) }
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func localResumeCommand(executable: URL, session: String, directory: URL?, desktop: Bool,
                                   home: URL = defaultHome(), userHome: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        guard executable.isFileURL, executable.path.hasPrefix("/"), let id = UUID(uuidString: session),
              home.isFileURL, home.path.hasPrefix("/"),
              directory.map({ $0.isFileURL && $0.path.hasPrefix("/") }) ?? true else { return nil }
        let usesDesktop = desktop && home.standardizedFileURL == defaultHome(userHome: userHome).standardizedFileURL
        return (directory.map { "cd -- " + quote($0.path) + " || exit 1\n" } ?? "") +
            "/usr/bin/env " + quote("CLAUDE_CONFIG_DIR=" + home.path) + " " + quote(executable.path) +
            (usesDesktop ? " --desktop --resume " : " --resume ") + quote(id.uuidString.lowercased())
    }

    /// Default Desktop metadata does not establish ownership of a separately
    /// selected local profile. SSH sessions retain their independently checked
    /// host/user/port mapping; their config directory lives on that host.
    static func desktopDestination(for activity: SessionActivity, home: URL,
                                   userHome: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                   lookup: @escaping DesktopLookup = { session, host in
                                       await ClaudeApplicationResolver.desktopSessionID(for: session, sourceHostID: host)
                                   }) async -> URL? {
        guard activity.provider == .claude, let session = activity.threadID,
              AgentProvider.claude.validatedSessionID(session) != nil,
              home.isFileURL, home.path.hasPrefix("/"),
              activity.sourceHostID != nil || home.standardizedFileURL == defaultHome(userHome: userHome).standardizedFileURL,
              let desktopID = await lookup(session, activity.sourceHostID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"; components.host = "code"; components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: desktopID)]
        return components.url
    }

    private static func defaultHome(userHome: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        userHome.appendingPathComponent(".claude")
    }
}
