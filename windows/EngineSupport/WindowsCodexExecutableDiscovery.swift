#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

enum WindowsEnvironment {
    static func value(_ key: String, in values: [String: String]) -> String? {
        values.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    static func replacing(_ key: String, with value: String, in values: [String: String]) -> [String: String] {
        var result = values.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
        result[key] = value; return result
    }
}

enum WindowsCodexExecutableDiscovery {
    static let packageFamily = "OpenAI.Codex_2p2nqsd0c76g0"
    private static let nativeTargets = [
        "node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe",
        "node_modules/@openai/codex/node_modules/@openai/codex-windows-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe",
        "node_modules/@openai/codex/vendor/x86_64-pc-windows-msvc/codex/codex.exe"
    ]
    static func absolute(_ path: String) -> Bool {
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && path.utf8.count <= 32768
            && path.range(of: #"^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)"#, options: .regularExpression) != nil
    }
    static func path(_ url: URL) -> String { url.withUnsafeFileSystemRepresentation { String(cString: $0!) } }
    static func normalize(_ input: String, userHome: URL) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value.removeFirst(); value.removeLast() }
        if value == "~" { return path(userHome) }
        if value.hasPrefix("~/") || value.hasPrefix("~\\") {
            return path(userHome.appendingPathComponent(String(value.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")))
        }
        return value
    }
    static func isExecutable(_ url: URL) -> Bool {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        let wide = Array(path(url).utf16) + [0]
        return pacer_is_windows_executable(wide) != 0
    }
    static func packageLocations() -> [URL] {
        var locations: [URL] = []
        for index in 0..<32 {
            var path = [UInt16](repeating: 0, count: 32768)
            guard pacer_codex_package_path(index, &path, path.count) != 0 else { break }
            let text = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
            if absolute(text) { locations.append(URL(fileURLWithPath: text)) }
        }
        return locations.sorted { $0.path.compare($1.path, options: .numeric) == .orderedDescending }
    }
    static func launchEnvironment(executable: URL, inherited: [String: String]) -> [String: String] {
        let directories = [path(executable.deletingLastPathComponent())] + pathEntries(WindowsEnvironment.value("PATH", in: inherited) ?? "")
        var seen: Set<String> = []
        let joined = directories.filter { absolute($0) && seen.insert($0.lowercased()).inserted }.joined(separator: ";")
        return WindowsEnvironment.replacing("Path", with: joined, in: inherited)
    }
    static func folderURLs(_ root: URL) -> [URL] {
        ["codex.exe", "app/resources/codex.exe", "resources/codex.exe", "vendor/x86_64-pc-windows-msvc/codex/codex.exe"]
            .map { root.appendingPathComponent($0) } + nativeTargets.map { root.appendingPathComponent($0) }
    }
    static func searchPaths(environment: [String: String], userHome: URL,
                            applicationURLs: [URL]?, systemBinDirectories: [String]) -> [ExecutableSearchPath] {
        var choices: [(URL, String)] = []
        for app in (applicationURLs ?? packageLocations()).prefix(12) {
            choices.append((app.appendingPathComponent("app/resources/codex.exe"), L10n.text("cli.source_app")))
            choices.append((app.appendingPathComponent("resources/codex.exe"), L10n.text("cli.source_app")))
        }
        var directories = pathEntries(WindowsEnvironment.value("PATH", in: environment) ?? "")
        directories += systemBinDirectories.filter(absolute)
        directories += [path(userHome.appendingPathComponent(".local/bin")), path(userHome.appendingPathComponent("AppData/Roaming/npm"))]
        for key in ["APPDATA", "NPM_CONFIG_PREFIX", "NVM_SYMLINK", "PNPM_HOME", "VOLTA_HOME"] {
            if let value = WindowsEnvironment.value(key, in: environment), absolute(value) {
                directories.append(key == "APPDATA" ? path(URL(fileURLWithPath: value).appendingPathComponent("npm")) : value)
            }
        }
        var seenDirectories: Set<String> = []
        for directory in directories.prefix(128) where seenDirectories.insert(directory.lowercased()).inserted {
            let root = URL(fileURLWithPath: directory)
            choices.append((root.appendingPathComponent("codex.exe"), "PATH"))
            choices += nativeTargets.map { (root.appendingPathComponent($0), L10n.text("cli.source_manager")) }
        }
        return choices.map { ExecutableSearchPath(url: $0.0, source: $0.1) }
    }
    private static func pathEntries(_ value: String) -> [String] {
        value.split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }.filter(absolute)
    }
}
#endif
