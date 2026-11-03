@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class QuotaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func date() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private actor QuotaTestConnection: CodexQuotaConnection {
    private var result: Result<QuotaSnapshot, CodexClientError>
    private var scope: String?
    private var blocked: Bool
    private let ignoresShutdown: Bool
    private var pending: CheckedContinuation<QuotaSnapshot, Error>?
    private(set) var reads = 0, shutdowns = 0
    init(_ result: Result<QuotaSnapshot, CodexClientError>, scope: String? = nil, blocked: Bool = false, ignoresShutdown: Bool = false) {
        self.result = result; self.scope = scope; self.blocked = blocked; self.ignoresShutdown = ignoresShutdown
    }
    func readQuota() async throws -> QuotaSnapshot {
        reads += 1
        if blocked { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try result.get()
    }
    func currentAccountScope() -> String? { scope }
    func set(_ result: Result<QuotaSnapshot, CodexClientError>, scope: String?) {
        self.result = result; self.scope = scope
    }
    func release() {
        blocked = false
        let previous = pending; pending = nil
        previous?.resume(with: result.mapError { $0 as Error })
    }
    func shutdown() {
        shutdowns += 1
        if !ignoresShutdown {
            let previous = pending; pending = nil
            previous?.resume(throwing: CodexClientError.disconnected)
        }
    }
}

private actor QuotaTestFactory {
    private var connections: [QuotaTestConnection]
    private(set) var paths: [String] = []
    init(_ connections: [QuotaTestConnection]) { self.connections = connections }
    func make(_ home: URL, _ path: String) throws -> any CodexQuotaConnection {
        paths.append(home.path + "|" + path)
        guard !connections.isEmpty else { throw CodexClientError.missingExecutable }
        if connections.count > 1 { return connections.removeFirst() }
        return connections[0]
    }
}

private final class QuotaEngineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }; values.append(value)
    }
    func last() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return values.last }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private actor QuotaPublishGate {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func pause() async { await withCheckedContinuation { waiting = true; pending = $0 } }
    func release() { let previous = pending; pending = nil; previous?.resume() }
}

final class CodexQuotaMonitorTests: XCTestCase {
    private func reading(_ clock: QuotaTestClock, remaining: Double = 80, scope: String? = "account-a") throws -> QuotaSnapshot {
        let reset = Date(timeIntervalSince1970: 1_800_000_000 + 6 * 86400).timeIntervalSince1970
        let bytes = try JSONSerialization.data(withJSONObject: ["rateLimits": ["secondary": [
            "usedPercent": 100 - remaining, "windowDurationMins": 10080, "resetsAt": reset]]])
        var result = try QuotaSnapshot.decode(bytes, capturedAt: clock.date()); result.accountScope = scope
        return result
    }
    private func monitor(_ factory: QuotaTestFactory, clock: QuotaTestClock, store: QuotaHistoryStore? = nil) -> CodexQuotaMonitor {
        .init(services: .init(makeClient: { try await factory.make($0, $1) }, history: store), now: { clock.date() }, output: { _ in })
    }
    private func configure(_ monitor: CodexQuotaMonitor, home: URL = URL(fileURLWithPath: "/synthetic/a"), context: UInt64 = 1) async {
        await monitor.configure(home: home, customPath: "", enabled: true, context: context)
    }
    private func until(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected the bounded asynchronous operation to finish", file: file, line: line)
    }

    func testRefreshCadenceForceAndConcurrentRequestsUseOneConnection() async throws {
        let clock = QuotaTestClock(), connection = QuotaTestConnection(.success(try reading(QuotaTestClock())), blocked: true)
        let factory = QuotaTestFactory([connection]), monitor = monitor(factory, clock: clock)
        await configure(monitor)
        await monitor.refreshIfDue(expanded: true)
        try await until { await connection.reads == 1 }
        await monitor.refreshIfDue(expanded: true, force: true)
        let coalesced = await connection.reads; XCTAssertEqual(coalesced, 1)
        await connection.release(); await monitor.waitForRefresh()
        clock.advance(29)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        let before = await connection.reads; XCTAssertEqual(before, 1)
        clock.advance(1)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        clock.advance(119)
        await monitor.refreshIfDue(expanded: false); await monitor.waitForRefresh()
        let collapsed = await connection.reads; XCTAssertEqual(collapsed, 2)
        clock.advance(1)
        await monitor.refreshIfDue(expanded: false); await monitor.waitForRefresh()
        await monitor.refreshIfDue(expanded: false, force: true); await monitor.waitForRefresh()
        let refreshed = await connection.reads, made = await factory.paths.count
        XCTAssertEqual(refreshed, 4); XCTAssertEqual(made, 1)
        await monitor.stop()
    }

