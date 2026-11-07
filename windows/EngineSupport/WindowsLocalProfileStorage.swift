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
