@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

final class EngineDeepSeekConnectionTests: XCTestCase {
    func testEveryWebRequestFollowsTheMatchingSourceSnapshotAcrossRepeatedSwitches() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), capture = Capture()
        let services = DeepSeekBalanceServices(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
            readAPI: { _ in throw DeepSeekBalanceError.missingKey }, fingerprint: { _, _ in nil }, detect: { _, _ in .account })
        let runtime = EngineRuntime(demo: true, now: { now }, balanceServices: services, output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        func settings(_ source: String) -> [String: Any] {
            ["mode": "balance", "daily": NSNull(), "weekly": NSNull(), "ringPeriod": "day", "speedSource": "local",
             "showsTurnCost": true, "balanceSource": source]
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"], "deepseekSettings": settings("apiKey")]))
        _ = await runtime.receive(try command("setDeepSeekWebHost", ["webAvailable": true]))
        for index in 0..<8 {
            _ = await runtime.receive(try command("configure", ["deepseekSettings": settings("web")]))
            try await wait { capture.webRequests().count == index + 1 }
            let request = try XCTUnwrap(capture.webRequests().last)
            XCTAssertEqual(capture.last()?.deepseekConnection?.context, request.context)
            XCTAssertEqual(capture.last()?.deepseekConnection?.mode, "account")
            XCTAssertEqual(capture.uncorrelatedWebRequests(), 0,
                "The host must see the current source before any browser work is requested")
            _ = await runtime.receive(try command("completeDeepSeekWebRead", ["webRequestID": request.id,
                "balanceContext": request.context, "webReply": ["state": "ok", "normal": ["35.60"], "bonus": ["6.40"],
                    "sessionFingerprint": String(repeating: "7", count: 64)]]))
            try await wait { capture.last()?.wallet?.balance == 42 }
            _ = await runtime.receive(try command("configure", ["deepseekSettings": settings("apiKey")]))
            XCTAssertNil(capture.last()?.wallet?.balance)
        }
        XCTAssertEqual(capture.webRequests().count, 8)
        await runtime.stop()
    }
    func testRealProtocolKeyEditsKeepSecretsOutOfSnapshotsAndLegacySettingsRetainTheSource() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), memory = KeyMemory(), capture = Capture()
        let fingerprints = DeepSeekHistoryCredential(loadSalt: { Data(repeating: 7, count: 32) }, saveSalt: { _ in })
        let services = DeepSeekBalanceServices(readKey: { memory.read() }, saveKey: { memory.save($0) }, removeKey: { memory.remove() },
            readAPI: { _ in .init(total: 86.4, capturedAt: now, source: .apiKey) }, fingerprint: { fingerprints.fingerprint(source: $0, identity: $1) }, detect: { _, _ in .account })
        let runtime = EngineRuntime(demo: true, now: { now }, balanceServices: services, output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        func group(_ source: String? = nil, daily: Double = 20) -> [String: Any] {
            var values: [String: Any] = ["mode": "budget", "daily": daily, "weekly": NSNull(), "ringPeriod": "day", "speedSource": "local", "showsTurnCost": true]
            if let source { values["balanceSource"] = source }; return values
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"], "deepseekSettings": group("apiKey")]))
        var snapshot = try XCTUnwrap(capture.last()), connection = try XCTUnwrap(snapshot.deepseekConnection)
        XCTAssertEqual(connection.mode, "apiKey"); XCTAssertFalse(connection.hasKey); XCTAssertTrue(connection.reading.keyEditor)
        XCTAssertNil(snapshot.wallet?.balance, "A demo log refresh cannot substitute its web wallet for a missing API key")
        XCTAssertEqual(snapshot.wallet?.dial?.connectTitle, L10n.text("deepseek.paste_key_short"))
        XCTAssertEqual(snapshot.sources.first { $0.id == "deepseek:balance" }?.available, false)
        let first = connection.context
        _ = await runtime.receive(try command("saveDeepSeekKey", ["balanceContext": first, "deepseekKey": "sk-synthetic-protocol-key-0000"]))
        try await wait { capture.last()?.wallet?.balance == 86.4 && capture.last()?.deepseekConnection?.hasKey == true }
        snapshot = try XCTUnwrap(capture.last()); connection = try XCTUnwrap(snapshot.deepseekConnection)
        XCTAssertNotEqual(connection.context, first); XCTAssertEqual(memory.writes(), 1)
        XCTAssertNil(snapshot.wallet?.dial?.connectTitle)
        XCTAssertEqual(snapshot.sources.first { $0.id == "deepseek:balance" }?.available, true)
        XCTAssertFalse(capture.text().contains("sk-synthetic-protocol-key-0000"), "Neither success, error nor snapshot frames may echo a credential")
        _ = await runtime.receive(try command("removeDeepSeekKey", ["balanceContext": first]))
        XCTAssertTrue(memory.read() != nil); XCTAssertEqual(capture.lastError(), "staleSource")
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group(daily: 30)]))
        connection = try XCTUnwrap(capture.last()?.deepseekConnection)
        XCTAssertEqual(connection.source, "apiKey", "Older complete protocol-1 budget groups omit the new source field")
        XCTAssertEqual(connection.context, snapshot.deepseekConnection?.context)
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group("unsupported", daily: 40)]))
        XCTAssertEqual(capture.lastError(), "invalidConfiguration")
        XCTAssertEqual(capture.last()?.deepseekConnection?.source, "apiKey")
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group("web")]))
        let web = try XCTUnwrap(capture.last()?.deepseekConnection); XCTAssertEqual(web.mode, "account"); XCTAssertFalse(web.webAvailable)
        XCTAssertNil(capture.last()?.wallet?.balance); XCTAssertTrue(memory.read() != nil, "Changing a source cannot delete the independent API key")
        XCTAssertEqual(web.status?.message, DeepSeekBalanceError.signedOut.errorDescription)
        XCTAssertTrue(web.status?.actions.isEmpty == true, "The dial owns sign-in recovery; it must not add a transient retry for authentication")
        _ = await runtime.receive(try command("saveDeepSeekKey", ["balanceContext": connection.context, "deepseekKey": "sk-synthetic-second-key-0000"]))
        XCTAssertEqual(memory.writes(), 1); XCTAssertEqual(capture.lastError(), "staleSource")
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group("apiKey")]))
        try await wait { capture.last()?.wallet?.balance == 86.4 }
        let current = try XCTUnwrap(capture.last()?.deepseekConnection)
        _ = await runtime.receive(try command("removeDeepSeekKey", ["balanceContext": current.context]))
        XCTAssertNil(memory.read()); XCTAssertNil(capture.last()?.wallet?.balance); XCTAssertFalse(capture.last()?.deepseekConnection?.hasKey ?? true)
        await runtime.stop()
    }
    func testChangingALogHomeDuringBalanceBindingCannotPublishTheOldHomeAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-balance-source-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("old"), replacement = root.appendingPathComponent("new"), now = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        func record(_ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: now), "type": type, "payload": payload]) + Data([10])
        }
        var log = try record("session_meta", ["id": id, "source": "cli", "cwd": root.path])
        log += try record("event_msg", ["type": "task_started", "turn_id": id])
        try log.write(to: directory.appendingPathComponent("rollout-" + id + ".jsonl"))
        let capture = Capture(), mode = DetectedMode(), history = HistoryGate()
        let services = DeepSeekBalanceServices(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
            readAPI: { _ in throw DeepSeekBalanceError.missingKey }, fingerprint: { _, _ in nil }, detect: { _, _ in mode.read() },
            saveHistory: { _, _ in await history.save() })
        let runtime = EngineRuntime(demo: false, now: { now }, dismissalStore: nil, balanceServices: services, output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        func path(_ value: URL) -> String { value.withUnsafeFileSystemRepresentation { String(cString: $0!) } }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex", "deepseek"],
            "codexHome": path(home), "deepseekHome": path(root.appendingPathComponent("deepseek"))]))
        XCTAssertTrue(capture.last()?.tasks.contains { $0.sessionID == id } == true)
        await history.arm(); mode.use(.account)
        let refreshCommand = try command("refresh"), changeCommand = try command("configure", ["codexHome": path(replacement)])
        let refresh = Task { await runtime.receive(refreshCommand) }
        let started = await history.waitUntilStarted(); XCTAssertTrue(started)
        let first = capture.snapshots().count, reads = mode.reads()
        let change = Task { await runtime.receive(changeCommand) }
        try await wait { mode.reads() > reads }
        await history.release(); _ = await refresh.value; _ = await change.value
        let after = capture.snapshots().dropFirst(first)
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { !$0.tasks.contains { $0.sessionID == id } },
            "A collect suspended in balance binding cannot republish tasks from the replaced log home")
        await runtime.stop()
    }
    func testWebSessionIdentityNeverAppearsInPublishedEngineSnapshots() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), capture = Capture(), identity = String(repeating: "7", count: 64)
        let fingerprints = DeepSeekHistoryCredential(loadSalt: { Data(repeating: 7, count: 32) }, saveSalt: { _ in })
        let services = DeepSeekBalanceServices(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
            readAPI: { _ in throw DeepSeekBalanceError.missingKey }, fingerprint: { fingerprints.fingerprint(source: $0, identity: $1) },
            readWeb: { _ in .init(total: 86.4, capturedAt: now, source: .web, sessionFingerprint: identity) }, detect: { _, _ in .account })
        let runtime = EngineRuntime(demo: true, now: { now }, balanceServices: services, output: { capture.append($0) })
        let group: [String: Any] = ["mode": "budget", "daily": 20, "weekly": NSNull(), "ringPeriod": "day",
            "speedSource": "local", "showsTurnCost": true, "balanceSource": "web"]
        let command = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": "initialize",
            "params": ["enabledProviders": ["deepseek"], "deepseekSettings": group]])
        _ = await runtime.receive(command)
        try await wait { capture.last()?.wallet?.balance == 86.4 }
        let snapshot = try XCTUnwrap(capture.last())
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains(identity), "The page-token digest is transient and cannot become presentation data")
        XCTAssertFalse(text.contains("sessionFingerprint"))
        XCTAssertEqual(snapshot.deepseekConnection?.mode, "account")
        await runtime.stop()
    }
    private func wait(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("The correlated balance update did not arrive")
    }
    private final class KeyMemory: @unchecked Sendable {
        private let lock = NSLock(); private var key: String?, count = 0
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return key }
        func save(_ key: String) -> Bool { lock.lock(); self.key = key; count += 1; lock.unlock(); return true }
        func remove() -> Bool { lock.lock(); key = nil; lock.unlock(); return true }
        func writes() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private final class DetectedMode: @unchecked Sendable {
        private let lock = NSLock(); private var mode = DeepSeekAuthMode.apiKey, count = 0
        func read() -> DeepSeekAuthMode { lock.lock(); defer { lock.unlock() }; count += 1; return mode }
        func use(_ value: DeepSeekAuthMode) { lock.lock(); mode = value; lock.unlock() }
        func reads() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private actor HistoryGate {
        private var armed = false
        private var continuation: CheckedContinuation<Void, Never>?
        func arm() { armed = true }
        func save() async {
            guard armed else { return }; armed = false
            await withCheckedContinuation { continuation = $0 }
        }
        func waitUntilStarted() async -> Bool {
            let start = ProcessInfo.processInfo.systemUptime
            while continuation == nil, ProcessInfo.processInfo.systemUptime - start < 3 { await Task.yield() }
            return continuation != nil
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock(); private var frames: [Data] = []
        func append(_ data: Data) { lock.lock(); frames.append(data); lock.unlock() }
        private func values() -> [Data] { lock.lock(); defer { lock.unlock() }; return frames }
        func snapshots() -> [EngineSnapshot] { values().compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) } }
        func last() -> EngineSnapshot? { values().compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.last }
        func lastError() -> String? {
            values().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .last { $0["type"] as? String == "error" }?["code"] as? String
        }
        func text() -> String { values().map { String(decoding: $0, as: UTF8.self) }.joined() }
        func webRequests() -> [(id: String, context: String)] {
            values().compactMap { data in
                guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["type"] as? String == "hostRequest", value["operation"] as? String == "deepseek.balance",
                      let id = value["requestID"] as? String, let context = value["context"] as? String else { return nil }
                return (id, context)
            }
        }
        func uncorrelatedWebRequests() -> Int {
            var latest: EngineSnapshot?, mismatches = 0
            for data in values() {
                if let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) { latest = snapshot; continue }
                guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["type"] as? String == "hostRequest", value["operation"] as? String == "deepseek.balance" else { continue }
                if latest?.deepseekConnection?.context != value["context"] as? String || latest?.deepseekConnection?.mode != "account" { mismatches += 1 }
            }
            return mismatches
        }
    }
}
