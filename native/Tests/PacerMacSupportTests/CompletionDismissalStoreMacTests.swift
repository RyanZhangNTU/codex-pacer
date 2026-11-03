import PacerMacSupport
import XCTest
@testable import PacerCore

final class CompletionDismissalStoreMacTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "019a0000-0000-7000-8000-000000000901"
    private let host = "remote-ssh-discovered:synthetic-host"
    private let controlHost = "remote-control:synthetic_control"

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dismissal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("acknowledged.json")
    }
    private func completion(_ provider: AgentProvider = .codex, hostID: String? = nil,
                            turn: String = "synthetic-private-turn", offset: Double = 0,
                            status: String = "completed") -> SessionActivity {
        var value = SessionActivity(id: provider.activityID(sessionID: session, sourceHostID: hostID), sourceHostID: hostID, provider: provider)
        value.applyRuntime(["method": "metadata", "threadId": session, "name": "Synthetic private title", "cwd": "/synthetic/private-project", "at": epoch.timeIntervalSince1970 + offset])
        value.applyRuntime(["method": "turn/started", "threadId": session, "turnId": turn, "at": epoch.timeIntervalSince1970 + offset])
        value.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": turn, "status": status, "at": epoch.timeIntervalSince1970 + offset + 1])
        return value
    }
    private func inbox(_ file: URL, home: String = "/synthetic/private-home", remoteHome: String = "~/.synthetic-private-home") -> CompletionInbox {
        var value = CompletionInbox(dismissalStore: CompletionDismissalStore(fileURL: file))
        for provider in AgentProvider.allCases {
            value.bindSourceHomes(provider: provider, localHome: URL(fileURLWithPath: home), remoteHomes: [host: remoteHome],
                remoteControlHostIDs: provider == .codex ? [controlHost] : [])
        }
        return value
    }








    func testSymbolicLinkToAValidStoreDoesNotLoadAcknowledgments() throws {
        let target = try fixture(), link = target.deletingLastPathComponent().appendingPathComponent("linked.json")
        let store = CompletionDismissalStore(fileURL: target), digest = CompletionDismissalStore.digest(["synthetic-ending"])
        XCTAssertTrue(store.saveDigests([digest]))
        let saved = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(store.loadDigests(), [digest])
        let linked = CompletionDismissalStore(fileURL: link).load()
        XCTAssertTrue(linked.digests.isEmpty)
        XCTAssertTrue(linked.cloudEndings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), saved)
    }




    func testStoredAcknowledgmentsKeepPrivatePermissions() throws {
        let file = try fixture()
        XCTAssertTrue(CompletionDismissalStore(fileURL: file).saveDigests([String(repeating: "a", count: 64)]))
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
}
