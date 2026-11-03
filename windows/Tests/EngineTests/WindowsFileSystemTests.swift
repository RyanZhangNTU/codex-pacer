@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PacerCore

final class WindowsFileSystemTests: XCTestCase {
    func testProviderLogsBeyondMaxPathAreDiscoveredReadAndWatched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-long-path-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = WindowsFileSystem()
        for provider in ["claude", "codex", "deepseek"] {
            // Claude encodes the whole project path in one directory component.
            // Keep each component below NTFS's limit while exceeding MAX_PATH.
            let directory = root.appendingPathComponent(provider).appendingPathComponent("C--synthetic-" + String(repeating: "project-", count: 27) + "中文")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("11111111-2222-4333-8444-555555555555.jsonl")
            let initial = Data("{\"type\":\"synthetic\"}\n".utf8)
            try initial.write(to: file)
            XCTAssertGreaterThan(WindowsCodexExecutableDiscovery.path(file).utf16.count, 260)
            XCTAssertNotNil(files.metadata(file), provider + " metadata must not disappear beyond MAX_PATH")
            XCTAssertEqual(try files.entries(in: directory), [file], provider + " discovery keeps canonical URLs")
            XCTAssertEqual(try files.read(file, offset: 0, maximumBytes: 4096), initial)
            let changed = expectation(description: provider + " append wakes a long-path watch")
            changed.assertForOverFulfill = false
            let watch = WindowsActivityLogWatcher().watch(file, isDirectory: false) { _ in changed.fulfill() }
            XCTAssertNotNil(watch, provider + " native watch must open the long directory")
            guard let watch else { changed.fulfill(); await fulfillment(of: [changed], timeout: 0.1); continue }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: WindowsFiles.extendedPath(WindowsCodexExecutableDiscovery.path(file))))
            try handle.seekToEnd(); try handle.write(contentsOf: Data("appended\n".utf8)); try handle.close()
            await fulfillment(of: [changed], timeout: 3)
            watch.stop()
            XCTAssertEqual(try files.read(file, offset: UInt64(initial.count), maximumBytes: 8), Data("appended".utf8))
        }
    }
    func testExtendedPathsPreserveUnicodeAndUNCWithoutChangingCanonicalURLs() {
        XCTAssertEqual(WindowsFiles.extendedPath("C:/synthetic/中文/file.jsonl"), "\\\\?\\C:\\synthetic\\中文\\file.jsonl")
        XCTAssertEqual(WindowsFiles.extendedPath("\\\\server\\share\\file"), "\\\\?\\UNC\\server\\share\\file")
        XCTAssertEqual(WindowsFiles.extendedPath("\\\\?\\C:\\synthetic\\file"), "\\\\?\\C:\\synthetic\\file")
        XCTAssertEqual(WindowsFiles.extendedPath("relative/file"), "relative\\file")
    }
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
