import PacerEngineSupport
import Foundation
import PacerCore
public typealias WindowsClaudeHookStorage = WindowsLocalProfileStorage
public enum WindowsClaudeHookCleanup {
    /// Existing Pacer installations used this shared python3 command format.
    /// This adapter does not install hooks or launch Python.
    static func installer(storage: any ClaudeHookStorage = WindowsClaudeHookStorage()) -> ClaudeHookInstaller {
        ClaudeHookInstaller(storage: storage, python: "python3", serialize: { arguments in
            arguments.enumerated().map { index, argument in
                if index == 0 || argument == "-S" || ((argument == "hook" || argument == "statusline") && index == arguments.count - 2) { return argument }
                return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
        })
    }
    public static func uninstall(home: URL, checkOnly: Bool = false) throws {
        let storage: any ClaudeHookStorage = checkOnly
            ? WindowsClaudeHookPlanStorage() : WindowsClaudeHookStorage()
        let manifest = home.appendingPathComponent("pacer/installation.json")
        try storage.validate(home); try storage.validate(manifest)
        guard storage.exists(manifest) else { return }
        try WindowsClaudeHookCommands.installer(home: home, root: WindowsClaudeRuntimeStore.defaultRoot, storage: storage).uninstall(home: home)
        guard !storage.exists(manifest) else { throw ClaudeHookInstaller.Failure.changedSettings }
    }
}
