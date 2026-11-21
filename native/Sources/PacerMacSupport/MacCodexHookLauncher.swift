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

/// Pacer's Codex hooks on this Mac.
public enum MacCodexHookSetup {
    /// Installs or removes the hooks with the CLI that Codex Desktop bundles, so the
    /// plugin is registered by the same engine that runs Desktop's turns; a separately
    /// installed CLI is the fallback.
    public static func apply(home: URL, customExecutable: String, enabled: Bool) async -> CodexHookSetupResult {
        guard let client = client(home: home, customExecutable: customExecutable) else {
            return .init(supportsHooks: nil, installed: nil, trust: nil)
        }
        let result = await CodexHookSetup.apply(home: home, enabled: enabled, launcher: MacCodexHookLauncher(),
                                                storage: MacClaudeHookStorage(), client: client)
        await client.shutdown()
        return result
    }

    /// The hooks' trust alone, while the user allows them in Codex.
    public static func trust(home: URL, customExecutable: String) async -> [String]? {
        guard let client = client(home: home, customExecutable: customExecutable) else { return nil }
        let trust = await CodexHookSetup.trust(client: client)
        await client.shutdown()
        return trust
    }

    private static func client(home: URL, customExecutable: String) -> CodexClient? {
        let application = MacDurableExecutor.findRunning()?.application ?? CodexApplicationResolver.find()
        guard let cli = application.flatMap(MacDurableExecutor.verifiedCLI(in:)) ?? CodexClient.findExecutable(customPath: customExecutable) else {
            return nil
        }
        return CodexClient(executable: cli, home: home, timeout: 8)
    }
}
