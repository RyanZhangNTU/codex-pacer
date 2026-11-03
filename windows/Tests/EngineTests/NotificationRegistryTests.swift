import Foundation
import XCTest
@testable import PacerCore

final class NotificationRegistryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = CompletionDismissalStore.digest(["synthetic-source"])
    func testReferencesAreBoundedSourceCheckedSingleUseAndExpire() throws {
        var registry = EngineNotificationRegistry(now: now)
        let reference = try XCTUnwrap(registry.issue(kind: "snoozeSpike", provider: .deepseek, source: source, now: now))
        XCTAssertTrue(EngineNotificationRegistry.validReference(reference)); XCTAssertEqual(reference.count, 32)
        XCTAssertNil(registry.consume(reference, source: nil, kind: "snoozeSpike", at: now))
        XCTAssertNil(registry.consume(reference, source: "other", kind: "snoozeSpike", at: now))
        XCTAssertNil(registry.consume(reference, source: source, kind: "topUp", at: now))
        XCTAssertNotNil(registry.consume(reference, source: source, kind: "snoozeSpike", at: now))
        XCTAssertNil(registry.consume(reference, source: source, kind: "snoozeSpike", at: now))
        let expired = try XCTUnwrap(registry.issue(kind: "topUp", provider: .deepseek, source: source, now: now))
        XCTAssertNotNil(registry.record(expired, at: now.addingTimeInterval(86_399)))
        XCTAssertNil(registry.record(expired, at: now.addingTimeInterval(86_400)))
        XCTAssertNil(registry.record(expired, at: now.addingTimeInterval(-1)))
        XCTAssertNil(registry.issue(kind: "https://untrusted.invalid", provider: .codex, source: source, now: now))
        XCTAssertNil(registry.issue(kind: "openTask", provider: .codex, source: source, now: now))
        XCTAssertNil(registry.record(String(repeating: "x", count: 129), at: now))
    }
    func testColdRecordsContainOnlyHashesAndKeepTheCapacityBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-notification-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineNotificationRegistry.Store(url: root.appendingPathComponent("actions.json"), files: WindowsFileSystem())
        var first = EngineNotificationRegistry(store: store, now: now)
        let old = try XCTUnwrap(first.issue(kind: "openTask", provider: .claude, source: source, target: CompletionDismissalStore.digest(["synthetic-task"]), now: now))
        var restored = EngineNotificationRegistry(store: store, now: now)
        XCTAssertEqual(restored.record(old, at: now)?.provider, .claude)
        XCTAssertNotNil(restored.consume(old, source: source, kind: "openTask", at: now))
        XCTAssertNil(EngineNotificationRegistry(store: store, now: now).record(old, at: now))
        for _ in 0..<140 { XCTAssertNotNil(restored.issue(kind: "showIsland", provider: .codex, source: source, now: now)) }
        XCTAssertEqual(restored.records.count, EngineNotificationRegistry.capacity)
        let data = try store.files.read(store.url, offset: 0, maximumBytes: 65_536)
        XCTAssertLessThan(data.count, 65_536)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-task"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-source"))
        XCTAssertEqual(EngineNotificationRegistry(store: store, now: now).records.count, 128)
        try Data("not JSON".utf8).write(to: store.url)
        XCTAssertTrue(EngineNotificationRegistry(store: store, now: now).records.isEmpty)
    }
    func testAReferenceCannotBeIssuedWhenItsPrivateStoreCannotCommit() {
        var registry = EngineNotificationRegistry(store: .init(url: URL(fileURLWithPath: "C:/synthetic/actions.json"), files: RejectNotificationWrites()), now: now)
        XCTAssertNil(registry.issue(kind: "topUp", provider: .deepseek, source: source, now: now))
        XCTAssertTrue(registry.records.isEmpty)
    }
    func testTargetFingerprintIncludesTheEndingEvenWhenTheTurnIDIsReused() throws {
        func entry(ending: Date) throws -> ActivityNavigationRegistry.Entry {
            var activity = SessionActivity(id: AgentProvider.codex.activityID(sessionID: "11111111-1111-4111-8111-111111111111"), provider: .codex,
                sessionID: "11111111-1111-4111-8111-111111111111")
            let formatter = ISO8601DateFormatter()
            activity.consume(["type": "event_msg", "timestamp": formatter.string(from: now), "payload": ["type": "task_started", "turn_id": "same-turn"]])
            activity.consume(["type": "event_msg", "timestamp": formatter.string(from: ending), "payload": ["type": "task_complete", "turn_id": "same-turn"]])
            var registry = ActivityNavigationRegistry()
            registry.update(activities: [activity], requests: [], inbox: CompletionInbox(), cloudContext: nil, canOpen: { _ in true })
            return try XCTUnwrap(registry.entries.values.first)
        }
        let first = try entry(ending: now.addingTimeInterval(1)), same = try entry(ending: now.addingTimeInterval(1)), newer = try entry(ending: now.addingTimeInterval(2))
        XCTAssertEqual(EngineNotificationRegistry.target(first), EngineNotificationRegistry.target(same))
        XCTAssertNotEqual(first.link.context, same.link.context, "Persistent fingerprints must survive a new engine's ephemeral links")
        XCTAssertNotEqual(EngineNotificationRegistry.target(first), EngineNotificationRegistry.target(newer), "An older notice cannot acknowledge a later ending")
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": method, "method": method, "params": params])
    }
    func testActualEngineColdActivationWaitsForInitializationAndRevalidatesTaskAndHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-notification-cold-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineNotificationRegistry.Store(url: root.appendingPathComponent("actions.json"), files: WindowsFileSystem())
        let date = now, frames = NotificationFrames()
        let first = EngineRuntime(demo: true, now: { date }, notificationStore: store, output: { frames.append($0) })
        _ = await first.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        _ = await first.receive(try command("demoStage", ["demoStage": 3]))
        let action = try XCTUnwrap(frames.snapshot?.notices.compactMap(\.defaultAction).first { $0.kind == "openTask" })
        let reference = try XCTUnwrap(action.reference)
        await first.stop()
        let coldFrames = NotificationFrames()
        let cold = EngineRuntime(demo: true, now: { date }, notificationStore: store, output: { coldFrames.append($0) })
        _ = await cold.receive(try command("activateNotification", ["context": reference, "notificationAction": action.kind]))
        XCTAssertEqual(coldFrames.error, "initializeRequired")
        _ = await cold.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        _ = await cold.receive(try command("demoStage", ["demoStage": 3]))
        _ = await cold.receive(try command("activateNotification", ["context": reference, "notificationAction": action.kind]))
        let activation = try XCTUnwrap(coldFrames.activation)
        XCTAssertEqual(activation.kind, "openTask"); XCTAssertEqual(activation.link?.provider, "codex")
        _ = await cold.receive(try command("activateNotification", ["context": reference, "notificationAction": action.kind]))
        XCTAssertEqual(coldFrames.error, "staleNotification")
        let another = try XCTUnwrap(coldFrames.notices.compactMap(\.defaultAction).last { $0.kind == "openTask" }?.reference)
        _ = await cold.receive(try command("configure", ["codexHome": root.path]))
        _ = await cold.receive(try command("activateNotification", ["context": another, "notificationAction": "openTask"]))
        XCTAssertEqual(coldFrames.error, "staleNotification")
        await cold.stop()
    }
}
private struct RejectNotificationWrites: PlatformFileSystem {
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? { nil }
    func entries(in directory: URL) throws -> [URL] { [] }
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
    func replace(_ url: URL, with data: Data) -> Bool { false }
}
private final class NotificationFrames: @unchecked Sendable {
    private let lock = NSLock(); private var frames: [Data] = []
    func append(_ bytes: Data) { lock.lock(); frames.append(bytes); lock.unlock() }
    private var all: [Data] { lock.lock(); defer { lock.unlock() }; return frames }
    var snapshot: EngineSnapshot? { all.compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.last }
    var notices: [EngineNotice] { all.compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.flatMap(\.notices) }
    var error: String? { all.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["code"] as? String }.last }
    var activation: EngineNotificationActivation? {
        struct Result: Decodable { let value: EngineNotificationActivation }
        return all.compactMap { try? JSONDecoder().decode(Result.self, from: $0).value }.last
    }
}
