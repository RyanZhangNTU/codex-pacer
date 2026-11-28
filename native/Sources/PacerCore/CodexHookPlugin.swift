import Foundation

/// Pacer's Codex hooks ship as one local plugin, so Codex lists them together,
/// the user trusts them once and they leave cleanly.
///
/// Codex keys a plugin hook's trust by plugin ID, event and position and hashes
/// its definition; a new plugin version marks every hook "modified". The name,
/// version and definitions below therefore never change between Pacer releases.
/// The hook program lives outside the plugin, behind a fixed launcher that each
/// Pacer release may rewrite. Adding an event or capability is the one reason to
/// change a definition, and asking the user to review it again is intended.
public enum CodexHookPlugin {
    public static let market = "codex-pacer-hooks"
    public static let plugin = "pacer-hooks"
    public static let version = "1.0.0"
    public static var id: String { plugin + "@" + market }
    /// The name Codex shows for the plugin, on its Hooks page among others.
    public static let displayName = "Codex Pacer"
    /// Written next to the marketplace so Pacer only ever changes or removes its own copy.
    public static let ownerMarker = Data("codex-pacer-hooks-v1\n".utf8)

    /// Codex runs SessionEnd synchronously and clamps it, and Interrupt, to three seconds.
    public static let shortTimeout = 3
    public static let timeout = 10

    public struct Layout: Equatable, Sendable {
        public let root: URL, owner: URL, marketplace: URL, pluginRoot: URL, manifest: URL, hooks: URL
        public init(home: URL) {
            root = home.appendingPathComponent("pacer/codex-hooks/marketplace", isDirectory: true)
            owner = root.appendingPathComponent(".pacer-owner")
            marketplace = root.appendingPathComponent(".agents/plugins/marketplace.json")
            pluginRoot = root.appendingPathComponent("plugins/" + CodexHookPlugin.plugin, isDirectory: true)
            manifest = pluginRoot.appendingPathComponent(".codex-plugin/plugin.json")
            hooks = pluginRoot.appendingPathComponent("hooks/hooks.json")
        }
        /// Directories in creation order.
        public var directories: [URL] {
            [root, root.appendingPathComponent(".agents", isDirectory: true), marketplace.deletingLastPathComponent(),
             root.appendingPathComponent("plugins", isDirectory: true), pluginRoot,
             manifest.deletingLastPathComponent(), hooks.deletingLastPathComponent()]
        }
    }

