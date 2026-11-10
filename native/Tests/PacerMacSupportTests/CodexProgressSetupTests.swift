import Darwin
@testable import PacerMacSupport
import XCTest
@testable import PacerCore

/// Turning Codex progress off stops reporting at once, even while an earlier
/// setup still waits for a slow Codex and the host quits before it finishes.
final class CodexProgressSetupTests: XCTestCase {
    /// A Codex app-server whose config read waits until the test creates `go`.
    private static let server = """
    import json,os,sys,time
    home=os.environ['CODEX_HOME']
    for line in sys.stdin:
        value=json.loads(line)
        if 'id' not in value:continue
        result={}
        if value['method']=='config/read':
            open(os.path.join(home,'reading'),'w').close()
            while not os.path.exists(os.path.join(home,'go')):time.sleep(0.01)
            result={'layers':[{'name':{'type':'user','file':os.path.join(home,'config.toml')},'version':'1','config':{}}]}
        print(json.dumps({'id':value['id'],'result':result}),flush=True)
    """
    private let storage = MacClaudeHookStorage()

    private func profile() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("config.toml"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func enable(_ home: URL, gate: CodexProgressSwitchGate, request: Int) -> Task<CodexProgressSetupStatus?, Never> {
        let command = CodexProgressCommand.native(executable: URL(fileURLWithPath: "/Applications/Codex Pacer.app/Contents/MacOS/CodexPacerIsland"), home: home)
        let script = Self.server, storage = storage
        return Task.detached {
            await CodexProgressSetup.apply(home: home, reporter: command, storage: storage, gate: gate, request: request, owns: { _ in true }) {
                CodexClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home, arguments: ["-u", "-c", script], timeout: 10)
            }
        }
    }
    private func readStarted(_ home: URL) async throws -> Bool {
        try await TestWait.until { FileManager.default.fileExists(atPath: home.appendingPathComponent("reading").path) }
    }
    private func release(_ home: URL) throws { try Data().write(to: home.appendingPathComponent("go")) }
    private func flagged(_ home: URL) -> Bool { FileManager.default.fileExists(atPath: CodexProgressSetup.flag(home).path) }
    private func accepts(_ home: URL) throws -> Bool {
        var reporter = CodexProgressReporter(home: home)
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report_progress","arguments":{"percent":41}}}"#
        let frame = try XCTUnwrap(reporter.receive(Data((call + "\n").utf8)).first)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        return (reply["result"] as? [String: Any])?["isError"] as? Bool == false
    }

    func testTheLatestSetupEnablesReporting() async throws {
        let home = try profile(), gate = CodexProgressSwitchGate()
        let setup = enable(home, gate: gate, request: gate.begin())
        let started = try await readStarted(home)
        XCTAssertTrue(started)
        try release(home)
        let status = await setup.value
        XCTAssertEqual(status, .ready)
        XCTAssertTrue(flagged(home))
        XCTAssertTrue(try accepts(home))
    }

