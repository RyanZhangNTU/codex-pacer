import Foundation
import PacerCore

enum WindowsClaudeHookCommands {
    static func serialize(_ arguments: [String]) -> String {
        // Combined /D/C is passed intact through Git Bash, cmd and PowerShell.
        // Python is always absolute; cmd.exe is the standard Windows launcher.
        "cmd.exe /D/C call " + arguments.map { "\"" + $0.replacingOccurrences(of: "\\", with: "/") + "\"" }.joined(separator: " ")
    }
    static func validate(python: URL, home: URL) throws {
        for path in [python.path, home.path] {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"$`%!^&|<>")) == nil else { throw ClaudeHookInstaller.Failure.unsafePath }
        }
        guard command(python: python, home: home, kind: .statusLine).utf16.count < 7000 else { throw ClaudeHookInstaller.Failure.unsafePath }
    }
    private static func mode(_ kind: ClaudeHookInstaller.CommandKind) -> String { kind == .hook ? "hook" : "statusline" }
    static func command(python: URL, home: URL, kind: ClaudeHookInstaller.CommandKind, site: Bool = false) -> String {
        serialize([python.path] + (site ? [] : ["-S"]) + [home.appendingPathComponent("pacer/hook.py").path, mode(kind), home.path])
    }
    static func owned(_ command: String, home: URL, root: URL, kind: ClaudeHookInstaller.CommandKind) -> Bool {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let suffix = quote(home.appendingPathComponent("pacer/hook.py").path) + " " + mode(kind) + " " + quote(home.path)
        if command == "python3 -S " + suffix || command == "python3 " + suffix { return true }
        let prefix = "cmd.exe /D/C call \"" + root.path + "/"
        guard command.hasPrefix(prefix) else { return false }
        let remainder = command.dropFirst(prefix.count)
        guard let slash = remainder.firstIndex(of: "/") else { return false }
        let identifier = String(remainder[..<slash])
        guard WindowsClaudeRuntimeStore.validIdentifier(identifier) else { return false }
        let python = root.appendingPathComponent(identifier + "/python.exe")
        return command == self.command(python: python, home: home, kind: kind) || command == self.command(python: python, home: home, kind: kind, site: true)
    }
    static func installer(home: URL, root: URL, storage: any ClaudeHookStorage, script: Data? = nil) throws -> ClaudeHookInstaller {
        let pin = try WindowsPythonPin.load(), root = root.standardizedFileURL
        return ClaudeHookInstaller(storage: storage, python: root.appendingPathComponent(pin.identifier + "/python.exe").path,
            serialize: { arguments in serialize(arguments) }, helperScript: script,
            additionalOwnedCommand: { command, home, kind in owned(command, home: home, root: root, kind: kind) })
    }
}

/// One synchronous shared-installer operation owns this journal. Nothing is
/// written during validation; readers can inspect the planned post-cleanup JSON.
final class WindowsClaudeHookPlanStorage: ClaudeHookStorage, @unchecked Sendable {
    let base: any ClaudeHookStorage
    private var removed = Set<URL>(), directories = Set<URL>()
    private var replacements: [URL: Data] = [:]
    init(base: any ClaudeHookStorage = WindowsClaudeHookStorage()) { self.base = base }
    func validate(_ url: URL) throws { try base.validate(url) }
    func exists(_ url: URL) -> Bool { !removed.contains(url) && (replacements[url] != nil || directories.contains(url) || base.exists(url)) }
    func isDirectory(_ url: URL) -> Bool { directories.contains(url) || base.isDirectory(url) }
    func isReadable(_ url: URL) -> Bool { replacements[url] != nil || base.isReadable(url) }
    func read(_ url: URL) throws -> Data { if let value = replacements[url] { return value }; return try base.read(url) }
    func createDirectory(_ url: URL, permissions: UInt16) throws { try base.validate(url); directories.insert(url) }
    func replace(_ url: URL, with data: Data, permissions: UInt16) throws { try base.validate(url); removed.remove(url); replacements[url] = data }
    func remove(_ url: URL) throws { try base.validate(url); replacements.removeValue(forKey: url); removed.insert(url) }
}
