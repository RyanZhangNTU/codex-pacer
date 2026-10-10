import XCTest
@testable import PacerCore

final class ClaudeRemoteResumeTests: XCTestCase {
    private let session = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    func testCommandRequiresCanonicalUuidAndContainsOnlyEncodedResolverAndSession() throws {
        let value = try XCTUnwrap(ClaudeRemoteResume.command(sessionID: session.uppercased()))
        XCTAssertTrue(value.hasSuffix(" " + session))
        XCTAssertTrue(value.hasPrefix("python3 -u -c 'import base64;exec(base64.b64decode("))
        XCTAssertFalse(value.contains("daemon.token"))
        for rejected in ["", "local_" + session, "../" + session, session + "; touch marker", session + "\n", "--resume"] {
            XCTAssertNil(ClaudeRemoteResume.command(sessionID: rejected))
        }
    }

    func testDesktopCacheResolvesNewestNumericVersionWithoutUsingPathOrServer() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try executable(root, ".claude/remote/ccd-cli/2.1.9-0123456789ab")
        let latest = try executable(root, ".claude/remote/ccd-cli/2.1.293-abcdef012345")
        _ = try executable(root, ".claude/remote/srv/99.0.0/claude-ssh")
        _ = try executable(root, ".claude/remote/ccd-cli/99.0.0-deadbeef0000.zst.part")
        XCTAssertEqual(try resolvedURL(root), latest.resolvingSymlinksInPath())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: latest.path)
        XCTAssertEqual(try resolvedURL(root), old.resolvingSymlinksInPath())
    }

    func testLegacyDesktopAndNativeInstallerLayoutRemainValidAndDirectoryIsNotExecutable() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try executable(root, ".claude/remote/ccd-cli")
        XCTAssertEqual(try resolvedURL(root), legacy.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: legacy)
        let native = try executable(root, ".local/share/claude/versions/2.1.293")
        XCTAssertEqual(try resolvedURL(root), native.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: native)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".local/bin/claude"), withIntermediateDirectories: true)
        XCTAssertEqual(try resolved(root), "")
    }

    func testResumeExecUsesArgumentVectorAndSendsNoPrompt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executable(root, ".claude/remote/ccd-cli/2.1.293-abcdef012345")
        let result = try run(root: root, code: "resolver['resolve_cli'] = lambda: resolver['resolve_cli_original'](user_home=root, path='', system_bin_directories=())\nraise SystemExit(resolver['main']([session]))")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "--resume\n" + session + "\n")
    }

    func testFailureIsStaticAndDoesNotExposeHomeOrSessionPaths() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try run(root: root, code: "resolver['resolve_cli'] = lambda: None\nraise SystemExit(resolver['main']([session]))")
        XCTAssertEqual(missing.status, 127)
        XCTAssertEqual(missing.output, "Claude Code executable not found on this host.\n")
        let invalid = try run(root: root, code: "raise SystemExit(resolver['main']([session+'; echo marker']))")
        XCTAssertEqual(invalid.status, 2)
        XCTAssertEqual(invalid.output, "Invalid Claude Code session.\n")
    }

    private func resolvedURL(_ root: URL) throws -> URL {
        URL(fileURLWithPath: try resolved(root)).resolvingSymlinksInPath()
    }

    private func resolved(_ root: URL) throws -> String {
        let result = try run(root: root, code: "value=resolver['resolve_cli'](user_home=root,path='',system_bin_directories=())\nprint(os.path.realpath(value) if value else '')")
        XCTAssertEqual(result.status, 0)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(root: URL, code: String) throws -> (status: Int32, output: String) {
        let source = try XCTUnwrap(ClaudeRemoteResume.resourceData())
        let bootstrap = "import base64,os\nresolver={'__name__':'pacer_test'}\nexec(base64.b64decode('\(source.base64EncodedString())').decode('utf-8'),resolver)\nresolver['resolve_cli_original']=resolver['resolve_cli']\nroot=base64.b64decode('\(Data(root.path.utf8).base64EncodedString())').decode('utf-8')\nsession='\(session)'\n" + code
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", bootstrap]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func executable(_ root: URL, _ relative: String) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-remote-resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
