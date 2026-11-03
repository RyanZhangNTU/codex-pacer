import Foundation
import PacerMacSupport
import XCTest
@testable import PacerCore

final class MacFileSystemTests: XCTestCase {
    private func fixture() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-files-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testMetadataDescribesTheLinkUnlessFollowingIsRequested() throws {
        let directory = fixture(), files = MacFileSystem()
        let target = directory.appendingPathComponent("target.json"), link = directory.appendingPathComponent("auth.json")
        XCTAssertTrue(files.replace(target, with: Data("synthetic".utf8)))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let entry = try XCTUnwrap(files.metadata(link)), destination = try XCTUnwrap(files.metadata(target))
        XCTAssertFalse(entry.isRegularFile)
        XCTAssertNotEqual(entry.identity, destination.identity)
        XCTAssertEqual(files.metadata(link, followingSymbolicLinks: true), destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(entry.size, (attributes[.size] as? NSNumber)?.uint64Value)
        let created = try XCTUnwrap(link.resourceValues(forKeys: [.creationDateKey]).creationDate)
        XCTAssertEqual(try XCTUnwrap(entry.created).timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)

        let fingerprint = CodexClient.authenticationFingerprint(home: directory, files: files)
        try Data("a longer synthetic destination".utf8).write(to: target)
        XCTAssertEqual(CodexClient.authenticationFingerprint(home: directory, files: files), fingerprint,
            "Authentication metadata describes the link, as attributesOfItem does")
        try FileManager.default.removeItem(at: target)
        XCTAssertNotNil(files.metadata(link), "A dangling link still has directory-entry metadata")
        XCTAssertNil(files.metadata(link, followingSymbolicLinks: true))
    }

    func testReplacementKeepsPrivatePermissionsAndCleansUpAfterRenameFailure() throws {
        let directory = fixture(), files = MacFileSystem(), original = Data("previous synthetic value".utf8)
        let target = directory.appendingPathComponent("settings.json")
        XCTAssertTrue(files.replace(target, with: original))
        XCTAssertEqual(try Data(contentsOf: target), original)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        XCTAssertTrue(files.replace(target, with: Data("next synthetic value".utf8)))
        XCTAssertEqual(try Data(contentsOf: target), Data("next synthetic value".utf8))

        let blocked = directory.appendingPathComponent("blocked.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let preserved = blocked.appendingPathComponent("previous.json")
        try original.write(to: preserved)
        XCTAssertFalse(files.replace(blocked, with: Data("replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: preserved), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["settings.json", "blocked.json"])
    }
}
