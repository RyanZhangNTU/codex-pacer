import Foundation
import XCTest
@testable import PacerCore

final class WindowsHistoryPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-history-中文-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func snapshot(scope: String = "synthetic-a", offset: Double = 0) throws -> QuotaSnapshot {
        let data = Data("{\"rateLimits\":{\"secondary\":{\"usedPercent\":20,\"windowDurationMins\":10080,\"resetsAt\":1800604800}}}".utf8)
        var value = try QuotaSnapshot.decode(data, capturedAt: now.addingTimeInterval(offset)); value.accountScope = scope
        return value
    }
    func testBothQuotaProvidersReuseMacHomeScopeFormatAndDeferredFlush() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for provider in ["codex", "claude"] {
            let folder = root.appendingPathComponent(provider), home = root.appendingPathComponent("home-a")
            let store = QuotaHistoryStore(directory: folder, files: WindowsFileSystem())
            let cache = QuotaCycleCache(directory: folder, files: WindowsFileSystem())
            let first = try snapshot(), next = try snapshot(offset: 600)
            var history = QuotaCycleHistory(); history.record(first)
            var saved = await store.save(home: home, snapshot: first, history: history, now: now); XCTAssertTrue(saved)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].lastPathComponent.count, "cycle-".count + 64 + ".json".count)
            let original = try Data(contentsOf: files[0]); history.record(next)
            saved = await store.save(home: home, snapshot: next, history: history, now: next.capturedAt); XCTAssertTrue(saved)
            XCTAssertEqual(try Data(contentsOf: files[0]), original, "The existing thirty-minute coalescing policy is unchanged")
            saved = await store.flush(at: next.capturedAt); XCTAssertTrue(saved)
            let restarted = QuotaHistoryStore(directory: folder, files: WindowsFileSystem())
            let restored = await restarted.restore(home: home, accountScope: "synthetic-a", now: next.capturedAt)
            XCTAssertEqual(restored?.0, next); XCTAssertEqual(restored?.1, history)
            XCTAssertEqual(QuotaCycleCache(directory: folder).load(home: home, accountScope: "synthetic-a", now: next.capturedAt)?.1, history,
                "The Mac cache decodes the exact Windows bytes")
            XCTAssertNil(cache.load(home: root.appendingPathComponent("home-b"), accountScope: "synthetic-a", now: next.capturedAt))
            XCTAssertNil(cache.load(home: home, accountScope: "synthetic-b", now: next.capturedAt))
            let accountB = try snapshot(scope: "synthetic-b", offset: 900); var other = QuotaCycleHistory(); other.record(accountB)
            try cache.save(home: home, snapshot: accountB, history: other)
            XCTAssertEqual(cache.load(home: home, accountScope: "synthetic-b", now: accountB.capturedAt)?.1, other,
                "A valid cache from another scope is replaceable, not treated as corruption")
            XCTAssertNil(cache.load(home: home, accountScope: "synthetic-a", now: accountB.capturedAt))
        }
    }
    func testQuotaCorruptionFutureSchemaOversizeAndExtremeDatesArePreservedOnSave() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), value = try snapshot()
        var history = QuotaCycleHistory(); history.record(value)
        let cache = QuotaCycleCache(directory: root, files: WindowsFileSystem())
        try cache.save(home: home, snapshot: value, history: history)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let valid = try Data(contentsOf: file)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any]); future["version"] = 999
        var extreme = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var raw = try XCTUnwrap(extreme["history"] as? [String: Any]); var cycles = try XCTUnwrap(raw["cycles"] as? [[String: Any]])
        cycles[0]["resetsAt"] = 1e300; raw["cycles"] = cycles; extreme["history"] = raw
        var badPoint = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var pointHistory = try XCTUnwrap(badPoint["history"] as? [String: Any])
        var pointCycles = try XCTUnwrap(pointHistory["cycles"] as? [[String: Any]])
        pointCycles[0]["points"] = [["timestamp": now.timeIntervalSinceReferenceDate, "remaining": 1e300]]
        pointHistory["cycles"] = pointCycles; badPoint["history"] = pointHistory
        var badClock = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var clockHistory = try XCTUnwrap(badClock["history"] as? [String: Any]); clockHistory["lastCapturedAt"] = 1e300
        badClock["history"] = clockHistory
        var creditValue = try XCTUnwrap(DemoScenario.quota(.codex, at: now).last); creditValue.accountScope = "synthetic-a"
        var badCredit = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var creditSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(creditValue)) as? [String: Any])
        var summary = try XCTUnwrap(creditSnapshot["resetCredits"] as? [String: Any])
        var credits = try XCTUnwrap(summary["credits"] as? [[String: Any]]); credits[0]["expiresAt"] = 1e300
        summary["credits"] = credits; creditSnapshot["resetCredits"] = summary; badCredit["snapshot"] = creditSnapshot
        var badCount = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var countSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(creditValue)) as? [String: Any])
        var countSummary = try XCTUnwrap(countSnapshot["resetCredits"] as? [String: Any]); countSummary["availableCount"] = Int.min
        countSnapshot["resetCredits"] = countSummary; badCount["snapshot"] = countSnapshot
        for data in [Data("not JSON".utf8), try JSONSerialization.data(withJSONObject: future),
                     try JSONSerialization.data(withJSONObject: extreme), try JSONSerialization.data(withJSONObject: badPoint),
                     try JSONSerialization.data(withJSONObject: badClock), try JSONSerialization.data(withJSONObject: badCredit),
                     try JSONSerialization.data(withJSONObject: badCount),
                     Data(repeating: 32, count: 3 * 1024 * 1024 + 1)] {
            try data.write(to: file)
            XCTAssertNil(cache.load(home: home, accountScope: "synthetic-a", now: now))
            XCTAssertThrowsError(try cache.save(home: home, snapshot: value, history: history))
            XCTAssertEqual(try Data(contentsOf: file), data, "A live reading cannot erase the damaged file")
        }
    }
    func testDeepSeekGlobalLegacyAndCredentialBindingSurviveRestartAndDamageIsPreserved() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history-v1.json")
        var legacy = DeepSeekBalanceHistory(); legacy.record(total: 100, at: now, source: "apiKey")
        let store = DeepSeekBalanceHistoryStore(file: file); await store.save(legacy)
        let bytes = try Data(contentsOf: file)
        let restarted = DeepSeekBalanceHistoryStore(file: file)
        var loaded = await restarted.load(now: now); XCTAssertEqual(loaded, legacy); XCTAssertNil(loaded.credentialFingerprint)
        let tag = String(repeating: "a", count: 32)
        loaded.record(total: 90, at: now.addingTimeInterval(60), source: "apiKey", credentialFingerprint: tag)
        await restarted.save(loaded, revision: 1)
        let after = await DeepSeekBalanceHistoryStore(file: file).load(now: now.addingTimeInterval(60))
        XCTAssertEqual(after, loaded); XCTAssertEqual(after.credentialFingerprint, tag)
        XCTAssertEqual(after.samples.count, 2, "The legacy history adopts the current credential, as on Mac")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "history"])
        XCTAssertEqual(object["version"] as? Int, 1)
        var future = object; future["version"] = 2
        for damaged in [Data("broken".utf8), try JSONSerialization.data(withJSONObject: future), Data(repeating: 32, count: 65537)] {
            try damaged.write(to: file)
            let fresh = DeepSeekBalanceHistoryStore(file: file)
            let fallback = await fresh.load(now: now); XCTAssertTrue(fallback.samples.isEmpty)
            await fresh.save(loaded)
            XCTAssertEqual(try Data(contentsOf: file), damaged)
        }
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("home"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("sk-"))
    }
    func testWindowsAcknowledgmentStorePreservesDamagedBytesAfterReadAndMark() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("dismissals.json"), store = CompletionDismissalStore(fileURL: file)
        let digest = CompletionDismissalStore.digest(["synthetic-ending"])
        XCTAssertTrue(store.saveDigests([digest])); XCTAssertEqual(store.loadDigests(), [digest])
        for data in [Data("broken".utf8), Data("{\"version\":999,\"digests\":[]}".utf8), Data(repeating: 32, count: 65537)] {
            try data.write(to: file)
            XCTAssertTrue(store.loadDigests().isEmpty); XCTAssertFalse(store.saveDigests([digest]))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testDemoPublishesIndependentSharedCyclesForBothQuotaProviders() async throws {
        let capture = HistoryCapture(), date = now
        let runtime = EngineRuntime(demo: true, now: { date }, output: { capture.append($0) })
        _ = await runtime.receive(Data(#"{"protocolVersion":1,"id":"start","method":"initialize","params":{"enabledProviders":["codex","claude"]}}"#.utf8))
        let snapshot = try XCTUnwrap(capture.last())
        for provider in [AgentProvider.codex, .claude] {
            let history = try XCTUnwrap(snapshot.quotaDashboard?.providers.first { $0.provider == provider }?.history)
            XCTAssertGreaterThan(try XCTUnwrap(history.chart?.points.count), 20)
            XCTAssertEqual(history.account != nil, provider == .codex)
        }
        await runtime.stop()
    }

}


private final class HistoryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngineSnapshot?
    func append(_ data: Data) {
        guard let next = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }; value = next
    }
    func last() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
}
