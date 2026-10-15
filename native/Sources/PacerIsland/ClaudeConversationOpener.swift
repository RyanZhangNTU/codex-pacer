import AppKit
import PacerCore

/// Opening a saved session never sends a prompt or asks Claude to run a turn.
enum ClaudeConversationOpener {
    typealias DesktopLookup = @Sendable (String, String?) async -> String?

    /// Where a local session opens. A session started by any app other than
    /// Claude Desktop opens that app; none is resumed in Terminal or imported
    /// into Desktop.
    enum LocalDestination: Equatable {
        case host(ClaudeHostApplication)
        case desktop(URL)
        case missing
    }

    static func localDestination(host: ClaudeHostApplication?, desktop: URL?) -> LocalDestination {
        if let host, !host.isClaudeDesktop { return .host(host) }
        if let desktop { return .desktop(desktop) }
        return host.map { .host($0) } ?? .missing
    }

    @MainActor static func open(_ activity: SessionActivity, home: URL, sourceTarget: RemoteActivityTarget? = nil,
                                recordedHost: ClaudeHostApplication? = nil) async -> ActivityOpenOutcome {
        guard activity.provider == .claude, let session = activity.threadID,
              AgentProvider.claude.validatedSessionID(session) != nil else { return .failed(L10n.text("activity.open_failed")) }
        guard let source = activity.sourceHostID else {
            // The process holding the session now outranks an earlier record.
            let live = await Task.detached(priority: .userInitiated) {
                ClaudeLiveSessionRegistry.holder(for: session, claudeHome: home).flatMap(ClaudeHostApplication.application(above:))
            }.value
            let host = live ?? recordedHost
            let desktop = host?.isClaudeDesktop == false ? nil : await desktopDestination(for: activity, home: home)
            switch localDestination(host: host, desktop: desktop) {
            case .host(let host): return await activate(host)
            case .desktop(let destination): return await openDesktop(destination)
            case .missing: return .failed(L10n.text("activity.claude_host_missing"))
            }
        }
        if let destination = await desktopDestination(for: activity, home: home, sourceTarget: sourceTarget),
           ClaudeApplicationResolver.find() != nil {
            return await openDesktop(destination)
        }
        // An SSH session resumes over ssh in Terminal, which provides the TTY.
        let prefix = "remote-ssh-discovered:"
        guard UUID(uuidString: session) != nil, source.hasPrefix(prefix) else { return .failed(L10n.text("activity.open_failed")) }
        let alias = String(source.dropFirst(prefix.count))
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil else { return .failed(L10n.text("activity.open_failed")) }
        let target = sourceTarget ?? RemoteActivityTarget(id: source, name: alias, alias: alias, home: "~/.claude")
        guard target.id == source, let command = remoteResumeCommand(target: target, session: session) else { return .failed(L10n.text("activity.open_failed")) }
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

    /// Brings the host forward, launching it again if it quit. Which of its
    /// windows shows the session is not verified.
    @MainActor static func activate(_ host: ClaudeHostApplication) async -> ActivityOpenOutcome {
        let installed = FileManager.default.fileExists(atPath: host.bundleURL.path) ? host.bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleIdentifier)
        guard let application = installed else { return .failed(L10n.text("activity.claude_host_missing")) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                continuation.resume(returning: error.map {
                    .failed(L10n.text("activity.open_failed_detail", CodexDiagnosticText.description(of: $0)))
                } ?? .openedConversation)
            }
        }
    }

    @MainActor private static func openDesktop(_ destination: URL) async -> ActivityOpenOutcome {
        guard let app = ClaudeApplicationResolver.find() else { return .failed(L10n.text("activity.open_failed")) }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([destination], withApplicationAt: app,
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                continuation.resume(returning: error == nil ? .openedConversation : .failed(L10n.text("activity.open_failed")))
            }
        }
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func remoteResumeCommand(target: RemoteActivityTarget, session: String) -> String? {
        guard let arguments = target.sshArguments(terminal: true),
              let command = ClaudeRemoteResume.command(sessionID: session) else { return nil }
        return "/usr/bin/ssh " + (arguments + [command]).map(quote).joined(separator: " ")
    }

    /// Default Desktop metadata does not establish ownership of a separately
    /// selected local profile. SSH sessions retain their independently checked
    /// host/user/port mapping; their config directory lives on that host.
    static func desktopDestination(for activity: SessionActivity, home: URL,
                                   userHome: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                   sourceTarget: RemoteActivityTarget? = nil,
                                   lookup: DesktopLookup? = nil) async -> URL? {
        guard activity.provider == .claude, let session = activity.threadID,
              AgentProvider.claude.validatedSessionID(session) != nil,
              home.isFileURL, home.path.hasPrefix("/"),
              activity.sourceHostID != nil || home.standardizedFileURL == defaultHome(userHome: userHome).standardizedFileURL else { return nil }
        let desktopID: String?
        if let lookup { desktopID = await lookup(session, activity.sourceHostID) }
        else { desktopID = await ClaudeApplicationResolver.desktopSessionID(for: session, sourceHostID: activity.sourceHostID,
            userHome: userHome, sourceTarget: sourceTarget) }
        guard let desktopID else { return nil }
        var components = URLComponents()
        components.scheme = "claude"; components.host = "code"; components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: desktopID)]
        return components.url
    }

    private static func defaultHome(userHome: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        userHome.appendingPathComponent(".claude")
    }
}
