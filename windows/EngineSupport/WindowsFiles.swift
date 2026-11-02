#if os(Windows)
import Foundation
import CWindowsSupport

enum WindowsFiles {
    static func wide(_ url: URL) -> [UInt16] { Array(WindowsCodexExecutableDiscovery.path(url).utf16) + [0] }
    static func replace(_ source: URL, with destination: URL) -> Bool {
        let from = Array(source.withUnsafeFileSystemRepresentation { String(cString: $0!) }.utf16) + [0]
        let to = Array(destination.withUnsafeFileSystemRepresentation { String(cString: $0!) }.utf16) + [0]
        return pacer_replace_file(from, to) != 0
    }
}

/// Addresses only Pacer's own Credential Manager item.
struct WindowsCredentialStore: PlatformCredentialStore {
    private let name = Array("CodexPacer/DeepSeek/api-key".utf16) + [0]
    func read() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 2560)
        let count = pacer_read_credential(name, &bytes, bytes.count)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard count > 0 else { return nil }
        return Data(bytes.prefix(Int(count)))
    }
    var exists: Bool { read() != nil }
    func save(_ data: Data) -> Bool {
        var bytes = Array(data)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard !bytes.isEmpty, bytes.count <= 2560 else { return false }
        return pacer_write_credential(name, bytes, bytes.count) != 0
    }
    func remove() { _ = removeChecked() }
    func removeChecked() -> Bool { pacer_remove_credential(name) != 0 }
}

extension DeepSeekAPIKeyStore {
    private static var applicationStore: Self { Self(store: WindowsCredentialStore()) }
    public static func read() -> String? { applicationStore.read() }
    public static var exists: Bool { applicationStore.hasKey }
    @discardableResult public static func save(_ value: String) -> Bool { applicationStore.save(value) }
    @discardableResult public static func remove() -> Bool { WindowsCredentialStore().removeChecked() }
}

public struct WindowsFileSystem: PlatformFileSystem {
    public init() {}
    public func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
        guard url.isFileURL else { return nil }
        var info = pacer_file_metadata()
        guard pacer_read_file_metadata(WindowsFiles.wide(url), followingSymbolicLinks ? 1 : 0, &info) != 0 else { return nil }
        func date(_ ticks: UInt64) -> Date { Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600) }
        return .init(identity: "\(info.volume):\(info.file_low):\(info.file_high)", size: info.size,
            modified: date(info.modified), created: date(info.created), isRegularFile: info.regular != 0, isDirectory: info.directory != 0)
    }
    public func entries(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
    public func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }
    public func replace(_ url: URL, with data: Data) -> Bool {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("." + url.lastPathComponent + "-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            return WindowsFiles.replace(temporary, with: url)
        } catch { return false }
    }
}

extension CompletionDismissalStore {
    public init(fileURL: URL) { self.init(fileURL: fileURL, files: WindowsFileSystem()) }
    public static var applicationDefault: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland", isDirectory: true)
        return Self(fileURL: directory.appendingPathComponent("completion-dismissals-v1.json"))
    }
}

extension DeepSeekSessionReader { init() { self.init(files: WindowsFileSystem()) } }
#endif
