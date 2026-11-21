import Foundation
import PacerCore

/// Windows' fixed hook entry point, `<home>\pacer\bin\codex-hook.cmd`.
///
/// PacerInstallerHooks writes it, with the bootstrap-wrapped program and the
/// bundled Python (`--prepare-codex-hook`, `WindowsCodexHookRuntime`); this type
/// gives Core the trusted command, confirms both files are in place and removes them.
public struct WindowsCodexHookLauncher: CodexHookLauncher {
    private let storage = WindowsLocalProfileStorage()
    public init() {}

    public static func launcher(home: URL) -> URL { home.appendingPathComponent("pacer/bin/codex-hook.cmd") }

    public func command(home: URL) -> String? { nil }

    /// Codex runs Windows handlers through Windows PowerShell 5.1, where a line
    /// that starts with a quoted path is a syntax error that Codex still records
    /// as completed; the call operator runs it. Single quotes keep `$` and
    /// backticks literal. This string is part of the trusted definition.
    public func commandWindows(home: URL) -> String? { Self.commandWindows(home: home) }

    public static func commandWindows(home: URL) -> String {
        "& '" + windowsPath(launcher(home: home)).replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func prepare(home: URL) throws {
        for path in [Self.launcher(home: home), CodexHookProgram.script(home: home)] {
            try storage.validate(path)
            guard storage.exists(path), !storage.isDirectory(path) else { throw CocoaError(.fileNoSuchFile) }
        }
        let folder = CodexHookSpool.folder(home: home)
        try storage.validate(folder)
        if !storage.exists(folder) { try storage.createDirectory(folder, permissions: 0o700) }
    }

    public func remove(home: URL) throws {
        for path in [Self.launcher(home: home), CodexHookProgram.script(home: home),
                     CodexHookSpool.current(home: home), CodexHookSpool.previous(home: home), CodexHookSpool.lock(home: home)] {
            try storage.validate(path)
            if storage.exists(path) { try storage.remove(path) }
        }
        for directory in [CodexHookSpool.folder(home: home), Self.launcher(home: home).deletingLastPathComponent()] {
            try storage.validate(directory)
            if storage.isDirectory(directory), (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try storage.remove(directory)
            }
        }
    }

    package static func windowsPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
        // Foundation spells a drive path "/C:/..." on some hosts.
        if path.hasPrefix("\\"), path.dropFirst().dropFirst().hasPrefix(":") { path.removeFirst() }
        return path
    }
}
