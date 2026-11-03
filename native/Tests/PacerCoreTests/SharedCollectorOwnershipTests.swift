import Foundation
import XCTest
@testable import PacerCore

final class SharedCollectorOwnershipTests: XCTestCase {
    func testAncestryRejectsCyclesParentPidReuseAndAnExitedChild() {
        let child = ProcessInstance(pid: 10, started: 100), ancestor = ProcessInstance(pid: 20, started: 50)
        let executable = URL(fileURLWithPath: "C:/fixture/app.exe")
        var rows: [UInt32: ProcessInstanceRecord] = [10: .init(identity: child, parent: 20, executable: executable),
            20: .init(identity: ancestor, parent: 0, executable: executable)]
        let lookup: (UInt32, UInt64) -> ProcessInstanceRecord? = { pid, started in rows[pid].flatMap { started == 0 || $0.identity.started == started ? $0 : nil } }
        XCTAssertTrue(ProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
        rows[20] = .init(identity: .init(pid: 20, started: 150), parent: 0, executable: executable)
        XCTAssertFalse(ProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
        rows[10] = .init(identity: child, parent: 10, executable: executable)
        XCTAssertFalse(ProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
        rows.removeValue(forKey: 10)
        XCTAssertFalse(ProcessOwnership.isDescendant(child, of: ancestor, lookup: lookup))
    }

    func testOwnerIsTheFirstApplicationAboveTheHolder() {
        let parents: [Int32: Int32] = [30: 20, 20: 10, 10: 1, 40: 41, 41: 40]
        let parent: (Int32) -> Int32? = { parents[$0] }
        XCTAssertEqual(ProcessOwnership.findOwner(of: 30, currentProcess: 99, isApplication: { $0 == 10 }, parent: parent), 10)
        XCTAssertEqual(ProcessOwnership.findOwner(of: 30, currentProcess: 99, isApplication: { $0 == 10 || $0 == 30 }, parent: parent), 30)
        XCTAssertNil(ProcessOwnership.findOwner(of: 30, currentProcess: 99, isApplication: { _ in false }, parent: parent))
        XCTAssertNil(ProcessOwnership.findOwner(of: 30, currentProcess: 99, isApplication: { $0 == 1 }, parent: parent))
        XCTAssertNil(ProcessOwnership.findOwner(of: 30, currentProcess: 20, isApplication: { $0 == 10 }, parent: parent))
        XCTAssertNil(ProcessOwnership.findOwner(of: 40, currentProcess: 99, isApplication: { _ in false }, parent: parent))
        XCTAssertNil(ProcessOwnership.findOwner(of: 30, currentProcess: 99, isApplication: { $0 == 10 }, parent: { _ in nil }))
    }

    func testRolloutHoldersRejectAnotherHomeCurrentProcessAndPidReuse() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-owner-fixture")
        let target = root.appendingPathComponent("rollout-task.jsonl")
        let other = root.appendingPathComponent("other-home/rollout-task.jsonl")
        let start = Date(timeIntervalSince1970: 10)
        let processes: () -> [Int32] = { [1, 7, 10, 11, 12] }
        var reads = 0
        let result = CodexRolloutOwners.holders(rollouts: ["task": target], currentProcess: 7, processes: processes,
            files: { pid in pid == 10 ? [other] : [target] }, processStart: { pid in
                if pid == 11 { reads += 1; return start.addingTimeInterval(Double(reads)) }
                return start
            })
        XCTAssertEqual(result, ["task": 12])
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(CodexRolloutOwners.holders(rollouts: [:], currentProcess: 7, processes: processes,
            files: { _ in XCTFail("An empty selection must not inspect processes"); return [] }, processStart: { _ in start }), [:])
    }

    func testRuntimeDiagnosticsKeepOnlyAllowedFieldsAndHashedIdentifiers() throws {
        let bytes = try XCTUnwrap(RuntimeDiagnostics.data("remoteFrame", source: "private-source", frame: [
            "kind": "runtimeBatch", "text": "PRIVATE", "path": "PRIVATE", "events": [["threadId": "private-thread",
                "turnId": "private-turn", "method": "turn/started", "text": "PRIVATE", "arguments": "PRIVATE"]]]))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("private-source"))
        XCTAssertFalse(text.contains("private-thread")); XCTAssertFalse(text.contains("private-turn"))
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let events = try XCTUnwrap(row["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["method"] as? String, "turn/started"); XCTAssertEqual(bytes.last, 10)
    }
}
