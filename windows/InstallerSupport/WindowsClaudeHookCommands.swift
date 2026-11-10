import Foundation
import PacerCore
import WinSDK

enum WindowsClaudeHookCommands {
    struct Selection { let command: String; let mode: String }
    private static var powershellExecutable: String? {
        var buffer = [UInt16](repeating: 0, count: 32768)
        let count = GetSystemDirectoryW(&buffer, UInt32(buffer.count))
        guard count > 0, Int(count) < buffer.count else { return nil }
        let directory = String(decoding: buffer.prefix(Int(count)), as: UTF16.self).replacingOccurrences(of: "\\", with: "/")
        let path = directory + "/WindowsPowerShell/v1.0/powershell.exe"
        return directSafe(path) ? path : nil
    }
    static var powershellPrefix: String {
        (powershellExecutable ?? "pacer-unavailable-powershell.exe") + " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "
    }
    static func directSafe(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z]:/[\p{L}\p{M}\p{N}_./~-]+\z"#, options: .regularExpression) != nil
    }
    static func shortPath(_ url: URL) -> String? {
        let input = WindowsClaudeHookStorage.wide(url)
        let count = GetShortPathNameW(input, nil, 0)
        guard count > 0, count < 32768 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(count))
        let written = GetShortPathNameW(input, &buffer, count)
        guard written > 0, written < count else { return nil }
        var path = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
        if path.hasPrefix("\\\\?\\") { path.removeFirst(4) }
        path = path.replacingOccurrences(of: "\\", with: "/")
        return directSafe(path) ? path : nil
    }
    private static func longPath(_ url: URL) -> String? {
        let input = WindowsClaudeHookStorage.wide(url)
        let count = GetLongPathNameW(input, nil, 0)
        guard count > 0, count < 32768 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(count))
        let written = GetLongPathNameW(input, &buffer, count)
        guard written > 0, written < count else { return nil }
        var path = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
        if path.hasPrefix("\\\\?\\") { path.removeFirst(4) }
        return path.replacingOccurrences(of: "\\", with: "/")
    }
    private static func normalized(_ arguments: [String]) -> [String] {
        arguments.map { $0.replacingOccurrences(of: "\\", with: "/") }
    }
    private static func directArguments(_ values: [String]) -> Bool {
        let scriptIndex = values.count == 5 ? 2 : 1
        return [0, scriptIndex, values.count - 1].allSatisfy { directSafe(values[$0]) }
    }
    static func fallback(_ arguments: [String]) -> String {
        let values = normalized(arguments), noSite = values.count == 5
        let python = URL(fileURLWithPath: values[0])
        let launcher = python.deletingLastPathComponent().appendingPathComponent("pacer-launch.ps1").path
        let valuesToQuote = [launcher, values[0], noSite ? "no-site" : "site"] + Array(values.dropFirst(noSite ? 2 : 1))
        return powershellPrefix + valuesToQuote.map { "\"" + $0 + "\"" }.joined(separator: " ")
    }
    static func selection(_ arguments: [String], shorten: (URL) -> String? = shortPath) -> Selection {
        let values = normalized(arguments), noSite = values.count == 5
        let home = values[values.count - 1]
        if directArguments(values) {
            return Selection(command: values.joined(separator: " "), mode: "direct")
        }
        if let python = shorten(URL(fileURLWithPath: values[0])), let home = shorten(URL(fileURLWithPath: home)),
           directSafe(python), directSafe(home) {
            let short = [python] + (noSite ? ["-S"] : []) + [home + "/pacer/hook.py", values[values.count - 2], home]
            return Selection(command: short.joined(separator: " "), mode: "shortPath")
        }
        return Selection(command: fallback(values), mode: "powershell")
    }
    static func serialize(_ arguments: [String]) -> String {
        selection(arguments).command
    }
    static func legacySerialize(_ arguments: [String]) -> String {
        "cmd.exe /D/C call " + normalized(arguments).map { "\"" + $0 + "\"" }.joined(separator: " ")
    }
    static func validate(python: URL, home: URL) throws {
        guard powershellExecutable != nil else { throw ClaudeHookInstaller.Failure.unsafePath }
        for path in [python.path, home.path] {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"$`%!^&|<>")) == nil else { throw ClaudeHookInstaller.Failure.unsafePath }
        }
        guard fallback(arguments(python: python, home: home, kind: .statusLine)).utf16.count < 7000 else { throw ClaudeHookInstaller.Failure.unsafePath }
    }
    private static func mode(_ kind: ClaudeHookInstaller.CommandKind) -> String { kind == .hook ? "hook" : "statusline" }
    static func arguments(python: URL, home: URL, kind: ClaudeHookInstaller.CommandKind, site: Bool = false) -> [String] {
        [python.path] + (site ? [] : ["-S"]) + [home.appendingPathComponent("pacer/hook.py").path, mode(kind), home.path]
    }
    static func command(python: URL, home: URL, kind: ClaudeHookInstaller.CommandKind, site: Bool = false) -> String {
        serialize(arguments(python: python, home: home, kind: kind, site: site))
    }
    static func owned(_ command: String, home: URL, root: URL, kind: ClaudeHookInstaller.CommandKind) -> Bool {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let suffix = quote(home.appendingPathComponent("pacer/hook.py").path) + " " + mode(kind) + " " + quote(home.path)
        if command == "python3 -S " + suffix || command == "python3 " + suffix { return true }
        var candidates: [String] = []
        for prefix in ["cmd.exe /D/C call \"" + root.path + "/", powershellPrefix + "\"" + root.path + "/", root.path + "/"] where command.hasPrefix(prefix) {
            candidates.append(String(command.dropFirst(prefix.count).prefix { $0 != "/" }))
        }
        // Either path can already contain an 8.3 ancestor (for example TEMP).
        // Expand both before locating the version, then require an exact match
        // against a command generated for this root, home and operation.
        if let first = command.split(separator: " ").first, directSafe(String(first)),
           let path = longPath(URL(fileURLWithPath: String(first))), let rootPath = longPath(root),
           let prefix = path.range(of: rootPath + "/", options: [.anchored, .caseInsensitive]) {
            candidates.append(String(path[prefix.upperBound...].prefix { $0 != "/" }))
        }
        for identifier in candidates where WindowsClaudeRuntimeStore.validIdentifier(identifier) {
            let python = root.appendingPathComponent(identifier + "/python.exe")
            for site in [false, true] {
                let values = arguments(python: python, home: home, kind: kind, site: site)
                if command == serialize(values) || command == legacySerialize(values) || command == fallback(values) { return true }
                if directArguments(normalized(values)), command == normalized(values).joined(separator: " ") { return true }
            }
        }
        return false
    }
    static func installer(home: URL, root: URL, storage: any ClaudeHookStorage, script: Data? = nil) throws -> ClaudeHookInstaller {
        let pin = try WindowsPythonPin.load(), root = root.standardizedFileURL
        return ClaudeHookInstaller(storage: storage, python: root.appendingPathComponent(pin.identifier + "/python.exe").path,
            serialize: { arguments in serialize(arguments) }, helperScript: script,
            additionalOwnedCommand: { command, home, kind in owned(command, home: home, root: root, kind: kind) },
            managedTelemetry: { WindowsClaudeManagedSettings.telemetry() })
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
