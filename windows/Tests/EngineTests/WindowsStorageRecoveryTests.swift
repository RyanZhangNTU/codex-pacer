import Foundation
import XCTest
@testable import PacerCore

final class WindowsStorageRecoveryTests: XCTestCase {
    func testRecoveryRepliesIncludeRequiredSuccessEnvelopeAndDemoHasNoProductionFiles() async throws {
        let output = RecoveryProtocolCapture()
        let runtime = EngineRuntime(demo: true, dismissalStore: nil, output: { output.append($0) })
        _ = await runtime.receive(Data(#"{"protocolVersion":1,"id":"start","method":"initialize","params":{"enabledProviders":[]}}"#.utf8))
        for method in ["storageRecoveryStatus", "recoverFutureStorage"] {
            let command = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "check", "method": method])
            _ = await runtime.receive(command)
            let reply = try XCTUnwrap(output.reply())
            XCTAssertEqual(reply["type"] as? String, "result"); XCTAssertEqual(reply["ok"] as? Bool, true)
            let value = try XCTUnwrap(reply["value"] as? [String: Any])
            XCTAssertEqual(value["futureFiles"] as? [String], [])
        }
        await runtime.stop()
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-recovery-中文 space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func backups(_ file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".damaged-") }
    }
    private func quota() throws -> (QuotaSnapshot, QuotaCycleHistory) {
        var snapshot = try QuotaSnapshot.decode(Data(#"{"rateLimits":{"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1800604800}}}"#.utf8), capturedAt: now)
        snapshot.accountScope = "synthetic-scope"; var history = QuotaCycleHistory(); history.record(snapshot)
        return (snapshot, history)
    }

    func testBothQuotaProvidersQuarantineAndContinueWithoutChangingScopeOrAgeRules() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (snapshot, history) = try quota()
        for provider in ["codex", "claude"] {
            let folder = root.appendingPathComponent(provider), home = root.appendingPathComponent("synthetic-home")
            let recovery = WindowsStorageRecovery(), files = WindowsRecoveringHistoryFiles(kind: .quota, recovery: recovery)
            let cache = QuotaCycleCache(directory: folder, files: files)
            try cache.save(home: home, snapshot: snapshot, history: history)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            let valid = try Data(contentsOf: file)
            XCTAssertNil(cache.load(home: home, accountScope: "other-synthetic-scope", now: now))
            XCTAssertNil(cache.load(home: home, accountScope: "synthetic-scope", now: now.addingTimeInterval(8 * 86400)))
            XCTAssertEqual(try Data(contentsOf: file), valid); XCTAssertTrue(try backups(file).isEmpty)
            for bytes in [Data("synthetic broken bytes".utf8), Data(repeating: 32, count: 3 * 1024 * 1024 + 1)] {
                try bytes.write(to: file)
                XCTAssertNil(cache.load(home: home, accountScope: "synthetic-scope", now: now))
                XCTAssertTrue(try backups(file).contains { try Data(contentsOf: $0) == bytes })
                try cache.save(home: home, snapshot: snapshot, history: history)
                XCTAssertEqual(cache.load(home: home, accountScope: "synthetic-scope", now: now)?.1, history)
            }
            XCTAssertEqual(recovery.status()["quota"] as? Int, 2)
        }
    }

    func testDeepSeekCorruptionRebuildsAndKeepsOnlyThreeOriginalByteBackups() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history-v1.json"), recovery = WindowsStorageRecovery()
        var history = DeepSeekBalanceHistory(); history.record(total: 100, at: now, source: "apiKey", credentialFingerprint: String(repeating: "a", count: 32))
        for index in 0..<6 {
            let bytes = Data("synthetic-private-damaged-\(index)".utf8); try bytes.write(to: file)
            let store = DeepSeekBalanceHistoryStore(file: file, recovery: recovery)
            let empty = await store.load(now: now); XCTAssertTrue(empty.samples.isEmpty)
            let saved = try backups(file); XCTAssertEqual(saved.count, min(index + 1, 3))
            XCTAssertTrue(try saved.contains { try Data(contentsOf: $0) == bytes })
            await store.save(history)
            let restored = await DeepSeekBalanceHistoryStore(file: file, recovery: recovery).load(now: now)
            XCTAssertEqual(restored, history)
        }
        XCTAssertEqual(recovery.status()["deepseek"] as? Int, 6)
        let diagnostics = try JSONSerialization.data(withJSONObject: recovery.status())
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains("synthetic-private"))
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains(root.path))
    }

    func testReadRecordsQuarantineThenMarkPersistsAcrossRestart() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("completion-dismissals-v1.json"), recovery = WindowsStorageRecovery()
        let store = CompletionDismissalStore(fileURL: file, files: WindowsRecoveringHistoryFiles(kind: .dismissals, recovery: recovery), preservesDamagedFile: true)
        let digest = CompletionDismissalStore.digest(["synthetic-ending"])
        for bytes in [Data("broken".utf8), Data(#"{"version":1,"digests":["not-a-digest"]}"#.utf8), Data(repeating: 32, count: 65537)] {
            try bytes.write(to: file); XCTAssertTrue(store.loadDigests().isEmpty)
            XCTAssertTrue(try backups(file).contains { try Data(contentsOf: $0) == bytes })
            XCTAssertTrue(store.saveDigests([digest]))
            XCTAssertEqual(CompletionDismissalStore(fileURL: file).loadDigests(), [digest])
        }
        XCTAssertEqual(recovery.status()["dismissals"] as? Int, 3)
    }

    func testEveryFutureHistoryRemainsProtectedUntilExplicitConfirmation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (snapshot, history) = try quota(), home = root.appendingPathComponent("home")
        let recovery = WindowsStorageRecovery()
        let cache = QuotaCycleCache(directory: root, files: WindowsRecoveringHistoryFiles(kind: .quota, recovery: recovery))
        try cache.save(home: home, snapshot: snapshot, history: history)
        let quotaFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let dismissFile = root.appendingPathComponent("completion-dismissals-v1.json"), deepFile = root.appendingPathComponent("history-v1.json")
        let future = Data(#"{"version":999,"synthetic":"preserve these exact bytes"}"#.utf8)
        for file in [quotaFile, dismissFile, deepFile] { try future.write(to: file) }
        XCTAssertNil(cache.load(home: home, accountScope: "synthetic-scope", now: now))
        XCTAssertThrowsError(try cache.save(home: home, snapshot: snapshot, history: history))
        let dismissals = CompletionDismissalStore(fileURL: dismissFile, files: WindowsRecoveringHistoryFiles(kind: .dismissals, recovery: recovery), preservesDamagedFile: true)
        XCTAssertTrue(dismissals.loadDigests().isEmpty); XCTAssertFalse(dismissals.saveDigests([]))
        let deep = DeepSeekBalanceHistoryStore(file: deepFile, recovery: recovery)
        let empty = await deep.load(now: now); XCTAssertTrue(empty.samples.isEmpty); await deep.save(.init())
        for file in [quotaFile, dismissFile, deepFile] { XCTAssertEqual(try Data(contentsOf: file), future); XCTAssertTrue(try backups(file).isEmpty) }
        XCTAssertEqual((recovery.status()["futureFiles"] as? [String])?.count, 3)
        XCTAssertTrue(recovery.recoverFutureFiles())
        for file in [quotaFile, dismissFile, deepFile] { XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups(file).first)), future) }
        try cache.save(home: home, snapshot: snapshot, history: history); XCTAssertTrue(dismissals.saveDigests([])); await deep.save(.init())
        for file in [quotaFile, dismissFile, deepFile] { XCTAssertNotEqual(try Data(contentsOf: file), future) }
        XCTAssertEqual(recovery.status()["futureFiles"] as? [String], [])
    }

    func testInvalidDatesAndDigestsUseSharedValidatorsAndRetentionIgnoresUnownedNames() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (snapshot, history) = try quota(), home = root.appendingPathComponent("home"), recovery = WindowsStorageRecovery()
        let cache = QuotaCycleCache(directory: root, files: WindowsRecoveringHistoryFiles(kind: .quota, recovery: recovery))
        try cache.save(home: home, snapshot: snapshot, history: history)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var raw = try XCTUnwrap(object["history"] as? [String: Any]); raw["lastCapturedAt"] = 1e300; object["history"] = raw
        let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: file)
        XCTAssertNil(cache.load(home: home, accountScope: "synthetic-scope", now: now)); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups(file).first)), bytes)
        let note = file.appendingPathExtension("damaged-user-note"); try Data("keep".utf8).write(to: note)
        for _ in 0..<5 { try Data("broken".utf8).write(to: file); _ = cache.load(home: home, accountScope: "synthetic-scope", now: now) }
        XCTAssertEqual(try Data(contentsOf: note), Data("keep".utf8)); XCTAssertEqual(try backups(file).count, 4)
    }
}

private final class RecoveryProtocolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]?
    func append(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] as? String == "check" else { return }
        lock.lock(); defer { lock.unlock() }; value = object
    }
    func reply() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
}
