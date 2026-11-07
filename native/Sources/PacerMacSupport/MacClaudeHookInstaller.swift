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

extension ClaudeHookInstaller {
    private static var mac: Self {
        Self(storage: MacClaudeHookStorage(), python: "python3", serialize: { arguments in
            arguments.enumerated().map { index, argument in
                if index == 0 || argument == "-S" || ((argument == "hook" || argument == "statusline") && index == arguments.count - 2) { return argument }
                return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
        })
    }
    public static func status(home: URL) -> Bool { mac.status(home: home) }
    public static func details(home: URL) -> Status { mac.details(home: home) }
    public static func ensureInstalled(home: URL) -> EnsureResult { mac.ensureInstalled(home: home) }
    @discardableResult public static func install(home: URL) throws -> Status { try mac.install(home: home) }
    @discardableResult public static func migrate(home: URL) -> Bool { mac.migrate(home: home) }
    public static func uninstall(home: URL) throws { try mac.uninstall(home: home) }
}
