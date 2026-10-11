import XCTest
@testable import PacerCore

final class CompletionDismissalStoreTests: XCTestCase {
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

    func testAcknowledgedLocalAndRemoteEndingsSurviveStoreReconstructionWithoutPrivateText() throws {
        let file = try fixture()
        let endings = AgentProvider.allCases.flatMap { provider in [completion(provider), completion(provider, hostID: host)] } +
            [completion(.codex, hostID: controlHost)]
        var first = inbox(file)
        first.observe(endings, at: epoch.addingTimeInterval(2), retention: 0)
        XCTAssertEqual(first.activities.count, 5)
        for ending in endings { first.dismiss(ending) }
        var relaunched = inbox(file)
        relaunched.observe(endings, at: epoch.addingTimeInterval(3), retention: 0)
        XCTAssertTrue(relaunched.activities.isEmpty)
        XCTAssertTrue(relaunched.unreadActivities.isEmpty)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        for privateText in [session, "synthetic-private-turn", "Synthetic private title", "private-project", "private-home", host, controlHost] {
            XCTAssertFalse(text.contains(privateText))
        }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["version", "digests"])
        XCTAssertTrue(try XCTUnwrap(value["digests"] as? [String]).allSatisfy { $0.count == 64 })
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testExplicitTurnAcknowledgmentIgnoresReplayDatesAndLateMetadataButNotNewEnding() throws {
        let file = try fixture()
        for provider in AgentProvider.allCases {
            let ended = completion(provider)
            var first = inbox(file)
            first.observe([ended], at: epoch.addingTimeInterval(2), retention: 0)
            first.dismiss(ended)
            var replay = completion(provider, offset: 0.0003)
            replay.applyRuntime(["method": "metadata", "threadId": session, "name": "Later synthetic name", "model": "synthetic-model", "at": epoch.timeIntervalSince1970 + 50])
            replay.applyRequestUsage(responseID: "synthetic-response", turnID: replay.turnID!, outputTokens: 80, at: epoch.addingTimeInterval(51))
            var relaunched = inbox(file)
            relaunched.observe([replay], at: epoch.addingTimeInterval(52), retention: 0)
            XCTAssertTrue(relaunched.activities.isEmpty, "Rounding and display/performance updates cannot revive the same identified ending")
            let datedReplay = completion(provider, offset: 2)
            relaunched.observe([datedReplay], at: epoch.addingTimeInterval(4), retention: 0)
            XCTAssertTrue(relaunched.activities.isEmpty, "Runtime and log timestamps may differ for the same explicit turn")
            for distinct in [completion(provider, turn: "next", offset: 60),
                             completion(provider, offset: 60, status: "interrupted"),
                             completion(provider, offset: 60, status: "failed")] {
                var fresh = inbox(file)
                fresh.observe([distinct], at: epoch.addingTimeInterval(62), retention: 0)
                XCTAssertEqual(fresh.activities.count, 1, "A changed turn, phase or failure is a separate ending")
            }
        }
    }

    func testProviderHostAndSourceHomesRemainIndependentAcrossRebindAndModuleToggle() throws {
        let file = try fixture(), local = completion(.claude), remote = completion(.claude, hostID: host)
        var first = inbox(file)
        first.observe([local, remote], at: epoch.addingTimeInterval(2), retention: 0)
        first.dismiss(local); first.dismiss(remote)
        let saved = try Data(contentsOf: file)
        first.remove(provider: .claude)
        first.bindSourceHomes(provider: .claude, localHome: URL(fileURLWithPath: "/synthetic/private-home"), remoteHomes: [host: "~/.synthetic-private-home"])
        first.observe([local, remote], at: epoch.addingTimeInterval(3), retention: 0)
        XCTAssertTrue(first.activities.isEmpty, "Re-enabling the same profile preserves acknowledgment")
        first.bindSourceHomes(provider: .claude, localHome: URL(fileURLWithPath: "/synthetic/other-home"), remoteHomes: [host: "~/.synthetic-private-home"])
        first.observe([local, remote], at: epoch.addingTimeInterval(4), retention: 0)
        XCTAssertEqual(first.activities.count, 2, "Replacing the local provider home isolates both local and remote readers")
        var changedRemote = inbox(file, remoteHome: "~/.other-remote-home")
        changedRemote.observe([local, remote], at: epoch.addingTimeInterval(4), retention: 0)
        XCTAssertEqual(changedRemote.activities.map(\.id), [remote.id])
        var otherSources = inbox(file)
        otherSources.bindSourceHomes(provider: .claude, localHome: URL(fileURLWithPath: "/synthetic/private-home"), remoteHomes: ["remote-ssh-discovered:other-host": "~/.synthetic-private-home"])
        let codex = completion(.codex), otherHost = completion(.claude, hostID: "remote-ssh-discovered:other-host")
        otherSources.observe([codex, otherHost], at: epoch.addingTimeInterval(4), retention: 0)
        XCTAssertEqual(Set(otherSources.activities.map(\.id)), Set([codex.id, otherHost.id]))
        XCTAssertEqual(try Data(contentsOf: file), saved, "Rebinding and module toggles never rewrite or clear the store")
    }

