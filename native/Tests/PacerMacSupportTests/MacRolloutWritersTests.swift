import Darwin
import XCTest
import PacerCore
import PacerMacSupport

/// The Mac's answer to "does any process still write this rollout?", on real files
/// held by this test process.
final class MacRolloutWritersTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file() throws -> URL {
        let url = try temporaryFolder().appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: url)
        return url
    }
    private func probe(_ url: URL) -> Bool? { MacRolloutWriters.probe(url, url.deletingLastPathComponent()) }

    func testOnlyAnOpenWriteHandleCountsAsAWriter() throws {
        let url = try file()
        XCTAssertEqual(probe(url), false, "No process holds it")

        let reader = try FileHandle(forReadingFrom: url)
        XCTAssertEqual(probe(url), false, "A reader, such as Pacer itself, is not a writer")

        let writer = try FileHandle(forWritingTo: url)
        XCTAssertEqual(probe(url), true)
        try writer.close()
        XCTAssertEqual(probe(url), false, "The writer closed it")

        let updater = try FileHandle(forUpdating: url)
        XCTAssertEqual(probe(url), true, "Codex holds its rollouts open for reading and writing")
        try updater.close(); try reader.close()
    }

    func testAMissingFileIsUnknown() throws {
        let url = try file()
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(probe(url), "Nothing can be said about a file that is gone")
    }

    /// A process with no open files lists none rather than failing, and an
    /// exited, unreaped child answers as gone; neither leaves the answer unknown.
    func testProcessesWithNoFilesOrNoLifeStillGiveAnAnswer() throws {
        let url = try file()
        // Close every descriptor in the child, so it starts with no open files at all.
        func spawn(_ arguments: [String]) -> pid_t {
            var pid: pid_t = 0, attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            XCTAssertEqual(posix_spawn(&pid, arguments[0], nil, &attributes, argv, environ), 0)
            return pid
        }
        let bare = spawn(["/bin/sleep", "30"])
        let zombie = spawn(["/usr/bin/true"])
        defer {
            kill(bare, SIGKILL)
            var status: Int32 = 0; waitpid(bare, &status, 0); waitpid(zombie, &status, 0)
        }
        usleep(500_000)
        XCTAssertEqual(probe(url), false)
    }

    /// The reader with the Mac's own probe: Codex holds a loaded thread's rollout
    /// open for reading and writing, and a quiet turn runs while it does.
    func testAQuietTurnRunsWhileItsRolloutIsHeldForWriting() async throws {
        let home = try temporaryFolder(), start = Date().addingTimeInterval(-3600)
        let thread = "019a0000-0000-7000-8000-000000000044"
        let folder = home.appendingPathComponent("sessions/2026/11/21", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rollout = folder.appendingPathComponent("rollout-2026-11-21T10-00-00-\(thread).jsonl")
        let stamp = ISO8601DateFormatter().string(from: start)
        func record(_ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": stamp, "payload": payload]) + Data([10])
        }
        try (record("session_meta", ["id": thread, "originator": "Codex Desktop", "cwd": "/fixture"])
            + record("event_msg", ["type": "task_started", "turn_id": "t1"])).write(to: rollout)
        // The hook row that names the rollout, as Codex's UserPromptSubmit writes it.
        let row: [String: Any] = ["v": 1, "hook": 1, "at": start.timeIntervalSince1970, "event": "UserPromptSubmit", "thread": thread,
                                  "turn": "t1", "agent": NSNull(), "agentType": NSNull(), "transcript": rollout.path,
                                  "agentTranscript": NSNull(), "approval": NSNull(), "reason": NSNull()]
        try FileManager.default.createDirectory(at: CodexHookSpool.folder(home: home), withIntermediateDirectories: true)
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: CodexHookSpool.current(home: home))

        let codex = try FileHandle(forUpdating: rollout)
        let reader = LocalActivityReader(writerProbe: MacRolloutWriters.probe)
        func phase(_ activities: [SessionActivity]) -> ActivityPhase? { activities.first { $0.threadID == thread }?.phase }

        let quiet = await reader.read(home: home, now: start.addingTimeInterval(180))
        XCTAssertEqual(phase(quiet.activities), .running, "A writer still holds the rollout")

        try codex.close()
        let gone = await reader.read(home: home, now: start.addingTimeInterval(240))
        XCTAssertEqual(phase(gone.activities), .unknown, "Its writer closed the rollout without ending the turn")
    }
}
