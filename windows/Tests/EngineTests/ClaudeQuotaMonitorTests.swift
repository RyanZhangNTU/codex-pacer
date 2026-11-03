@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class ClaudeMonitorClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
private actor ClaudeMonitorClient: ClaudeQuotaConnection {
    var result: Result<QuotaSnapshot, ClaudeQuotaError>, scope: String?
    var retry: Date?, choices: [ClaudeWebOrganization] = []
    var blocked = false, ignoresShutdown = false
    private var pending: CheckedContinuation<QuotaSnapshot, Error>?
    private(set) var reads = 0, shutdowns = 0
    init(_ snapshot: QuotaSnapshot, blocked: Bool = false, ignoresShutdown: Bool = false) {
        result = .success(snapshot); scope = snapshot.accountScope; self.blocked = blocked; self.ignoresShutdown = ignoresShutdown
    }
    func readQuota() async throws -> QuotaSnapshot {
        reads += 1
        if blocked { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try result.get()
    }
    func set(_ result: Result<QuotaSnapshot, ClaudeQuotaError>, scope: String?, retry: Date? = nil, choices: [ClaudeWebOrganization] = []) {
        self.result = result; self.scope = scope; self.retry = retry; self.choices = choices
    }
    func currentAccountScope() -> String? { scope }
    func organizations() -> [ClaudeWebOrganization] { choices }
    func currentSource() -> ClaudeQuotaSource? { scope == nil ? nil : .webSession }
    func nextRetryAt() -> Date? { retry }
    func release() { blocked = false; let previous = pending; pending = nil; previous?.resume(with: result.mapError { $0 as Error }) }
    func shutdown() { shutdowns += 1; if !ignoresShutdown { let previous = pending; pending = nil; previous?.resume(throwing: CancellationError()) } }
}
private actor ClaudeMonitorFactory {
    private var clients: [ClaudeMonitorClient]; private(set) var calls = 0
    init(_ clients: [ClaudeMonitorClient]) { self.clients = clients }
    func make() throws -> any ClaudeQuotaConnection {
        calls += 1; guard !clients.isEmpty else { throw ClaudeQuotaError.connectionFailed }; return clients.removeFirst()
    }
}

final class ClaudeQuotaMonitorTests: XCTestCase {
    private func snapshot(_ account: String, percent: Double = 25) throws -> QuotaSnapshot {
        try ClaudeQuotaDecoder.decodeUsage(Data(("{\"five_hour\":{\"utilization\":\(percent),\"resets_at\":1800001800},\"seven_day\":{\"utilization\":30,\"resets_at\":1800604800}}").utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), accountScope: ClaudeQuotaDecoder.digest(account))
    }
    private var home: URL { FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-claude-monitor") }
    func testNativeQuotaPollingCapsTheFailureCounterAtFour() {
        XCTAssertEqual((0...6).map { ProviderQuotaRefreshPolicy.interval(expanded: true, failures: $0) }, [30, 60, 120, 240, 480, 480, 480])
        XCTAssertEqual((0...4).map { ProviderQuotaRefreshPolicy.interval(expanded: false, failures: $0) }, [120, 240, 480, 600, 600])
        XCTAssertEqual(CodexQuotaMonitor.refreshInterval(expanded: true, failures: 5), 480)
        XCTAssertEqual(ProviderQuotaRefreshPolicy.interval(expanded: true, failures: Int.max), 480)
        XCTAssertEqual(ProviderQuotaRefreshPolicy.interval(expanded: true, failures: -1), 30)
    }
    func testClientAndVerifiedQuotaSurviveTransientErrorsAndScopedRetryAfterIsRespected() async throws {
        let clock = ClaudeMonitorClock(), reading = try snapshot("first"), client = ClaudeMonitorClient(try snapshot("first"))
        let factory = ClaudeMonitorFactory([client]), monitor = ClaudeQuotaMonitor(services: .init(makeClient: { _, _, _ in try await factory.make() }, history: nil), now: { clock.now() }, output: { _ in })
        await monitor.configure(home: home, organization: "", enabled: true, context: 1)
        let beforeHost = await monitor.refreshIfDue(expanded: true); XCTAssertFalse(beforeHost)
        await monitor.setWebAvailable(true)
        let first = await monitor.refreshIfDue(expanded: true); XCTAssertTrue(first); await monitor.waitForRefresh()
        await client.set(.failure(.unavailable), scope: reading.accountScope)
        _ = await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let failed = await monitor.currentState(); XCTAssertEqual(failed.failure, .unavailable); XCTAssertEqual(failed.snapshot, reading)
        await client.set(.failure(.unavailable), scope: reading.accountScope, retry: clock.now().addingTimeInterval(900))
        clock.advance(600)
        let throttled = await monitor.refreshIfDue(expanded: true, force: true); XCTAssertFalse(throttled)
        clock.advance(301); await client.set(.success(reading), scope: reading.accountScope)
        _ = await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let restored = await monitor.currentState(), calls = await factory.calls, shutdowns = await client.shutdowns
        XCTAssertNil(restored.failure); XCTAssertEqual(restored.snapshot, reading); XCTAssertEqual(calls, 1); XCTAssertEqual(shutdowns, 0)
        await monitor.stop()
    }
    func testLostOwnerClearsQuotaAndWorkspaceChoicesRemainAvailableWithoutGuessing() async throws {
        let client = ClaudeMonitorClient(try snapshot("first"))
        let monitor = ClaudeQuotaMonitor(services: .init(makeClient: { _, _, _ in client }, history: nil), output: { _ in })
        await monitor.configure(home: home, organization: "", enabled: true, context: 1); await monitor.setWebAvailable(true)
        _ = await monitor.refreshIfDue(expanded: false); await monitor.waitForRefresh()
        let choices = [ClaudeWebOrganization(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Synthetic workspace")]
        await client.set(.failure(.organizationSelectionRequired), scope: nil, choices: choices)
        _ = await monitor.refreshIfDue(expanded: false, force: true); await monitor.waitForRefresh()
        let state = await monitor.currentState()
        XCTAssertNil(state.snapshot); XCTAssertNil(state.history.accountScope); XCTAssertEqual(state.organizations, choices)
        XCTAssertEqual(state.failure, .organizationSelectionRequired); XCTAssertNil(state.source)
        await monitor.stop()
    }
    func testSameSourceWithDifferentVerifiedAccountRebindsItsHistory() async throws {
        let first = try snapshot("first"), second = try snapshot("second", percent: 55), client = ClaudeMonitorClient(try snapshot("first"))
        let monitor = ClaudeQuotaMonitor(services: .init(makeClient: { _, _, _ in client }, history: nil), output: { _ in })
        await monitor.configure(home: home, organization: "", enabled: true, context: 1); await monitor.setWebAvailable(true)
        _ = await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh()
        let previous = await monitor.currentState(); XCTAssertEqual(previous.history.accountScope, first.accountScope)
        await client.set(.success(second), scope: second.accountScope)
        _ = await monitor.refreshIfDue(expanded: true, force: true); await monitor.waitForRefresh()
        let changed = await monitor.currentState(); XCTAssertEqual(changed.history.accountScope, second.accountScope); XCTAssertEqual(changed.snapshot, second)
        await monitor.stop()
    }
    func testChangingSourceRevokesLateReadAndDisablingTheWebHostClearsItsBinding() async throws {
        let old = ClaudeMonitorClient(try snapshot("old"), blocked: true, ignoresShutdown: true), fresh = ClaudeMonitorClient(try snapshot("fresh", percent: 55))
        let factory = ClaudeMonitorFactory([old, fresh])
        let monitor = ClaudeQuotaMonitor(services: .init(makeClient: { _, _, _ in try await factory.make() }, history: nil), output: { _ in })
        await monitor.configure(home: home, organization: "", enabled: true, context: 1); await monitor.setWebAvailable(true)
        _ = await monitor.refreshIfDue(expanded: true)
        for _ in 0..<200 { if await old.reads > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let previous = await monitor.currentState()
        await monitor.configure(home: home.appendingPathComponent("other"), organization: "", enabled: true, context: 2)
        _ = await monitor.refreshIfDue(expanded: true); await monitor.waitForRefresh(); await old.release()
        try await Task.sleep(nanoseconds: 5_000_000)
        let state = await monitor.currentState()
        XCTAssertEqual(state.snapshot?.accountScope, ClaudeQuotaDecoder.digest("fresh")); XCTAssertEqual(state.context, 2)
        XCTAssertNotEqual(state.connectionContext, previous.connectionContext)
        await monitor.setWebAvailable(false)
        let closed = await monitor.currentState()
        XCTAssertNil(closed.snapshot); XCTAssertFalse(closed.refreshing); XCTAssertNotEqual(closed.connectionContext, state.connectionContext)
        await monitor.stop()
    }
}