    func testDurableReporterPersistsOnlyAcceptedReceiptsWithMatchingHostIdentity() throws {
        let home = try profile()
        try FileManager.default.createDirectory(at: CodexProgressSetup.flag(home).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try CodexProgressSetup.on.write(to: CodexProgressSetup.flag(home))
        let mailbox = MacDurableProgressMailbox(home: home)
        try mailbox.prepare()
        var reporter = CodexProgressReporter(home: home, capturesDurableReceipts: true)
        let thread = "019a0000-0000-7000-8000-000000000001"
        let turn = "019a0000-0000-7000-8000-000000000002"
        let other = "019a0000-0000-7000-8000-000000000003"
        func send(percent: Int, contextThread: String, id: String) throws -> Bool {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": [
                "name": "report_progress", "arguments": ["percent": percent],
                "_meta": ["threadId": thread, "callId": id, "x-codex-turn-metadata": [
                    "thread_id": contextThread, "turn_id": turn, "workspaces": ["synthetic": "discarded"]
                ]]
            ]]
            let bytes = try JSONSerialization.data(withJSONObject: message) + Data([10])
            let reply = try XCTUnwrap(reporter.receive(bytes).first)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
            for receipt in reporter.takeDurableReceipts() { mailbox.record(receipt) }
            return (result["result"] as? [String: Any])?["isError"] as? Bool == false
        }
        XCTAssertTrue(try send(percent: 25, contextThread: thread, id: "first"))
        XCTAssertEqual(mailbox.read()[thread + ":" + turn]?.percent, 25)
        XCTAssertTrue(try send(percent: 99, contextThread: other, id: "wrong-thread"))
        XCTAssertFalse(try send(percent: 101, contextThread: thread, id: "out-of-range"))
        XCTAssertEqual(mailbox.read()[thread + ":" + turn]?.percent, 25)
        XCTAssertTrue(try send(percent: 60, contextThread: thread, id: "second"))
        XCTAssertEqual(mailbox.read()[thread + ":" + turn]?.percent, 60)
        XCTAssertNil(mailbox.read()[thread + ":" + other])
        try mailbox.discard()
        XCTAssertTrue(try send(percent: 90, contextThread: thread, id: "after-remove"))
        XCTAssertTrue(mailbox.read().isEmpty)
    }

    func testTurningOffDuringASlowSetupStopsReportingAndKeepsItOff() async throws {
        // A profile that was already reporting before Pacer started again.
        let home = try profile(), gate = CodexProgressSwitchGate()
        try FileManager.default.createDirectory(at: CodexProgressSetup.flag(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try CodexProgressSetup.on.write(to: CodexProgressSetup.flag(home))
        let setup = enable(home, gate: gate, request: gate.change(home: home, wanted: true, previous: nil, storage: storage))
        let started = try await readStarted(home)
        XCTAssertTrue(started)
        XCTAssertTrue(flagged(home), "Starting a setup keeps an existing registration working")

        _ = gate.change(home: home, wanted: false, previous: nil, storage: storage)
        XCTAssertFalse(flagged(home), "Turning off revokes reporting before the earlier setup returns")
        XCTAssertFalse(try accepts(home))
        try release(home)
        let status = await setup.value
        XCTAssertNil(status)
        XCTAssertFalse(flagged(home), "The earlier setup cannot enable reporting again")
        XCTAssertFalse(try accepts(home))
    }

    func testLeavingAProfileRevokesItsReportingAndOnlyPacersFlag() throws {
        let gate = CodexProgressSwitchGate()
        let old = try profile(), new = try profile(), foreign = try profile()
        for home in [old, new, foreign] {
            try FileManager.default.createDirectory(at: CodexProgressSetup.flag(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try CodexProgressSetup.on.write(to: CodexProgressSetup.flag(old))
        try CodexProgressSetup.on.write(to: CodexProgressSetup.flag(new))
        try Data("kept\n".utf8).write(to: CodexProgressSetup.flag(foreign))

        _ = gate.change(home: new, wanted: true, previous: old, storage: storage)
        XCTAssertFalse(flagged(old), "A replaced profile stops reporting at once")
        XCTAssertTrue(flagged(new), "The profile still wanted keeps reporting while its setup runs")
        _ = gate.change(home: foreign, wanted: false, previous: nil, storage: storage)
        XCTAssertEqual(try Data(contentsOf: CodexProgressSetup.flag(foreign)), Data("kept\n".utf8), "Only Pacer's own flag is removed")
    }

    func testDisableRejectsANamedPipeInPlaceOfTheFlag() async throws {
        let home = try profile(), flag = CodexProgressSetup.flag(home)
        try FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(flag.path, 0o600), 0)
        let storage = storage, finished = ShutdownSignal()
        let setup = Task.detached {
            defer { finished.finish() }
            _ = CodexProgressSwitchGate().change(home: home, wanted: false, previous: nil, storage: storage)
            return await CodexProgressSetup.apply(home: home, reporter: nil, storage: storage, owns: { _ in false }) { nil }
        }
        guard try await TestWait.until({ finished.isFinished }) else {
            // Release a blocked open if the storage regressed, so the test can exit.
            let writer = open(flag.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 {
                try? FileManager.default.removeItem(at: flag)
                close(writer)
            }
            XCTFail("Disabling waited for a pipe writer")
            return
        }
        let status = await setup.value
        XCTAssertEqual(status, .failed)
        var info = stat()
        XCTAssertEqual(lstat(flag.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
    }
}
