import Foundation
import CryptoKit
import PacerCore
import WinSDK

public struct WindowsPythonPin: Decodable, Sendable {
    public let version: String, architecture: String, url: String, sha256: String, signer: String
    public var identifier: String { version + "-" + sha256.prefix(12) }
    public static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "python-runtime-lock", withExtension: "json") else { throw ClaudeHookInstaller.Failure.invalidSettings }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

/// One current-user cache shared by every Claude home. Configuration changes
/// stay in ClaudeHookInstaller; this type only manages owned runtime files.
public struct WindowsClaudeRuntimeStore {
    public enum Failure: Error { case invalidRuntime, unsafeRuntime, referenced, busy }
    private struct RuntimeFile: Codable { let name: String, sha256: String, bytes: Int }
    private struct Package: Decodable { let schemaVersion: Int; let version, architecture, archiveSHA256: String; let files: [RuntimeFile] }
    private struct RootClaim: Codable {
        var schemaVersion = 1, owner = "CodexPacer"
        var homes: [String] = []
    }
    private struct VersionClaim: Codable {
        var schemaVersion = 1, owner = "CodexPacer"
        let version, archiveSHA256: String
        let files: [RuntimeFile]
    }
    private static let marker = ".pacer-owned.json"
    public let root: URL
    private let storage = WindowsClaudeHookStorage()
    public init(root: URL) { self.root = root.standardizedFileURL }
    public static var defaultRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        let local = environment.first { $0.key.caseInsensitiveCompare("LOCALAPPDATA") == .orderedSame }?.value
        let base = local.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return base.appendingPathComponent("CodexPacer/ClaudeRuntime", isDirectory: true)
    }
    static func wide(_ url: URL) -> [UInt16] { WindowsClaudeHookStorage.wide(url) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}-[0-9a-f]{12}\z"#, options: .regularExpression) != nil
    }
    public func withLock<T>(_ action: () throws -> T) throws -> T {
        guard root.lastPathComponent.caseInsensitiveCompare("ClaudeRuntime") == .orderedSame else { throw Failure.unsafeRuntime }
        let name = "Global\\CodexPacer.ClaudeRuntime." + Self.digest(Data(root.path.lowercased().utf8))
        guard let mutex = CreateMutexW(nil, false, Array(name.utf16) + [0]) else { throw Failure.busy }
        defer { _ = CloseHandle(mutex) }
        let state = WaitForSingleObject(mutex, 2000)
        guard state == WAIT_OBJECT_0 || state == DWORD(0x80) /* WAIT_ABANDONED_0 */ else { throw Failure.busy }
        defer { _ = ReleaseMutex(mutex) }
        return try action()
    }
    public func python(identifier: String) -> URL { root.appendingPathComponent(identifier + "/python.exe") }
    private func entries(_ url: URL) throws -> [URL] {
        try storage.validate(url)
        guard storage.isDirectory(url) else { throw Failure.unsafeRuntime }
        let values = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard values.count <= 256 else { throw Failure.invalidRuntime }
        return values
    }
    private func createDirectory(_ url: URL) throws {
        try storage.validate(url)
        if storage.exists(url) {
            guard storage.isDirectory(url) else { throw Failure.unsafeRuntime }; return
        }
        let parent = url.deletingLastPathComponent()
        guard parent != url else { throw Failure.unsafeRuntime }
        try createDirectory(parent)
        try storage.createDirectory(url, permissions: 0o700)
        try storage.validate(url)
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try storage.validate(url)
        let data = try storage.read(url)
        guard data.count <= 2 * 1024 * 1024 else { throw Failure.invalidRuntime }
        return try JSONDecoder().decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try storage.validate(url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try storage.replace(url, with: encoder.encode(value), permissions: 0o600)
    }
    private func claim() throws -> RootClaim {
        let value = try read(RootClaim.self, root.appendingPathComponent(Self.marker))
        guard value.schemaVersion == 1, value.owner == "CodexPacer", value.homes.count <= 128,
              value.homes.allSatisfy({ $0.utf16.count < 16000 && $0.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw Failure.unsafeRuntime }
        return value
    }
    public func homes(including extra: [URL]) throws -> [URL] {
        var values = extra
        if storage.exists(root) { values += try claim().homes.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        var seen = Set<String>()
        return values.map(\.standardizedFileURL).filter { seen.insert($0.path.lowercased()).inserted }
    }
    /// Claim before copying, so interruption leaves a repairable owned cache.
    /// Only a verified official package is copied; unknown files are preserved.
    public func ensure(package source: URL, home: URL) throws -> URL {
        try storage.validate(home)
        guard storage.isDirectory(home) else { throw Failure.unsafeRuntime }
        let pin = try WindowsPythonPin.load()
        let package = try read(Package.self, source.appendingPathComponent("pacer-runtime.json"))
        guard package.schemaVersion == 1, package.version == pin.version, package.architecture == pin.architecture,
              package.archiveSHA256 == pin.sha256, package.files.count <= 128,
              Set(package.files.map(\.name)).count == package.files.count,
              package.files.contains(where: { $0.name == "python.exe" }), package.files.contains(where: { $0.name == "LICENSE.txt" }) else { throw Failure.invalidRuntime }
        var bytes: [(RuntimeFile, Data)] = []
        for file in package.files {
            try validate(file)
            let url = source.appendingPathComponent(file.name); try storage.validate(url)
            let data = try WindowsFileSystem().read(url, offset: 0, maximumBytes: file.bytes + 1)
            guard data.count == file.bytes, Self.digest(data) == file.sha256 else { throw Failure.invalidRuntime }
            bytes.append((file, data))
        }
        try createDirectory(root)
        let marker = root.appendingPathComponent(Self.marker)
        var record: RootClaim
        if storage.exists(marker) { record = try claim() }
        else {
            guard try entries(root).isEmpty else { throw Failure.unsafeRuntime }
            record = RootClaim()
        }
        let path = home.standardizedFileURL.path
        if !record.homes.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) { record.homes.append(path) }
        guard record.homes.count <= 128 else { throw Failure.invalidRuntime }
        try write(record, marker)
        let directory = root.appendingPathComponent(pin.identifier, isDirectory: true)
        try createDirectory(directory)
        let versionMarker = directory.appendingPathComponent(Self.marker)
        if storage.exists(versionMarker) {
            let prior = try versionClaim(directory)
            guard prior.archiveSHA256 == pin.sha256 else { throw Failure.unsafeRuntime }
        } else { guard try entries(directory).isEmpty else { throw Failure.unsafeRuntime } }
        try write(VersionClaim(version: pin.version, archiveSHA256: pin.sha256, files: package.files), versionMarker)
        let expected = Set(package.files.map(\.name) + [Self.marker])
        guard try entries(directory).allSatisfy({ expected.contains($0.lastPathComponent) }) else { throw Failure.unsafeRuntime }
        for (file, data) in bytes {
            let target = directory.appendingPathComponent(file.name); try storage.validate(target)
            if storage.exists(target), let old = try? WindowsFileSystem().read(target, offset: 0, maximumBytes: file.bytes + 1), old == data { continue }
            try storage.replace(target, with: data, permissions: 0o700)
        }
        return python(identifier: pin.identifier)
    }
    private func validate(_ file: RuntimeFile) throws {
        guard !file.name.isEmpty, file.name.utf16.count < 200, file.name.last != ".", file.name.last != " ",
              !file.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              file.name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\"<>|?*")) == nil,
              file.name != Self.marker, file.bytes >= 0, file.bytes <= 16 * 1024 * 1024,
              file.sha256.range(of: #"^[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { throw Failure.invalidRuntime }
    }
    private func versionClaim(_ directory: URL) throws -> VersionClaim {
        let value = try read(VersionClaim.self, directory.appendingPathComponent(Self.marker))
        guard value.schemaVersion == 1, value.owner == "CodexPacer", value.files.count <= 128,
              Set(value.files.map(\.name)).count == value.files.count,
              directory.lastPathComponent == value.version + "-" + value.archiveSHA256.prefix(12),
              value.archiveSHA256.range(of: #"^[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { throw Failure.unsafeRuntime }
        for file in value.files { try validate(file) }
        return value
    }
    private func references(homes: [URL], using config: any ClaudeHookStorage) throws -> [String] {
        var strings: [String] = [], total = 0
        for home in homes {
            for relative in ["settings.json", "pacer/installation.json"] {
                let file = home.appendingPathComponent(relative)
                try config.validate(file)
                guard config.exists(file) else { continue }
                let data = try config.read(file); total += data.count
                guard data.count <= 2 * 1024 * 1024, total <= 64 * 1024 * 1024,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.referenced }
                var pending: [Any] = [object]
                while let value = pending.popLast() {
                    if let text = value as? String { strings.append(text.lowercased()) }
                    else if let dictionary = value as? [String: Any] { pending += Array(dictionary.values) }
                    else if let array = value as? [Any] { pending += array }
                }
            }
        }
        return strings
    }
    /// Preflight validates the entire deletion plan before any file is removed.
    /// Both unchanged user references and saved status-line renderers protect a
    /// version. Unreadable or invalid configurations cannot prove it unused.
    public func collect(keeping current: String? = nil, extraHomes: [URL] = [], configurations: any ClaudeHookStorage = WindowsClaudeHookStorage(),
                        requireEmpty: Bool = false, checkOnly: Bool = false) throws {
        guard storage.exists(root) else { return }
        _ = try claim()
        let uses = try references(homes: homes(including: extraHomes), using: configurations)
        var plan: [(URL, VersionClaim)] = [], retained = false
        for directory in try entries(root) where directory.lastPathComponent != Self.marker {
            let identifier = directory.lastPathComponent
            guard Self.validIdentifier(identifier) else { throw Failure.unsafeRuntime }
            if identifier == current || uses.contains(where: { $0.contains(identifier) }) { retained = true; continue }
            let version = try versionClaim(directory)
            let expected = Set(version.files.map(\.name) + [Self.marker])
            guard try entries(directory).allSatisfy({ expected.contains($0.lastPathComponent) }) else { throw Failure.unsafeRuntime }
            for file in version.files {
                let url = directory.appendingPathComponent(file.name); try storage.validate(url)
                guard storage.exists(url) else { continue } // Retry after interrupted cleanup.
                let data = try WindowsFileSystem().read(url, offset: 0, maximumBytes: file.bytes + 1)
                guard data.count == file.bytes, Self.digest(data) == file.sha256 else { throw Failure.unsafeRuntime }
                let handle = CreateFileW(Self.wide(url), DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
                guard let handle, handle != INVALID_HANDLE_VALUE else { throw Failure.busy }
                _ = CloseHandle(handle)
            }
            plan.append((directory, version))
        }
        if requireEmpty && retained { throw Failure.referenced }
        guard !checkOnly else { return }
        for (directory, version) in plan {
            for name in version.files.map(\.name) + [Self.marker] {
                let file = directory.appendingPathComponent(name); try storage.validate(file)
                if storage.exists(file), !DeleteFileW(Self.wide(file)) { throw Failure.busy }
            }
            try storage.validate(directory)
            guard RemoveDirectoryW(Self.wide(directory)) else { throw Failure.busy }
        }
        if try entries(root).allSatisfy({ $0.lastPathComponent == Self.marker }) {
            let marker = root.appendingPathComponent(Self.marker); try storage.validate(marker)
            guard DeleteFileW(Self.wide(marker)) else { throw Failure.busy }
            try storage.validate(root)
            guard RemoveDirectoryW(Self.wide(root)) else { throw Failure.busy }
        }
    }
}
