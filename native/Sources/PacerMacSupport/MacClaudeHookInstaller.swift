import Darwin
import Foundation
import PacerCore

public struct MacClaudeHookStorage: ClaudeHookStorage {
    public init() {}
    public func validate(_ url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ClaudeHookInstaller.Failure.unsafePath }
        }
    }
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    public func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    public func read(_ url: URL) throws -> Data {
        // The path may change after validation. Open without waiting for a
        // pipe writer and inspect the open file before reading it.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        return try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
    }
    public func createDirectory(_ url: URL, permissions: UInt16) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(permissions)])
    }
    public func replace(_ url: URL, with data: Data, permissions: UInt16) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: Int(permissions)], ofItemAtPath: url.path)
    }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// Settings an organization manages for Claude Code on this Mac: the managed
/// settings file and its drop-in folder, and the managed preferences domain.
/// They are read only to learn whether they claim Claude's trace exporter.
public enum MacClaudeManagedSettings {
    public static let folder = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
    public static let domain = "com.anthropic.claudecode"
    public static func telemetry(folder: URL = folder, preferences: [URL] = preferenceFiles()) -> ClaudeManagedTelemetry {
        var result = ClaudeManagedTelemetry()
        for url in preferences {
            guard let data = small(url), let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            result.merge(settings: value)
        }
        if let data = small(folder.appendingPathComponent("managed-settings.json")) { result.merge(json: data) }
        let dropIns = folder.appendingPathComponent("managed-settings.d")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().prefix(64)
        for name in names { if let data = small(dropIns.appendingPathComponent(name)) { result.merge(json: data) } }
        return result
    }
    public static func preferenceFiles() -> [URL] {
        let root = URL(fileURLWithPath: "/Library/Managed Preferences")
        let user = NSUserName()
        return (user.isEmpty || user.contains("/") ? [] : [root.appendingPathComponent(user).appendingPathComponent(domain + ".plist")])
            + [root.appendingPathComponent(domain + ".plist")]
    }
    private static func small(_ url: URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= 2 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
}

extension ClaudeHookInstaller {
    private static var mac: Self {
        Self(storage: MacClaudeHookStorage(), python: "python3", serialize: { arguments in
            arguments.enumerated().map { index, argument in
                if index == 0 || argument == "-S" || ((argument == "hook" || argument == "statusline") && index == arguments.count - 2) { return argument }
                return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
        }, managedTelemetry: { MacClaudeManagedSettings.telemetry() })
    }
    public static func status(home: URL) -> Bool { mac.status(home: home) }
    public static func details(home: URL) -> Status { mac.details(home: home) }
    public static func ensureInstalled(home: URL) -> EnsureResult { mac.ensureInstalled(home: home) }
    @discardableResult public static func install(home: URL) throws -> Status { try mac.install(home: home) }
    @discardableResult public static func migrate(home: URL) -> Bool { mac.migrate(home: home) }
    public static func uninstall(home: URL) throws { try mac.uninstall(home: home) }
}
