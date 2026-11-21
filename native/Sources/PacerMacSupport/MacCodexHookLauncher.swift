import Darwin
import Foundation
import PacerCore

/// The Mac's fixed hook entry point, `<home>/pacer/bin/codex-hook`.
public struct MacCodexHookLauncher: CodexHookLauncher {
    private let storage = MacClaudeHookStorage()
    public init() {}

    public func command(home: URL) -> String? { CodexHookProgram.posixCommand(home: home) }
    public func commandWindows(home: URL) -> String? { nil }

    public func prepare(home: URL) throws {
        guard let source = CodexHookProgram.source else { throw CocoaError(.fileReadNoSuchFile) }
        let pacer = home.appendingPathComponent("pacer", isDirectory: true)
        let directories = [pacer, pacer.appendingPathComponent("bin", isDirectory: true), CodexHookSpool.folder(home: home)]
        for directory in directories {
            try storage.validate(directory)
            if !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
        }
        try write(source, to: CodexHookProgram.script(home: home), permissions: 0o600)
        try write(CodexHookProgram.posixLauncher(home: home), to: CodexHookProgram.launcher(home: home), permissions: 0o700)
    }

    public func remove(home: URL) throws {
        for path in [CodexHookProgram.launcher(home: home), CodexHookProgram.script(home: home),
                     CodexHookSpool.current(home: home), CodexHookSpool.previous(home: home), CodexHookSpool.lock(home: home)] {
            try storage.validate(path)
            if storage.exists(path) { try storage.remove(path) }
        }
        _ = rmdir(CodexHookSpool.folder(home: home).path)
        _ = rmdir(CodexHookProgram.launcher(home: home).deletingLastPathComponent().path)
    }

    private func write(_ bytes: Data, to path: URL, permissions: UInt16) throws {
        try storage.validate(path)
        if (try? storage.read(path)) != bytes { try storage.replace(path, with: bytes, permissions: permissions) }
    }
}
