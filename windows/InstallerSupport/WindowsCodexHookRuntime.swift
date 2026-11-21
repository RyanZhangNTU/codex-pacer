import Foundation
import PacerCore
import PacerEngineSupport

/// Prepares Pacer's Codex hooks on Windows: the bundled Python the progress
/// reporter already uses, the shared `codex_hook.py` wrapped in the Claude hook
/// bootstrap at `<home>\pacer\codex_hook.py`, and the fixed launcher
/// `<home>\pacer\bin\codex-hook.cmd` that the trusted plugin definitions start.
///
/// Codex keys its trust to the definition, so the launcher's path never changes;
/// each release rewrites what it starts. The launcher holds no literal path that
/// could be non-ASCII, because cmd reads batch files in the console code page:
/// the Codex home comes from the launcher's own location and the Python under
/// `%LOCALAPPDATA%` through that variable, both expanded as Unicode at run time.
public struct WindowsCodexHookRuntime {
    public enum Failure: Error, Equatable { case missingResource, unsupportedPath }
    private let progress: WindowsCodexProgressRuntime
    private let environment: [String: String]
    private let storage = WindowsLocalProfileStorage()

    public init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        progress = WindowsCodexProgressRuntime(root: root)
        self.environment = environment
    }

    /// Writes the program and the launcher and returns the launcher's path.
    public func prepare(home: URL, package: URL) throws -> URL {
        let python = URL(fileURLWithPath: try progress.prepare(home: home, package: package).executable)
        let program = try Self.program()
        let launcher = try Self.launcher(python: python, environment: environment)
        let pacer = home.appendingPathComponent("pacer", isDirectory: true)
        for directory in [pacer, pacer.appendingPathComponent("bin", isDirectory: true), CodexHookSpool.folder(home: home)] {
            try storage.validate(directory)
            if !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
        }
        try write(program, to: CodexHookProgram.script(home: home))
        let path = WindowsCodexHookLauncher.launcher(home: home)
        try write(launcher, to: path)
        return path
    }

    /// `codex_hook.py` behind the Windows bootstrap that provides `fcntl.flock`
    /// and replaces `private_open`, as the Claude hook is run.
    static func program() throws -> Data {
        guard let adapter = Bundle.module.url(forResource: "windows_claude_bootstrap", withExtension: "py"),
              let shared = CodexHookProgram.source else { throw Failure.missingResource }
        return Data(("SHARED_SOURCE = '" + shared.base64EncodedString() + "'\n").utf8) + (try Data(contentsOf: adapter))
    }

    /// The launcher's bytes: ASCII with CRLF line ends. It forwards stdin to the
    /// program, discards any output so a broken interpreter can never answer a
    /// hook, and always exits 0.
    static func launcher(python: URL, environment: [String: String]) throws -> Data {
        let interpreter = try batchPath(python, environment: environment)
        let lines = [
            "@echo off",
            "rem Codex Pacer's Codex hook launcher. Each Pacer release may rewrite this file;",
            "rem the trusted Codex hook definition that starts it never changes.",
            "setlocal",
            "for %%I in (\"%~dp0..\\..\") do set \"PACER_CODEX_HOME=%%~fI\"",
            "\"\(interpreter)\" -S -B \"%PACER_CODEX_HOME%\\pacer\\codex_hook.py\" hook \"%PACER_CODEX_HOME%\" >nul 2>&1",
            "exit /b 0"
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The interpreter as the launcher names it: under `%LOCALAPPDATA%` through
    /// the variable, otherwise a literal path only when it is plain ASCII.
    static func batchPath(_ url: URL, environment: [String: String]) throws -> String {
        let path = windowsPath(url)
        if let local = environment.first(where: { $0.key.caseInsensitiveCompare("LOCALAPPDATA") == .orderedSame })?.value, !local.isEmpty {
            let base = windowsPath(URL(fileURLWithPath: local, isDirectory: true))
            let prefix = base.hasSuffix("\\") ? base : base + "\\"
            if path.lowercased().hasPrefix(prefix.lowercased()) {
                let rest = String(path.dropFirst(prefix.count))
                if safe(rest) { return "%LOCALAPPDATA%\\" + rest }
            }
        }
        if safe(path) { return path }
        if let short = WindowsClaudeHookCommands.shortPath(url), safe(short.replacingOccurrences(of: "/", with: "\\")) {
            return short.replacingOccurrences(of: "/", with: "\\")
        }
        throw Failure.unsupportedPath
    }

    static func windowsPath(_ url: URL) -> String {
        var path = WindowsCodexHookLauncher.windowsPath(url)
        while path.count > 3, path.hasSuffix("\\") { path.removeLast() }
        return path
    }

    /// Printable ASCII without the characters cmd treats specially in a quoted command line.
    static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) && !"\"%^&|<>!".unicodeScalars.contains($0) }
    }

    private func write(_ bytes: Data, to path: URL) throws {
        try storage.validate(path)
        if (try? storage.read(path)) != bytes { try storage.replace(path, with: bytes, permissions: 0o600) }
    }
}
