@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import WinSDK
import XCTest
import CWindowsSupport
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
    func testDirectoryChangeBatchesAreParsedRecordByRecord() {
        // FILE_NOTIFY_INFORMATION: next offset, action, name length in bytes, UTF-16 name.
        func batch(_ records: [(action: UInt32, name: String)], truncatedBy cut: Int = 0) -> [UInt8] {
            var bytes: [UInt8] = []
            for (index, record) in records.enumerated() {
                let name = Array(record.name.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
                let size = (12 + name.count + 3) / 4 * 4
                let next = index == records.count - 1 ? 0 : UInt32(size)
                for value in [next, record.action, UInt32(name.count)] {
                    bytes += [0, 8, 16, 24].map { UInt8((value >> UInt32($0)) & 0xff) }
                }
                bytes += name + Array(repeating: 0, count: size - 12 - name.count)
            }
            return Array(bytes.dropLast(cut))
        }
        func parse(_ bytes: [UInt8], watching name: String?) -> (changed: Int32, flags: Int32) {
            var flags: Int32 = 0
            let changed = bytes.withUnsafeBytes { buffer in
                if let name {
                    return Array(name.utf16 + [0]).withUnsafeBufferPointer {
                        pacer_directory_parse(buffer.baseAddress, UInt32(buffer.count), $0.baseAddress, &flags)
                    }
                }
                return pacer_directory_parse(buffer.baseAddress, UInt32(buffer.count), nil, &flags)
            }
            return (changed, flags)
        }
        let added: UInt32 = 1, removed: UInt32 = 2, modified: UInt32 = 3
        let siblings = (0..<6).map { (action: added, name: "sibling-\($0).log") }
        // A change to the watched file after other records in the same batch.
        XCTAssertTrue(parse(batch(siblings + [(modified, "target.jsonl")]), watching: "target.jsonl") == (1, 0))
        XCTAssertTrue(parse(batch(siblings + [(removed, "TARGET.JSONL")]), watching: "target.jsonl") == (1, 3))
        XCTAssertTrue(parse(batch(siblings), watching: "target.jsonl") == (0, 0), "Siblings are not changes to the file")
        XCTAssertTrue(parse(batch([(modified, "a.jsonl"), (added, "b.jsonl")]), watching: nil) == (1, 2))
        XCTAssertTrue(parse(batch(siblings + [(modified, "target.jsonl")], truncatedBy: 6), watching: "target.jsonl") == (1, 2),
                      "A damaged record asks for discovery")
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
