import Foundation
import PacerCore
import WinSDK

/// Local provider configuration uses the same ownership and reparse checks for
/// Codex progress registration and Claude hooks.
public struct WindowsLocalProfileStorage: ClaudeHookStorage {
    public init() {}

    public static func wide(_ url: URL) -> [UInt16] {
        let path = url.path.replacingOccurrences(of: "/", with: "\\")
        return Array((path.hasPrefix("\\\\?\\") ? path : "\\\\?\\" + path).utf16) + [0]
    }

    public func validate(_ url: URL) throws { try validate(url, checksOwner: true) }

    func validate(_ url: URL, checksOwner: Bool) throws {
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
        guard checksOwner else { return }
        var descriptor: PSECURITY_DESCRIPTOR?
        var owner: PSID?
        guard GetNamedSecurityInfoW(Self.wide(url), SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION),
            &owner, nil, nil, nil, &descriptor) == DWORD(ERROR_SUCCESS), let owner else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        defer { if let descriptor { _ = LocalFree(descriptor) } }
        try WindowsLocalProfileOwner.validate(owner)
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

/// The plugin owns three files and two directories. Windows keeps the plugin
/// directory locked while it is an MCP process's current working directory.
package struct WindowsProgressPluginStorage: ProgressPluginStorage {
    private let base = WindowsLocalProfileStorage()

    /// The user's profile folder is only the plugin's root, and Windows often
    /// gives it to Administrators or SYSTEM. It must still be a plain folder;
    /// everything Pacer reads or writes below it keeps the owner check.
    private let profile: URL
    package init(profile: URL = FileManager.default.homeDirectoryForCurrentUser) { self.profile = profile.standardizedFileURL }

    package func validate(_ url: URL) throws {
        let isProfile = url.standardizedFileURL.path.trimmingCharacters(in: ["/"])
            .caseInsensitiveCompare(profile.path.trimmingCharacters(in: ["/"])) == .orderedSame
        try base.validate(url, checksOwner: !isProfile)
        guard base.exists(url), !base.isDirectory(url) else { return }
        let file = CreateFileW(WindowsLocalProfileStorage.wide(url), DWORD(FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        guard file != INVALID_HANDLE_VALUE else { throw ClaudeHookInstaller.Failure.unsafePath }
        defer { CloseHandle(file) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(file, &info), info.nNumberOfLinks == 1,
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) == 0 else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
    }
    package func exists(_ url: URL) -> Bool { base.exists(url) }
    package func isDirectory(_ url: URL) -> Bool { base.isDirectory(url) }
    package func isReadable(_ url: URL) -> Bool { base.isReadable(url) }
    package func read(_ url: URL) throws -> Data { try validate(url); return try base.read(url) }
    package func createDirectory(_ url: URL, permissions: UInt16) throws { try base.createDirectory(url, permissions: permissions) }
    package func replace(_ url: URL, with data: Data, permissions: UInt16) throws {
        try validate(url); try base.replace(url, with: data, permissions: permissions)
    }
    package func names(in directory: URL) throws -> Set<String> {
        try validate(directory)
        return try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
    package func remove(_ url: URL) throws {
        try validate(url)
        guard DeleteFileW(WindowsLocalProfileStorage.wide(url)) else { throw removalError(directory: false) }
    }
    package func removeEmptyDirectory(_ url: URL) throws {
        try validate(url)
        guard RemoveDirectoryW(WindowsLocalProfileStorage.wide(url)) else { throw removalError(directory: true) }
    }
    private func removalError(directory: Bool) -> any Error {
        let code = GetLastError()
        if code == ERROR_SHARING_VIOLATION || code == ERROR_LOCK_VIOLATION || (directory && code == ERROR_ACCESS_DENIED) {
            return ProgressPluginRemovalError.inUse
        }
        return CocoaError(.fileWriteUnknown)
    }
}
