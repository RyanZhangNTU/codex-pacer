import PacerMacSupport
import XCTest
@testable import PacerCore

final class ClaudeApplicationResolverMacTests: XCTestCase {
    func testBundleIdentityAndRelocatedApplicationDetection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, identifier: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let wrong = try app("Claude", identifier: "test.unrelated"), moved = try app("Relocated Claude", identifier: ClaudeApplicationResolver.bundleIdentifier)
        XCTAssertEqual(ClaudeApplicationResolver.find(applicationURLs: [wrong, moved]), moved)
        XCTAssertNil(ClaudeApplicationResolver.find(applicationURLs: [wrong]))
    }

    func testBundledCliFindsNewestNumericVersionAndFallsBackToUserInstallation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        func executable(_ relative: String) throws -> URL {
            let path = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path
        }
        let older = try executable("Library/Application Support/Claude/claude-code/2.1.9/hash/claude.app/Contents/MacOS/claude")
        let newest = try executable("Library/Application Support/Claude/claude-code/2.1.293/hash/claude.app/Contents/MacOS/claude")
        let user = try executable(".local/bin/claude")
        XCTAssertEqual(ClaudeApplicationResolver.findExecutable(userHome: root, environment: [:], applicationURLs: [], systemBinDirectories: [])?.resolvingSymlinksInPath(), newest.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: newest)
        XCTAssertEqual(ClaudeApplicationResolver.findExecutable(userHome: root, environment: [:], applicationURLs: [], systemBinDirectories: [])?.resolvingSymlinksInPath(), older.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: older)
        XCTAssertEqual(ClaudeApplicationResolver.findExecutable(userHome: root, environment: [:], applicationURLs: [], systemBinDirectories: [])?.resolvingSymlinksInPath(), user.resolvingSymlinksInPath())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: user.path)
        XCTAssertNil(ClaudeApplicationResolver.findExecutable(userHome: root, environment: ["PATH": "relative/bin"], applicationURLs: [], systemBinDirectories: []))
    }




    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-resolver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
