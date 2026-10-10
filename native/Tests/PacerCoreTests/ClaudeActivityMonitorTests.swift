import XCTest
import Darwin
@testable import PacerCore

final class ClaudeActivityMonitorTests: XCTestCase {
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var quietDelivered = false
        private var completedDelivered = false
        private var eofDelivered = false
        private var updates = 0
        private var latest: [String: RuntimeStreamStatus] = [:]
        func quiet(_ statuses: [String: RuntimeStreamStatus], hosts: [String], expectation: XCTestExpectation) {
            lock.lock(); defer { lock.unlock() }; updates += 1; latest = statuses
            if !quietDelivered && hosts.allSatisfy({ statuses[$0]?.connected == true && statuses[$0]?.watchingLogs == false &&
                (statuses[$0]?.helperLoopIterations ?? 0) >= 3 }) {
                quietDelivered = true; expectation.fulfill()
            }
        }
        func terminal(_ values: [SessionActivity], statuses: [String: RuntimeStreamStatus], host: String,
                      completed: XCTestExpectation, eof: XCTestExpectation) {
            lock.lock(); defer { lock.unlock() }; updates += 1; latest = statuses
            guard values.contains(where: { $0.sourceHostID == host && $0.turnID == "fixture-turn" && $0.phase == .completed }) else { return }
            if statuses[host]?.connected == true && !completedDelivered { completedDelivered = true; completed.fulfill() }
            if statuses[host]?.connected == false && !eofDelivered { eofDelivered = true; eof.fulfill() }
        }
        func snapshot() -> (count: Int, statuses: [String: RuntimeStreamStatus]) {
            lock.lock(); defer { lock.unlock() }; return (updates, latest)
        }
    }

    private func fixture() throws -> (root: URL, home: URL) {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-claude-monitor-" + UUID().uuidString)
        let home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (root, home)
    }
    private func executable(in root: URL, script: String) throws -> URL {
        let file = root.appendingPathComponent("fixture-ssh")
        try Data(("#!/usr/bin/env python3\n" + script).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    private func target(_ alias: String) -> RemoteActivityTarget {
        RemoteActivityTarget(id: "remote-ssh-discovered:" + alias, name: "Synthetic SSH", alias: alias, home: "~/.claude")
    }
    private func assertExited(_ pid: Int32) async throws {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The exact owned helper remained alive after stdin EOF")
        _ = Darwin.kill(pid, SIGKILL)
    }

    func testQuietFragmentedSSHHeartbeatsPublishWithoutTasksAndShutdownClosesOnlyOwnedHelpers() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let root = Data(fixture.root.path.utf8).base64EncodedString()
        let script = """
        import base64,json,os,pathlib,select,sys,time
        root=pathlib.Path(base64.b64decode('\(root)').decode())
        alias=sys.argv[sys.argv.index('--')+1]
        (root/(alias+'.pid')).write_text(str(os.getpid()))
        def ended():
            (root/(alias+'.eof')).write_text('closed');sys.exit(0)
        for loops in range(1,4):
            frame=json.dumps({'kind':'status','connected':True,'watchingLogs':False,'scans':1,'loopIterations':loops})+'\\n'
            sys.stdout.write(frame[:11]);sys.stdout.flush();time.sleep(.02)
            sys.stdout.write(frame[11:]);sys.stdout.flush()
            until=time.monotonic()+.15
            while time.monotonic()<until:
                ready,_,_=select.select([sys.stdin],[],[],max(0,until-time.monotonic()))
                if ready and not sys.stdin.readline():ended()
        for line in sys.stdin:pass
        ended()
        """
        let monitor = ClaudeActivityMonitor(sshExecutable: try executable(in: fixture.root, script: script))
        let targets = [target("quiet-one"), target("quiet-two"), target("quiet-three")]
        let quiet = expectation(description: "quiet SSH heartbeats reached the actor promptly")
        let observations = Observations(), hosts = targets.map(\.id), started = Date()
        await monitor.start(home: fixture.home, remoteTargets: targets, refreshPolicy: .collapsed) { values, statuses, requests, performance in
            XCTAssertTrue(values.isEmpty); XCTAssertTrue(requests.isEmpty); XCTAssertTrue(performance.isEmpty)
            observations.quiet(statuses, hosts: hosts, expectation: quiet)
        }
        await fulfillment(of: [quiet], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Transport health must not wait for the collapsed five-second activity batch")
        let statuses = await monitor.statuses()
        for host in hosts { XCTAssertTrue(statuses[host]?.connected == true); XCTAssertFalse(statuses[host]?.watchingLogs == true) }
        let pids = try targets.map { try XCTUnwrap(Int32(String(contentsOf: fixture.root.appendingPathComponent($0.alias + ".pid"), encoding: .utf8))) }
        await monitor.shutdown()
        let count = observations.snapshot().count
        for pid in pids { try await assertExited(pid) }
        for destination in targets { XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent(destination.alias + ".eof"), encoding: .utf8), "closed") }
        XCTAssertEqual(observations.snapshot().count, count, "Cancelled pipe delivery cannot publish after shutdown")
        let stopped = await monitor.statuses()
        XCTAssertFalse(hosts.contains { stopped[$0] != nil })
    }

    func testFragmentedTerminalFramesRemainOrderedBeforeNormalSSHOutputEOF() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = """
        import json,sys,time
        at=time.time()
        status={'kind':'status','connected':True,'watchingLogs':False,'scans':1}
        records=[dict(kind=kind,origin=origin,sessionId='fixture-session',promptId='fixture-turn',at=at) for kind,origin in [('prompt','hook'),('stopRequested','hook'),('stopVerified','transcript')]]
        payload=json.dumps(status)+'\\n'+json.dumps({'kind':'claudeBatch','records':records})+'\\n'
        for offset in range(0,len(payload),17):
            sys.stdout.write(payload[offset:offset+17]);sys.stdout.flush()
        """
        let monitor = ClaudeActivityMonitor(sshExecutable: try executable(in: fixture.root, script: script)), destination = target("normal-eof")
        let completed = expectation(description: "terminal frame was published before EOF")
        let eof = expectation(description: "normal EOF preserved completed activity and disconnected transport")
        let observations = Observations()
        await monitor.start(home: fixture.home, remoteTargets: [destination]) { values, statuses, _, _ in
            observations.terminal(values, statuses: statuses, host: destination.id, completed: completed, eof: eof)
        }
        await fulfillment(of: [completed, eof], timeout: 2, enforceOrder: true)
        let values = await monitor.activities(), statuses = await monitor.statuses()
        XCTAssertEqual(values.filter { $0.sourceHostID == destination.id }.map(\.phase), [.completed])
        XCTAssertFalse(statuses[destination.id]?.connected == true)
        await monitor.shutdown()
    }
}
