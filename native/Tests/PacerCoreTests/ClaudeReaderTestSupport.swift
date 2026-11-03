import Foundation
@testable import PacerCore

/// Filesystem fixtures use this adapter; observation tests inject controlled
/// identities, creation dates and byte-read counters.
extension ClaudeActivityReader {
    init() { self.init(files: ClaudeReaderTestFileSystem()) }
}

private struct ClaudeReaderTestFileSystem: PlatformFileSystem {
    func entries(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
        #if canImport(PacerMacSupport)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return .init(identity: "\(device):\(inode)", size: size,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            created: attributes[.creationDate] as? Date,
            isRegularFile: attributes[.type] as? FileAttributeType == .typeRegular)
        #else
        return TestFileSystem().metadata(url, followingSymbolicLinks: followingSymbolicLinks)
        #endif
    }
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }
    func replace(_ url: URL, with data: Data) -> Bool { false }
}
