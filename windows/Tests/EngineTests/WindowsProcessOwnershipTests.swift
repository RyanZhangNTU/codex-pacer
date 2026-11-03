@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsProcessOwnershipTests: XCTestCase {
    private final class Holder {
        let root: URL, file: URL, ready: URL
        let process = Process()
        init(_ mode: String, contents: String = "synthetic log\n") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-owner-中文 " + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("rollout-fixture.jsonl"); ready = root.appendingPathComponent("ready")
            try Data(contents.utf8).write(to: file)
            process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_DESKTOP_PIPE_FIXTURE"]))
            process.arguments = [mode, WindowsCodexExecutableDiscovery.path(file), WindowsCodexExecutableDiscovery.path(ready)]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { try? FileManager.default.removeItem(at: root); throw error }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard FileManager.default.fileExists(atPath: ready.path) else { stop(); throw WindowsDesktopTransport.Failure.unavailable }
        }
        var pid: UInt32 { UInt32(process.processIdentifier) }
        func stop() { if process.isRunning { process.terminate() }; process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
    }
    func testOnlyWritableHandlesEstablishOwnership() throws {
        for mode in ["file-read", "file-write", "file-append"] {
            let holder = try Holder(mode); defer { holder.stop() }
            let original = try Data(contentsOf: holder.file)
            let writers = try XCTUnwrap(WindowsProcessOwnership.writers(of: holder.file))
            let process = try XCTUnwrap(WindowsProcessOwnership.inspect(holder.pid))
            XCTAssertEqual(writers.contains(process.identity), mode != "file-read")
            XCTAssertEqual(try Data(contentsOf: holder.file), original, "Ownership inspection cannot change the source")
        }
    }
    func testSameFilenameAndAnAtomicReplacementDoNotInheritTheOldWriter() throws {
        let holder = try Holder("file-write"); defer { holder.stop() }
        let identity = try XCTUnwrap(WindowsProcessOwnership.inspect(holder.pid)).identity
        XCTAssertTrue(try XCTUnwrap(WindowsProcessOwnership.writers(of: holder.file)).contains(identity))
        XCTAssertTrue(try XCTUnwrap(WindowsProcessOwnership.writers(of: holder.file, within: holder.root)).contains(identity))
        XCTAssertNil(WindowsProcessOwnership.writers(of: holder.file, within: URL(fileURLWithPath: WindowsCodexExecutableDiscovery.path(holder.root) + "-other")))
        let other = holder.root.appendingPathComponent("elsewhere/rollout-fixture.jsonl")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("same name, different file\n".utf8).write(to: other)
        XCTAssertFalse(try XCTUnwrap(WindowsProcessOwnership.writers(of: other)).contains(identity))
        try FileManager.default.removeItem(at: holder.file); try Data("replacement\n".utf8).write(to: holder.file)
        XCTAssertFalse(try XCTUnwrap(WindowsProcessOwnership.writers(of: holder.file)).contains(identity), "An old open file must not bind its replacement")
    }
    func testProcessInstanceAndParentAreValidatedWithoutCommandLines() throws {
        let holder = try Holder("file-write"); defer { holder.stop() }
        let child = try XCTUnwrap(WindowsProcessOwnership.inspect(holder.pid))
        let parent = try XCTUnwrap(WindowsProcessOwnership.inspect(UInt32(ProcessInfo.processInfo.processIdentifier)))
        XCTAssertEqual(child.parent, parent.identity.pid)
        XCTAssertTrue(WindowsProcessOwnership.isDescendant(child.identity, of: parent.identity))
        XCTAssertNil(WindowsProcessOwnership.inspect(child.identity.pid, started: child.identity.started + 1))
        XCTAssertFalse(WindowsProcessOwnership.isDescendant(.init(pid: child.identity.pid, started: child.identity.started + 1), of: parent.identity))
        XCTAssertFalse(WindowsProcessOwnership.isDescendant(child.identity, of: .init(pid: parent.identity.pid, started: parent.identity.started + 1)))
    }
    func testAncestryRejectsCyclesParentPidReuseAndAnExitedChild() {
        let child = WindowsProcessIdentity(pid: 10, started: 100), ancestor = WindowsProcessIdentity(pid: 20, started: 50)
        let executable = URL(fileURLWithPath: "C:/fixture/app.exe")
        var rows: [UInt32: WindowsProcessRecord] = [10: .init(identity: child, parent: 20, executable: executable),
            20: .init(identity: ancestor, parent: 0, executable: executable)]
        let lookup: WindowsProcessOwnership.Lookup = { pid, started in rows[pid].flatMap { started == 0 || $0.identity.started == started ? $0 : nil } }
        XCTAssertTrue(WindowsProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
        rows[20] = .init(identity: .init(pid: 20, started: 150), parent: 0, executable: executable)
        XCTAssertFalse(WindowsProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
        rows[10] = .init(identity: child, parent: 10, executable: executable)
        XCTAssertFalse(WindowsProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
        rows.removeValue(forKey: 10)
        XCTAssertFalse(WindowsProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
    }
    func testSourceBindingRequiresTheSelectedFileWriterAndTheVerifiedPeerTree() throws {
        let thread = "019a0000-0000-7000-8000-000000000001"
        let holder = try Holder("file-write", contents: "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\",\"originator\":\"Codex Desktop\",\"cwd\":\"C:/synthetic\"}}\n")
        defer { holder.stop() }
        let peer = try XCTUnwrap(WindowsProcessOwnership.inspect(UInt32(ProcessInfo.processInfo.processIdentifier))).identity
        let row = CodexRolloutMetadata(origin: .init(embedded: false, ignored: false), url: holder.file, observedAt: nil, parentThreadID: nil)
        let binding = WindowsDesktopSourceBinding(home: holder.root, peer: peer, metadata: { $0 == thread ? row : nil })
        let proof = try XCTUnwrap(binding.authorize(thread))
        XCTAssertEqual(proof.writer.pid, holder.pid); XCTAssertTrue(binding.isCurrent(proof))
        let other = holder.root.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNil(WindowsDesktopSourceBinding(home: other, peer: peer, metadata: { _ in row }).authorize(thread),
            "A metadata UUID cannot bind a file outside the selected physical home")
        let different = WindowsProcessIdentity(pid: peer.pid, started: peer.started + 1)
        XCTAssertNil(WindowsDesktopSourceBinding(home: holder.root, peer: different, metadata: { _ in row }).authorize(thread))
        let ignored = CodexRolloutMetadata(origin: .init(embedded: true, ignored: true), url: holder.file, observedAt: nil, parentThreadID: nil)
        XCTAssertNil(WindowsDesktopSourceBinding(home: holder.root, peer: peer, metadata: { _ in ignored }).authorize(thread))
        XCTAssertNil(binding.authorize("not-a-thread"))
        try FileManager.default.removeItem(at: holder.file); try Data("replacement\n".utf8).write(to: holder.file)
        XCTAssertFalse(binding.isCurrent(proof), "Replacing the selected file invalidates its original writer proof")
    }
    func testMissingDirectoriesAndRemoteFilesCannotEstablishOwnership() throws {
        XCTAssertNil(WindowsProcessOwnership.writers(of: FileManager.default.temporaryDirectory))
        XCTAssertNil(WindowsProcessOwnership.writers(of: URL(fileURLWithPath: #"\\untrusted.invalid\share\rollout.jsonl"#)))
        XCTAssertNil(WindowsProcessOwnership.writers(of: URL(string: "https://untrusted.invalid/rollout.jsonl")!))
        XCTAssertNil(WindowsProcessOwnership.inspect(0))
    }
}
#endif