    func testFailuresBackOffAndExpansionAndManualRefreshCanRetry() async throws {
        let clock = QuotaTestClock(), connection = QuotaTestConnection(.failure(.notLoggedIn))
        let monitor = monitor(QuotaTestFactory([connection]), clock: clock)
        await configure(monitor)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        clock.advance(59)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        let pending = await connection.reads; XCTAssertEqual(pending, 1)
        let signedOut = await monitor.currentState(); XCTAssertEqual(signedOut.failure?.kind, "signedOut")
        clock.advance(1)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        clock.advance(31)
        await monitor.refreshIfDue(expanded: true, expansion: true); await monitor.waitForRefresh()
        let expanded = await connection.reads; XCTAssertEqual(expanded, 3)
        await connection.set(.success(try reading(clock)), scope: "account-a")
        await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        clock.advance(30)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        let recovered = await connection.reads; XCTAssertEqual(recovered, 5)
        XCTAssertEqual((0...4).map { CodexQuotaMonitor.refreshInterval(expanded: true, failures: $0) }, [30, 60, 120, 240, 480])
        XCTAssertEqual((0...4).map { CodexQuotaMonitor.refreshInterval(expanded: false, failures: $0) }, [120, 240, 480, 600, 600])
        await monitor.stop()
    }

    func testSourceAndExecutableChangesRevokeLateResultsAndDisableStopsRefresh() async throws {
        let clock = QuotaTestClock()
        let first = QuotaTestConnection(.success(try reading(clock, remaining: 1)), blocked: true, ignoresShutdown: true)
        let second = QuotaTestConnection(.success(try reading(clock, remaining: 90, scope: "account-b")))
        let factory = QuotaTestFactory([first, second]), monitor = monitor(factory, clock: clock)
        await configure(monitor)
        await monitor.refreshIfDue(expanded: true)
        try await until { await first.reads == 1 }
        let replacement = URL(fileURLWithPath: "/synthetic/b")
        await monitor.configure(home: replacement, customPath: "new-cli", enabled: true, context: 2)
        let cleared = await monitor.currentState(); XCTAssertNil(cleared.snapshot)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        await first.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        let state = await monitor.currentState(), firstStops = await first.shutdowns
        XCTAssertEqual(state.context, 2); XCTAssertEqual(state.snapshot?.accountScope, "account-b")
        XCTAssertEqual(state.snapshot?.windows.first?.remainingPercent, 90); XCTAssertEqual(firstStops, 1)
        await monitor.configure(home: replacement, customPath: "another-cli", enabled: true, context: 3)
        let changedPath = await monitor.currentState(); XCTAssertNil(changedPath.snapshot)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        await monitor.configure(home: replacement, customPath: "another-cli", enabled: false, context: 4)
        await monitor.refreshIfDue(expanded: true, force: true)
        let disabled = await monitor.currentState(), made = await factory.paths.count, stopped = await second.shutdowns
        XCTAssertNil(disabled.snapshot); XCTAssertTrue(disabled.history.cycles.isEmpty)
        XCTAssertEqual(made, 3); XCTAssertEqual(stopped, 2)
        await monitor.stop()
    }

    func testRevokingQueuedRefreshPreventsDiscoveryAndProcessCreation() async throws {
        let clock = QuotaTestClock(), gate = QuotaPublishGate()
        let factory = QuotaTestFactory([QuotaTestConnection(.success(try reading(clock)))])
        let monitor = CodexQuotaMonitor(services: .init(makeClient: { try await factory.make($0, $1) }, history: nil),
            now: { clock.date() }, output: { state in
                if state.context == 1 && state.refreshing { await gate.pause() }
            })
        let home = URL(fileURLWithPath: "/synthetic/a")
        await configure(monitor, home: home)
        await monitor.refreshIfDue(expanded: true)
        try await until { await gate.waiting }
        await monitor.configure(home: home, customPath: "", enabled: false, context: 2)
        await gate.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        let made = await factory.paths.count; XCTAssertEqual(made, 0)
        await monitor.stop()
    }

