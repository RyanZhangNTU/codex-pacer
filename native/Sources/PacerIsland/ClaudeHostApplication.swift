import AppKit
import PacerCore

/// The app that started a local Claude session: the first regular application
/// above its live Claude Code process (a terminal, an editor, Claude Desktop or
/// an app that embeds Claude Code). Kept in memory after the process exits.
struct ClaudeHostApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let bundleURL: URL
    let name: String

    var isClaudeDesktop: Bool { bundleIdentifier == ClaudeApplicationResolver.bundleIdentifier }

    /// Hosts of the requested sessions that a live process holds right now.
    static func resolve(sessions: Set<String>, claudeHome: URL) -> [String: ClaudeHostApplication] {
        guard !sessions.isEmpty else { return [:] }
        return ClaudeLiveSessionRegistry.holders(claudeHome: claudeHome)
            .filter { sessions.contains($0.key) }.compactMapValues(application(above:))
    }

    static func application(above pid: pid_t) -> ClaudeHostApplication? {
        guard let owner = ClaudeLiveSessionRegistry.owner(of: pid, isApplication: {
                  NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }),
              let app = NSRunningApplication(processIdentifier: owner),
              let identifier = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        let name = app.localizedName ?? FileManager.default.displayName(atPath: url.path)
        return ClaudeHostApplication(bundleIdentifier: identifier, bundleURL: url,
                                     name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}