    func testLegacyEndingUsesRoundedDatesAndDoesNotSuppressAnotherEnding() throws {
        let file = try fixture()
        func legacy(_ offset: Double) -> SessionActivity {
            var value = SessionActivity(id: "local:" + session)
            value.applySubagentEvidence(.init(parentThreadID: "019a0000-0000-7000-8000-000000000902", state: "completed", observedAt: epoch.addingTimeInterval(offset)))
            return value
        }
        let ended = legacy(0)
        XCTAssertNil(ended.turnID); XCTAssertEqual(ended.phase, .completed)
        var first = inbox(file)
        first.observe([ended], at: epoch.addingTimeInterval(1), retention: 0); first.dismiss(ended)
        var relaunched = inbox(file)
        relaunched.observe([legacy(0.0002)], at: epoch.addingTimeInterval(1), retention: 0)
        XCTAssertTrue(relaunched.activities.isEmpty)
        var different = inbox(file)
        different.observe([legacy(1)], at: epoch.addingTimeInterval(2), retention: 0)
        XCTAssertEqual(different.activities.count, 1)
    }

    func testOnlyMatchingKnownScopeDismissalWritesAndObservationExpiryRemainMemoryOnly() throws {
        let file = try fixture(), ended = completion(.claude)
        var value = inbox(file)
        value.observe([ended], at: epoch.addingTimeInterval(2), retention: 30)
        value.dismiss(completion(.claude, turn: "wrong-turn"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        value.prune(at: epoch.addingTimeInterval(50), retention: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Expiry is not user acknowledgment")
        var unknown = CompletionInbox(dismissalStore: CompletionDismissalStore(fileURL: file))
        unknown.bindSourceHomes(provider: .claude, localHome: URL(fileURLWithPath: "/synthetic/home"))
        let remote = completion(.claude, hostID: host)
        unknown.observe([remote], at: epoch.addingTimeInterval(2), retention: 0); unknown.dismiss(remote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "An unbound remote home cannot persist a guessed scope")
        var successful = inbox(file)
        successful.observe([ended], at: epoch.addingTimeInterval(2), retention: 0); successful.dismiss(ended)
        let saved = try Data(contentsOf: file)
        successful.observe([ended], at: epoch.addingTimeInterval(100), retention: 0)
        successful.dismiss(ended); successful.prune(at: epoch.addingTimeInterval(100), retention: 1)
        successful.remove(provider: .claude)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    func testStoreEvictsOldestAcknowledgmentAtBoundAndKeepsNewestAfterRecreation() throws {
        let file = try fixture()
        var value = inbox(file)
        for index in 0...512 {
            let ended = completion(turn: "synthetic-\(index)", offset: Double(index) * 2)
            value.observe([ended], at: epoch.addingTimeInterval(Double(index) * 2 + 1), retention: 0)
            value.dismiss(ended)
        }
        let data = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(data.count, 64 * 1024)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((envelope["digests"] as? [String])?.count, 512)
        var newest = inbox(file)
        newest.observe([completion(turn: "synthetic-512", offset: 1024)], at: epoch.addingTimeInterval(1026), retention: 0)
        XCTAssertTrue(newest.activities.isEmpty)
        var oldest = inbox(file)
        oldest.observe([completion(turn: "synthetic-0")], at: epoch.addingTimeInterval(1026), retention: 0)
        XCTAssertEqual(oldest.activities.count, 1, "Bound eviction fails open for old cards")
    }

    func testCorruptUnsupportedOrOversizedStoreFailsOpen() throws {
        let file = try fixture(), ended = completion()
        var initial = inbox(file)
        initial.observe([ended], at: epoch.addingTimeInterval(2), retention: 0); initial.dismiss(ended)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let digest = try XCTUnwrap((valid["digests"] as? [String])?.first)
        let cases: [Data] = [Data("{broken".utf8),
            try JSONSerialization.data(withJSONObject: ["version": 2, "digests": [digest]]),
            try JSONSerialization.data(withJSONObject: ["version": 1, "digests": [digest, "invalid"]]),
            try JSONSerialization.data(withJSONObject: ["version": 1, "digests": [digest, digest]]),
            Data(repeating: 32, count: 64 * 1024 + 1)]
        for data in cases {
            try data.write(to: file)
            var relaunched = inbox(file)
            relaunched.observe([ended], at: epoch.addingTimeInterval(3), retention: 0)
            XCTAssertEqual(relaunched.activities.count, 1)
            XCTAssertEqual(try Data(contentsOf: file), data, "Reading malformed data never repairs or writes it implicitly")
        }
    }

    func testInFlightAcknowledgmentRequiresUnchangedBoundScopeWithOrWithoutDiskStore() throws {
        for provider in AgentProvider.allCases {
            for persist in [false, true] {
                let file = try fixture(), ended = completion(provider, hostID: host)
                var value = persist ? inbox(file) : CompletionInbox()
                value.bindSourceHomes(provider: provider, localHome: URL(fileURLWithPath: "/synthetic/private-home"), remoteHomes: [host: "~/.synthetic-private-home"])
                value.observe([ended], at: epoch.addingTimeInterval(2), retention: 0)
                let oldToken = try XCTUnwrap(value.acknowledgment(for: ended))
                value.bindSourceHomes(provider: provider, localHome: URL(fileURLWithPath: "/synthetic/private-home"), remoteHomes: [host: "~/.replacement-home"])
                value.observe([ended], at: epoch.addingTimeInterval(3), retention: 0)
                XCTAssertFalse(value.dismiss(ended, acknowledging: oldToken))
                XCTAssertEqual(value.activities.count, 1)
                XCTAssertTrue(value.isUnread(ended))
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "An old navigation outcome cannot acknowledge the replacement source")
                let currentToken = try XCTUnwrap(value.acknowledgment(for: ended))
                XCTAssertTrue(value.dismiss(ended, acknowledging: currentToken))
                XCTAssertTrue(value.activities.isEmpty)
                XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), persist)
            }
        }
    }

    func testRemoteControlScopesAreValidatedCodexOwnerRoutesAndRemainIsolatedAcrossRemovalOrHomeChanges() throws {
        let file = try fixture(), ended = completion(.codex, hostID: controlHost)
        var value = inbox(file)
        value.observe([ended], at: epoch.addingTimeInterval(2), retention: 0)
        let token = try XCTUnwrap(value.acknowledgment(for: ended)), source = value.sourceToken(for: ended)
        XCTAssertTrue(value.dismiss(ended, acknowledging: token))
        let saved = try Data(contentsOf: file)
        var rebuilt = inbox(file)
        rebuilt.observe([ended], at: epoch.addingTimeInterval(3), retention: 0)
        XCTAssertTrue(rebuilt.activities.isEmpty)
        value.bindSourceHomes(provider: .codex, localHome: URL(fileURLWithPath: "/synthetic/private-home"))
        XCTAssertFalse(value.isCurrentSource(source))
        value.observe([ended], at: epoch.addingTimeInterval(4), retention: 0)
        XCTAssertFalse(value.dismiss(ended, acknowledging: token), "A removed owner route cannot acknowledge an ending after await")
        XCTAssertTrue(value.isUnread(ended))
        value.bindSourceHomes(provider: .codex, localHome: URL(fileURLWithPath: "/synthetic/private-home"), remoteControlHostIDs: [controlHost])
        value.observe([ended], at: epoch.addingTimeInterval(5), retention: 0)
        XCTAssertTrue(value.activities.isEmpty, "Re-enabling the same owner-home route preserves its successful acknowledgment")
        value.bindSourceHomes(provider: .codex, localHome: URL(fileURLWithPath: "/synthetic/replacement-home"), remoteControlHostIDs: [controlHost])
        value.observe([ended], at: epoch.addingTimeInterval(6), retention: 0)
        XCTAssertTrue(value.isUnread(ended), "The same host/session/turn in another owner home is independent")
        XCTAssertFalse(value.dismiss(ended, acknowledging: token))
        XCTAssertEqual(try Data(contentsOf: file), saved, "Route removal and rebinding never change the on-disk acknowledgment store")

        for (provider, hostID) in [(AgentProvider.claude, controlHost), (.codex, "remote-control:bad/path"),
                                   (.codex, "remote-control:trailing\n"), (.codex, "remote-control:" + String(repeating: "a", count: 129))] {
            let invalidFile = try fixture(), invalid = completion(provider, hostID: hostID)
            var invalidInbox = CompletionInbox(dismissalStore: CompletionDismissalStore(fileURL: invalidFile))
            invalidInbox.bindSourceHomes(provider: provider, localHome: URL(fileURLWithPath: "/synthetic/private-home"),
                remoteHomes: [hostID: "/invented/remote-home"], remoteControlHostIDs: [hostID])
            invalidInbox.observe([invalid], at: epoch.addingTimeInterval(2), retention: 0)
            invalidInbox.dismiss(invalid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: invalidFile.path), "Unsupported/invalid control routes never gain a fabricated remote home")
        }
    }
}