    func testVerifiedAccountChangesAndUnverifiedReadingsNeverMixHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-quota-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = QuotaTestClock(), connection = QuotaTestConnection(.success(try reading(QuotaTestClock())), scope: "account-a")
        let store = QuotaHistoryStore(directory: root), monitor = monitor(QuotaTestFactory([connection]), clock: clock, store: store)
        let home = root.appendingPathComponent("home")
        await configure(monitor, home: home)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        let initial = await monitor.currentState(); XCTAssertEqual(initial.history.accountScope, "account-a")
        await connection.set(.failure(.server(method: "account/rateLimits/read", code: 503, message: "fixture")), scope: "account-b")
        await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let changed = await monitor.currentState(); XCTAssertNil(changed.snapshot); XCTAssertTrue(changed.history.cycles.isEmpty)
        XCTAssertEqual(changed.failure, .init(kind: "server", method: "account/rateLimits/read", code: 503))
        clock.advance(31)
        await connection.set(.success(try reading(clock, remaining: 60, scope: "account-b")), scope: "account-b")
        await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let verified = await monitor.currentState()
        XCTAssertEqual(verified.history.accountScope, "account-b"); XCTAssertEqual(verified.history.cycles.first?.points.count, 1)
        await connection.set(.success(try reading(clock, remaining: 50, scope: nil)), scope: nil)
        await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let unverified = await monitor.currentState()
        XCTAssertEqual(unverified.snapshot?.windows.first?.remainingPercent, 50)
        XCTAssertTrue(unverified.history.cycles.isEmpty); XCTAssertEqual(unverified.warning, L10n.text("quota.no_identity"))
        XCTAssertNil(unverified.failure)
        await connection.set(.failure(.notLoggedIn), scope: nil)
        await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let signedOut = await monitor.currentState(); XCTAssertNil(signedOut.snapshot); XCTAssertTrue(signedOut.history.cycles.isEmpty)
        await monitor.stop()
        let cache = QuotaCycleCache(directory: root)
        XCTAssertNil(cache.load(home: home, accountScope: "account-a", now: clock.date()))
        XCTAssertEqual(cache.load(home: home, accountScope: "account-b", now: clock.date())?.0.windows.first?.remainingPercent, 60)
    }

    func testOnlyVerifiedScopeRestoresCacheAndShutdownFlushesLatestReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-quota-flush-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = QuotaTestClock(), home = root.appendingPathComponent("home"), store = QuotaHistoryStore(directory: root)
        let cached = try reading(clock); var history = QuotaCycleHistory(); history.record(cached)
        let saved = await store.save(home: home, snapshot: cached, history: history, now: clock.date()); XCTAssertTrue(saved)
        clock.advance(60)
        let connection = QuotaTestConnection(.failure(.timeout(method: "account/rateLimits/read", seconds: 1)), scope: "account-a")
        let monitor = monitor(QuotaTestFactory([connection]), clock: clock, store: store)
        await configure(monitor, home: home)
        let beforeVerification = await monitor.currentState(); XCTAssertNil(beforeVerification.snapshot)
        await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        let restored = await monitor.currentState(); XCTAssertEqual(restored.snapshot, cached); XCTAssertNotNil(restored.error)
        XCTAssertEqual(restored.failure, .init(kind: "timeout", method: "account/rateLimits/read"))
        let latest = try reading(clock, remaining: 70)
        await connection.set(.success(latest), scope: "account-a")
        await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        XCTAssertEqual(QuotaCycleCache(directory: root).load(home: home, accountScope: "account-a", now: clock.date())?.0, cached)
        await monitor.stop()
        XCTAssertEqual(QuotaCycleCache(directory: root).load(home: home, accountScope: "account-a", now: clock.date())?.0, latest)
    }

    func testEngineRetryQuotaReconnectsAndPublishesRecoveryStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-quota-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = QuotaTestClock(), capture = QuotaEngineCapture()
        let first = QuotaTestConnection(.failure(.notLoggedIn))
        let second = QuotaTestConnection(.success(try reading(clock, remaining: 65)))
        let factory = QuotaTestFactory([first, second])
        let runtime = EngineRuntime(demo: false, now: { clock.date() }, dismissalStore: nil,
            quotaServices: .init(makeClient: { try await factory.make($0, $1) }, history: nil), output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        let home = root.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        _ = await runtime.receive(try command("initialize", ["codexHome": home, "enabledProviders": ["codex"]]))
        try await until { capture.last()?.quotaDashboard?.providers.first?.status?.state == .error }
        XCTAssertEqual(capture.last()?.quotaDashboard?.providers.first?.status?.actions.map(\.kind), [.retry, .settings])
        _ = await runtime.receive(try command("retryQuota", ["provider": "claude"]))
        let before = await factory.paths.count; XCTAssertEqual(before, 1)
        _ = await runtime.receive(try command("retryQuota", ["provider": "codex"]))
        try await until { capture.last()?.quota.first?.windows.first?.remainingPercent == 65 }
        XCTAssertEqual(capture.last()?.quotaDashboard?.providers.first?.status?.state, .hidden)
        let attempts = await factory.paths.count; XCTAssertEqual(attempts, 2)
        let released = await first.shutdowns; XCTAssertEqual(released, 1)
        _ = await runtime.receive(try command("configure", ["enabledProviders": []]))
        _ = await runtime.receive(try command("retryQuota", ["provider": "codex"]))
        let reads = await second.reads; XCTAssertEqual(reads, 1)
        XCTAssertTrue(capture.last()?.quota.isEmpty == true)
        await runtime.stop()
    }

    func testQuotaReadFailureUsesTheSharedUndimmedCollapsedRing() async throws {
        let clock = QuotaTestClock(), capture = QuotaEngineCapture()
        let client = QuotaTestConnection(.success(try reading(clock)), scope: "account-a")
        let runtime = EngineRuntime(demo: false, now: { clock.date() },
            quotaServices: .init(makeClient: { _, _ in client }, history: nil), output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": method, "method": method, "params": params])
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        try await until { capture.last()?.quota.first?.windows.first?.remainingPercent == 80 }
        await client.set(.failure(.disconnected), scope: "account-a")
        _ = await runtime.receive(try command("retryQuota", ["provider": "codex"]))
        try await until { capture.last()?.compactContext?.sources.first?.failed == true }
        let context = try XCTUnwrap(capture.last()?.compactContext)
        XCTAssertNotNil(context.sources.first?.snapshot, "A verified account keeps its last reading")
        let request = CompactBarPresentation.Request(providers: [.codex], context: context)
        let presentation = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertNil(presentation.rings.first?.remaining, "A failed reading stays unknown")
        XCTAssertEqual(presentation.rings.first?.dimmed, false, "Failure alone does not make the shared ring stale")
        await runtime.stop()
    }

    func testEngineKeepsLogCommandsResponsiveDuringQuotaAndClearsOldSourceValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-quota-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = QuotaTestClock(), capture = QuotaEngineCapture()
        let first = QuotaTestConnection(.success(try reading(clock, remaining: 75)), blocked: true)
        let second = QuotaTestConnection(.success(try reading(clock, remaining: 90, scope: "account-b")))
        let factory = QuotaTestFactory([first, second])
        let runtime = EngineRuntime(demo: false, now: { clock.date() }, dismissalStore: nil,
            quotaServices: .init(makeClient: { try await factory.make($0, $1) }, history: nil), output: { capture.append($0) })
        let home = root.appendingPathComponent("first"), replacement = root.appendingPathComponent("second")
        let identifier = UUID().uuidString.lowercased()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: clock.date()))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func record(_ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: clock.date()), "type": type, "payload": payload]) + Data([10])
        }
        let file = day.appendingPathComponent("rollout-" + identifier + ".jsonl")
        try (record("session_meta", ["id": identifier, "source": "cli", "cwd": "/synthetic"]) +
            record("event_msg", ["type": "task_started", "turn_id": identifier])).write(to: file)
        func path(_ url: URL) -> String { url.withUnsafeFileSystemRepresentation { String(cString: $0!) } }
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        _ = await runtime.receive(try command("initialize", ["codexHome": path(home), "enabledProviders": ["codex"]]))
        try await until { await first.reads == 1 }
        XCTAssertEqual(capture.last()?.runningCount, 1); XCTAssertTrue(capture.last()?.quota.isEmpty == true)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd(); try writer.write(contentsOf: record("event_msg", ["type": "task_complete", "turn_id": identifier])); try writer.close()
        _ = await runtime.receive(try command("refresh"))
        XCTAssertTrue(capture.last()?.tasks.contains { $0.sessionID == identifier && $0.phase == "completed" && $0.unread } == true)
        let coalesced = await first.reads; XCTAssertEqual(coalesced, 1)
        await first.release()
        try await until { capture.last()?.quota.first?.windows.first?.remainingPercent == 75 }
        XCTAssertTrue(capture.last()?.sources.contains { $0.id == "codex:quota" && $0.available } == true)
        let history = try XCTUnwrap(capture.last()?.quotaDashboard?.providers.first?.history)
        XCTAssertEqual(history.chart?.points.last?.remaining, 75)
        XCTAssertEqual(history.chart?.points.count, 1)
        let accountContext = try XCTUnwrap(history.account?.context)
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        XCTAssertEqual(capture.last()?.quotaDashboard?.providers.first?.history?.account?.context, accountContext)
        _ = await runtime.receive(try command("configure", ["codexHome": path(replacement)]))
        try await until { capture.last()?.quota.first?.windows.first?.remainingPercent == 90 }
        let changedHistory = try XCTUnwrap(capture.last()?.quotaDashboard?.providers.first?.history)
        XCTAssertEqual(changedHistory.chart?.points.map(\.remaining), [90])
        XCTAssertNotEqual(changedHistory.account?.context, accountContext)
        XCTAssertTrue(capture.last()?.tasks.isEmpty == true)
        _ = await runtime.receive(try command("configure", ["enabledProviders": []]))
        XCTAssertTrue(capture.last()?.quota.isEmpty == true); XCTAssertTrue(capture.last()?.sources.isEmpty == true)
        await runtime.stop()
        let stopped = capture.count()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(capture.count(), stopped)
    }
}
