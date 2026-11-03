import Foundation
import PacerCore
import WinSDK

/// Windows supplies filesystem access. Configuration ownership and restoration
/// remain in the shared ClaudeHookInstaller.
public struct WindowsClaudeHookStorage: ClaudeHookStorage {
    public init() {}
    private static func wide(_ url: URL) -> [UInt16] {
        Array(url.path.replacingOccurrences(of: "/", with: "\\").utf16) + [0]
    }
    public func validate(_ url: URL) throws {
        guard url.isFileURL, url.path.utf16.count < 32760,
              url.path.dropFirst().hasPrefix(":/"), !url.path.contains("\0") else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        var current = url.standardizedFileURL
        while current.path.count > 3 {
            let attributes = GetFileAttributesW(Self.wide(current))
            if attributes != INVALID_FILE_ATTRIBUTES && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
                throw ClaudeHookInstaller.Failure.unsafePath
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }; current = parent
        }
        let attributes = GetFileAttributesW(Self.wide(url))
        if attributes == INVALID_FILE_ATTRIBUTES {
            let error = GetLastError()
            if error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND { return }
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        var descriptor: PSECURITY_DESCRIPTOR?
        var owner: PSID?
        guard GetNamedSecurityInfoW(Self.wide(url), SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION),
            &owner, nil, nil, nil, &descriptor) == DWORD(ERROR_SUCCESS), let owner else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        defer { if let descriptor { _ = LocalFree(descriptor) } }
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        defer { _ = CloseHandle(token) }
        func matches(_ kind: TOKEN_INFORMATION_CLASS, defaultOwner: Bool) -> Bool {
            var size: DWORD = 0
            _ = GetTokenInformation(token, kind, nil, 0, &size)
            guard size > 0, size <= 65536 else { return false }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
            defer { buffer.deallocate() }
            guard GetTokenInformation(token, kind, buffer, size, &size) else { return false }
            let sid = defaultOwner ? buffer.assumingMemoryBound(to: TOKEN_OWNER.self).pointee.Owner
                : buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid
            return EqualSid(owner, sid)
        }
        // Windows can assign the token's default owner group to files this
        // process creates (notably on hosted CI), rather than TokenUser.
        guard matches(TokenUser, defaultOwner: false) || matches(TokenOwner, defaultOwner: true) else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
    }
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func isDirectory(_ url: URL) -> Bool {
        WindowsFileSystem().metadata(url, followingSymbolicLinks: false)?.isDirectory == true
    }
    public func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    public func read(_ url: URL) throws -> Data {
        try validate(url)
        return try WindowsFileSystem().read(url, offset: 0, maximumBytes: 2 * 1024 * 1024 + 1)
    }
    public func createDirectory(_ url: URL, permissions: UInt16) throws {
        try validate(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func replace(_ url: URL, with data: Data, permissions: UInt16) throws {
        try validate(url)
        guard WindowsFileSystem().replace(url, with: data) else { throw ClaudeHookInstaller.Failure.invalidSettings }
    }
    public func remove(_ url: URL) throws { try validate(url); try FileManager.default.removeItem(at: url) }
}

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
            ? UninstallCheckStorage(base: WindowsClaudeHookStorage()) : WindowsClaudeHookStorage()
        let manifest = home.appendingPathComponent("pacer/installation.json")
        try storage.validate(home); try storage.validate(manifest)
        guard storage.exists(manifest) else { return }
        try installer(storage: storage).uninstall(home: home)
        guard !storage.exists(manifest) else { throw ClaudeHookInstaller.Failure.changedSettings }
    }
}

/// Run the shared ownership/JSON checks without changing provider files. A
/// failed preflight lets the uninstaller offer Cancel before any cleanup.
private final class UninstallCheckStorage: ClaudeHookStorage, @unchecked Sendable {
    private let base: any ClaudeHookStorage
    // One synchronous installer owns this adapter; it is never shared.
    private var removed = Set<URL>()
    init(base: any ClaudeHookStorage) { self.base = base }
    func validate(_ url: URL) throws { try base.validate(url) }
    func exists(_ url: URL) -> Bool { !removed.contains(url) && base.exists(url) }
    func isDirectory(_ url: URL) -> Bool { base.isDirectory(url) }
    func isReadable(_ url: URL) -> Bool { base.isReadable(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL, permissions: UInt16) throws { throw ClaudeHookInstaller.Failure.unsafePath }
    func replace(_ url: URL, with data: Data, permissions: UInt16) throws { try base.validate(url) }
    func remove(_ url: URL) throws { try base.validate(url); removed.insert(url) }
}
