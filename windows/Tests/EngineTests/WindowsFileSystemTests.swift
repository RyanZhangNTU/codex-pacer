#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PacerCore

final class WindowsFileSystemTests: XCTestCase {
    func testMetadataUsesAStableFullIdentityAndReadsStayBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-file-port-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json"), files = WindowsFileSystem()
        XCTAssertTrue(files.replace(file, with: Data("0123456789".utf8)))
        let first = try XCTUnwrap(files.metadata(file))
        XCTAssertTrue(first.isRegularFile); XCTAssertFalse(first.isDirectory)
        XCTAssertEqual(first.size, 10); XCTAssertNotNil(first.created)
        XCTAssertEqual(first.identity, files.metadata(file)?.identity)
        XCTAssertEqual(try files.read(file, offset: 3, maximumBytes: 4), Data("3456".utf8))
        let directory = try XCTUnwrap(files.metadata(root))
        XCTAssertTrue(directory.isDirectory); XCTAssertFalse(directory.isRegularFile)
        XCTAssertNotEqual(first.identity, directory.identity)
        XCTAssertEqual(try files.entries(in: root).map(\.lastPathComponent), ["state.json"])
    }

    func testAtomicReplacementPreservesOldFileWhenRenameIsDenied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-atomic-port-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target.json"), files = WindowsFileSystem()
        XCTAssertTrue(files.replace(file, with: Data("old".utf8)))
        let handle = CreateFileW(WindowsFiles.wide(file), DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil,
                                 DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        XCTAssertNotEqual(handle, INVALID_HANDLE_VALUE)
        guard let handle, handle != INVALID_HANDLE_VALUE else { return }
        XCTAssertFalse(files.replace(file, with: Data("new".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), Data("old".utf8))
        CloseHandle(handle)
        XCTAssertTrue(files.replace(file, with: Data("new".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        XCTAssertEqual(try files.entries(in: root).map(\.lastPathComponent), ["target.json"], "Failed replacements leave no temporary file")
    }
}
#endif
