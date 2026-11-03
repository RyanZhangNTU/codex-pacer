import Foundation
import PacerCore

public struct WindowsClaudeHookRuntime {
    public struct Report: Codable, Sendable {
        public let state: String
        public let hooksConfigured, telemetryConfigured, statusLineConfigured, telemetryConflict, updateAvailable: Bool
        public let launchMode: String?
        init(_ state: String, _ status: ClaudeHookInstaller.Status? = nil, launchMode: String? = nil) {
            self.state = state; hooksConfigured = status?.hooksConfigured ?? false
            telemetryConfigured = status?.telemetryConfigured ?? false; statusLineConfigured = status?.statusLineConfigured ?? false
            telemetryConflict = status?.telemetryConflict ?? false; updateAvailable = status?.updateAvailable ?? false
            self.launchMode = launchMode
        }
    }
    let runtime: WindowsClaudeRuntimeStore
    public init(root: URL = WindowsClaudeRuntimeStore.defaultRoot) { runtime = .init(root: root) }
    static func script() throws -> Data {
        guard let adapter = Bundle.module.url(forResource: "windows_claude_bootstrap", withExtension: "py"),
              let shared = L10n.sharedResourceBundle.url(forResource: "claude_hook", withExtension: "py") else { throw ClaudeHookInstaller.Failure.invalidSettings }
        let source = try Data(contentsOf: shared).base64EncodedString()
        return Data(("SHARED_SOURCE = '" + source + "'\n").utf8) + (try Data(contentsOf: adapter))
    }
    public func inspect(home: URL) -> Report {
        do {
            let storage = WindowsClaudeHookStorage()
            try storage.validate(home)
            guard storage.isDirectory(home) else { return Report("missingHome") }
            let installer = try WindowsClaudeHookCommands.installer(home: home, root: runtime.root, storage: storage, script: Self.script())
            let status = installer.details(home: home)
            let python = runtime.python(identifier: try WindowsPythonPin.load().identifier)
            try storage.validate(python)
            return Report(status.hooksConfigured && !status.updateAvailable && storage.isReadable(python) ? "ready" : "needsSetup", status,
                launchMode: WindowsClaudeHookCommands.selection(WindowsClaudeHookCommands.arguments(python: python, home: home, kind: .hook)).mode)
        } catch { return Report("failed") }
    }
    public func ensure(home: URL, package: URL) -> Report {
        do {
            return try runtime.withLock {
                let storage = WindowsClaudeHookStorage()
                try storage.validate(home)
                guard storage.isDirectory(home) else { return Report("missingHome") }
                let script = try Self.script()
                let python = runtime.python(identifier: try WindowsPythonPin.load().identifier)
                try WindowsClaudeHookCommands.validate(python: python, home: home)
                // Validate through the same shared installer before creating a
                // runtime or changing settings. The journal never commits.
                let plan = WindowsClaudeHookPlanStorage(base: storage)
                _ = try WindowsClaudeHookCommands.installer(home: home, root: runtime.root, storage: plan, script: script).install(home: home)
                _ = try runtime.ensure(package: package, home: home)
                let installer = try WindowsClaudeHookCommands.installer(home: home, root: runtime.root, storage: storage, script: script)
                let result = installer.ensureInstalled(home: home)
                guard result == .current || result == .installed else { return Report("failed") }
                // GC failure does not undo a working new adapter. Unknown or
                // referenced data is retained for a later explicit retry.
                try? runtime.collect(keeping: try WindowsPythonPin.load().identifier)
                return Report("ready", installer.details(home: home),
                    launchMode: WindowsClaudeHookCommands.selection(WindowsClaudeHookCommands.arguments(python: python, home: home, kind: .hook)).mode)
            }
        } catch { return Report("failed") }
    }
    public func uninstall(homes explicit: [URL], checkOnly: Bool = false, continueAfterFailure: Bool = false) throws {
        try runtime.withLock {
            var failed = false, all: [URL]
            do { all = try runtime.homes(including: explicit) }
            catch { all = explicit; failed = true }
            let plan = WindowsClaudeHookPlanStorage()
            var valid: [URL] = []
            for home in all {
                do { try uninstallOne(home, storage: plan); valid.append(home) }
                catch { failed = true }
            }
            if !failed {
                do { try runtime.collect(extraHomes: all, configurations: plan, requireEmpty: true, checkOnly: true) }
                catch { failed = true }
            }
            if checkOnly || (failed && !continueAfterFailure) {
                if failed { throw ClaudeHookInstaller.Failure.changedSettings }; return
            }
            for home in valid {
                do { try uninstallOne(home, storage: WindowsClaudeHookStorage()) }
                catch { failed = true }
            }
            if !failed { try runtime.collect(extraHomes: all, requireEmpty: true) }
            if failed { throw ClaudeHookInstaller.Failure.changedSettings }
        }
    }
    public func uninstallHome(_ home: URL) throws {
        try runtime.withLock {
            try uninstallOne(home, storage: WindowsClaudeHookStorage())
            try? runtime.collect(extraHomes: [home])
        }
    }
    private func uninstallOne(_ home: URL, storage: any ClaudeHookStorage) throws {
        let manifest = home.appendingPathComponent("pacer/installation.json")
        try storage.validate(manifest)
        guard storage.exists(manifest) else { return }
        try storage.validate(home)
        try WindowsClaudeHookCommands.installer(home: home, root: runtime.root, storage: storage).uninstall(home: home)
        guard !storage.exists(manifest) else { throw ClaudeHookInstaller.Failure.changedSettings }
    }
}