    /// The three plugin files. `command` and `commandWindows` are the platform's
    /// fixed launcher invocations (`CodexHookLauncher`); a host writes only its own.
    public static func files(command: String?, commandWindows: String?) throws -> [(relativePath: String, data: Data)] {
        guard command != nil || commandWindows != nil else { throw CocoaError(.featureUnsupported) }
        let marketplace: [String: Any] = [
            "name": market, "interface": ["displayName": displayName],
            "plugins": [["name": plugin, "source": ["source": "local", "path": "./plugins/" + plugin],
                         "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"]]]
        ]
        let manifest: [String: Any] = [
            "name": plugin, "version": version, "description": "Task status for Codex Pacer.", "hooks": "./hooks/hooks.json",
            "interface": ["displayName": displayName]
        ]
        return [(".agents/plugins/marketplace.json", try json(marketplace)),
                ("plugins/\(plugin)/.codex-plugin/plugin.json", try json(manifest)),
                ("plugins/\(plugin)/hooks/hooks.json", try json(hooks(command: command, commandWindows: commandWindows)))]
    }

    /// The hook definitions. Every handler is asynchronous except SessionEnd, which
    /// Codex always waits for; the program writes no output, so it never decides anything.
    static func hooks(command: String?, commandWindows: String?) -> [String: Any] {
        func handler(_ timeout: Int, async: Bool = true) -> [String: Any] {
            var value: [String: Any] = ["type": "command", "timeout": timeout]
            if async { value["async"] = true }
            if let command { value["command"] = command }
            if let commandWindows { value["commandWindows"] = commandWindows }
            return value
        }
        func group(_ timeout: Int, async: Bool = true, matcher: String? = nil) -> [[String: Any]] {
            var value: [String: Any] = ["hooks": [handler(timeout, async: async)]]
            if let matcher { value["matcher"] = matcher }
            return [value]
        }
        return ["hooks": [
            CodexHookEvent.Kind.userPromptSubmit.rawValue: group(timeout),
            CodexHookEvent.Kind.preCompact.rawValue: group(timeout),
            CodexHookEvent.Kind.postCompact.rawValue: group(timeout),
            CodexHookEvent.Kind.stop.rawValue: group(timeout),
            CodexHookEvent.Kind.interrupt.rawValue: group(shortTimeout),
            CodexHookEvent.Kind.permissionRequest.rawValue: group(timeout, matcher: "*"),
            CodexHookEvent.Kind.subagentStart.rawValue: group(timeout),
            CodexHookEvent.Kind.subagentStop.rawValue: group(timeout),
            CodexHookEvent.Kind.sessionEnd.rawValue: group(shortTimeout, async: false)
        ]]
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

/// The platform's fixed entry point for the hook program. The command strings
/// are part of the trusted definitions and must stay the same across releases;
/// `prepare` rewrites what they start, for this Pacer release and machine.
public protocol CodexHookLauncher: Sendable {
    /// For macOS, Linux hosts and WSL: run through a POSIX shell.
    func command(home: URL) -> String?
    /// For Windows, where Codex runs the handler through Windows PowerShell.
    func commandWindows(home: URL) -> String?
    func prepare(home: URL) throws
    func remove(home: URL) throws
    /// Whether a path Codex reports names `expected`; Windows reports `\\?\` paths.
    func samePath(_ value: String, _ expected: URL) -> Bool
}

public extension CodexHookLauncher {
    func samePath(_ value: String, _ expected: URL) -> Bool {
        value.hasPrefix("/") && URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path ==
            expected.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// What Settings and the collapsed bar say about Codex task tracking.
public enum CodexHookStatus: Equatable, Sendable {
    /// The Codex module is off.
    case off
    /// Still being set up: not installed, or installed while Codex has not reported its hooks' trust.
    case notInstalled
    /// Installed; the user still has to allow this many of Pacer's hooks in Codex.
    case needsApproval(count: Int)
    case running
    /// Trusted, but Codex ran turns recently and the spool stayed silent.
    case notRunning
    /// The Codex CLI is too old to have hooks.
    case needsCodexUpdate
    case installFailed

    /// Derives the status from what Pacer can observe.
    /// - Parameters:
    ///   - trust: `hooks/list` trust states of Pacer's plugin hooks, nil when unknown;
    ///     unknown trust is not running yet, and the host asks for it again.
    ///   - lastHookEvent: the newest spool row written by the current hook program.
    ///   - lastCodexTurn: the newest rollout change no open hook turn explains
    ///     (`LocalActivityReader.hookEvidence`).
    ///   - trustedAt: when Pacer saw the user allow the hooks; turns before it ran without them.
    public static func evaluate(enabled: Bool, supportsHooks: Bool?, installed: Bool?, trust: [String]?,
                                lastHookEvent: Date?, lastCodexTurn: Date?, trustedAt: Date? = nil, now: Date,
                                silence: TimeInterval = 300) -> CodexHookStatus {
        guard enabled else { return .off }
        if supportsHooks == false { return .needsCodexUpdate }
        guard let installed else { return .installFailed }
        guard installed, let trust else { return .notInstalled }
        guard trust.count == CodexHookEvent.Kind.allCases.count else { return .installFailed }
        let pending = trust.filter { $0 != "trusted" }.count
        if pending > 0 { return .needsApproval(count: pending) }
        if let turn = lastCodexTurn, now.timeIntervalSince(turn) < silence, turn > trustedAt ?? .distantPast,
           turn.timeIntervalSince(lastHookEvent ?? .distantPast) > silence {
            return .notRunning
        }
        return .running
    }
}

/// The hook program and the POSIX launcher shared by macOS, Linux hosts and WSL.
/// Each Pacer release may rewrite both; the command that starts them never changes.
public enum CodexHookProgram {
    /// `codex_hook.py`, the only implementation; Windows wraps it in the Claude hook bootstrap.
    public static var source: Data? {
        Bundle.module.url(forResource: "codex_hook", withExtension: "py").flatMap { try? Data(contentsOf: $0) }
    }
    public static func script(home: URL) -> URL { home.appendingPathComponent("pacer/codex_hook.py") }
    public static func launcher(home: URL) -> URL { home.appendingPathComponent("pacer/bin/codex-hook") }
    /// The trusted command: the launcher's quoted path, run by a POSIX shell.
    public static func posixCommand(home: URL) -> String { quote(launcher(home: home).path) }
    /// Starts the current program with python3 and discards any output, so a
    /// broken interpreter can never answer a hook. A host without python3 skips the event.
    public static func posixLauncher(home: URL) -> Data {
        Data("""
        #!/bin/sh
        # Codex Pacer's Codex hook launcher. Each Pacer release may rewrite this file.
        command -v python3 >/dev/null 2>&1 || exit 0
        exec python3 -S -B \(quote(script(home: home).path)) hook \(quote(home.path)) >/dev/null 2>&1

        """.utf8)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
