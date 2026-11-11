import Foundation
import XCTest
@testable import PacerCore

private final class SlowReplyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor SlowReplyConnection: CodexQuotaConnection {
    private var result: Result<QuotaSnapshot, CodexClientError>
    private var scope: String?
    private(set) var reads = 0, shutdowns = 0
    init(_ result: Result<QuotaSnapshot, CodexClientError>, scope: String?) { self.result = result; self.scope = scope }
    func set(_ result: Result<QuotaSnapshot, CodexClientError>, scope: String?) { self.result = result; self.scope = scope }
    func readQuota() throws -> QuotaSnapshot { reads += 1; return try result.get() }
    func currentAccountScope() -> String? { scope }
    func shutdown() { shutdowns += 1 }
}

private actor SlowReplyFactory {
    private let connection: SlowReplyConnection
    private(set) var made = 0
    init(_ connection: SlowReplyConnection) { self.connection = connection }
    func make() -> any CodexQuotaConnection { made += 1; return connection }
}

/// A quota reply that takes too long is not an outage the user must act on.
final class CodexQuotaSlowReplyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/synthetic/slow-quota")
    private let slow = CodexClientError.timeout(method: "account/rateLimits/read", seconds: 30)

    private func reading(_ clock: SlowReplyClock, used: Int = 20, scope: String? = "synthetic-account-a") throws -> QuotaSnapshot {
        let bytes = Data(#"{"rateLimits":{"secondary":{"usedPercent":\#(used),"windowDurationMins":10080,"resetsAt":1800500000}}}"#.utf8)
        var value = try QuotaSnapshot.decode(bytes, capturedAt: clock.now())
        value.accountScope = scope
        return value
    }
    private func coordinator(_ factory: SlowReplyFactory, clock: SlowReplyClock, store: QuotaHistoryStore? = nil) async -> CodexQuotaCoordinator {
        let coordinator = CodexQuotaCoordinator(services: .init(makeClient: { _, _ in await factory.make() }, history: store),
            now: { clock.now() }, output: { _ in })
        await coordinator.configure(home: home, customPath: "", enabled: true, context: 1)
        return coordinator
    }
    private func ring(_ state: CodexQuotaState, _ clock: SlowReplyClock) -> QuotaDashboardPresentation.Reading {
        .init(provider: .codex, period: .weekly, snapshot: state.snapshot, failed: state.error != nil, refreshing: state.refreshing, now: clock.now())
    }

    func testSlowReplyKeepsTheLastReadingAndCadenceUntilItIsTenMinutesOld() async throws {
        for expanded in [false, true] {
            let clock = SlowReplyClock(), first = try reading(clock)
            let connection = SlowReplyConnection(.success(first), scope: first.accountScope), factory = SlowReplyFactory(connection)
            let quota = await coordinator(factory, clock: clock)
            await quota.refreshIfDue(expanded: expanded); await quota.waitForRefresh()
            let shown = ring(await quota.currentState(), clock)
            XCTAssertEqual(shown.availability, .available)

            await connection.set(.failure(slow), scope: first.accountScope)
            let cadence = ProviderQuotaRefreshPolicy.interval(expanded: expanded, failures: 0)
            var attempts = 1
            while clock.now().timeIntervalSince(first.capturedAt) + cadence < QuotaSnapshot.staleInterval {
                clock.advance(cadence - 1)
                await quota.refreshIfDue(expanded: expanded); await quota.waitForRefresh()
                let early = await connection.reads
                XCTAssertEqual(early, attempts, "A slow reply cannot pull the next reading forward")
                clock.advance(1)
                await quota.refreshIfDue(expanded: expanded); await quota.waitForRefresh()
                attempts += 1
                let reads = await connection.reads, state = await quota.currentState()
                XCTAssertEqual(reads, attempts, "A slow reply cannot push the next reading back")
                XCTAssertEqual(state.snapshot, first); XCTAssertNil(state.error); XCTAssertNil(state.failure)
                XCTAssertEqual(state.failureCount, 0)
                let now = ring(state, clock)
                XCTAssertEqual(now.availability, .available, "Nothing on screen changes for a slow reply")
                XCTAssertEqual(now.remainingPercent, shown.remainingPercent); XCTAssertEqual(now.pacePercent != nil, shown.pacePercent != nil)
                XCTAssertEqual(QuotaConnectionPresentation(provider: .codex, snapshot: state.snapshot, error: state.error, refreshing: false).state, .hidden)
            }
            let made = await factory.made, shutdowns = await connection.shutdowns
            XCTAssertEqual(made, 1); XCTAssertEqual(shutdowns, 0, "The client reconnects itself and keeps the verified account")

            clock.advance(QuotaSnapshot.staleInterval + 1 - clock.now().timeIntervalSince(first.capturedAt))
            let late = await quota.currentState()
            XCTAssertNil(late.error, "Ten minutes without data only marks the reading")
            XCTAssertEqual(ring(late, clock).availability, .stale)
            XCTAssertEqual(QuotaConnectionPresentation(provider: .codex, snapshot: late.snapshot, error: late.error, refreshing: false).state, .hidden)
            XCTAssertEqual(CompactWarningPresentation.items(enabled: [.codex], warnings: [.quotaDelay], snapshots: [.codex: try XCTUnwrap(late.snapshot)],
                failed: late.error == nil ? [] : [.codex], now: clock.now()).map(\.solid), [false], "The collapsed bar gets the quiet late-update mark")

            let next = try reading(clock, used: 30)
            await connection.set(.success(next), scope: next.accountScope)
            await quota.refreshIfDue(expanded: expanded, force: true); await quota.waitForRefresh()
            let recovered = await quota.currentState()
            XCTAssertEqual(recovered.snapshot, next); XCTAssertEqual(ring(recovered, clock).availability, .available)
            await quota.stop()
        }
    }

    func testSlowReplyRestoresTheVerifiedAccountsSavedReadingQuietly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-slow-quota-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = SlowReplyClock(), store = QuotaHistoryStore(directory: root), saved = try reading(clock)
        var history = QuotaCycleHistory(); history.record(saved)
        let stored = await store.save(home: home, snapshot: saved, history: history, now: clock.now()); XCTAssertTrue(stored)
        clock.advance(60)
        let connection = SlowReplyConnection(.failure(slow), scope: saved.accountScope)
        let quota = await coordinator(SlowReplyFactory(connection), clock: clock, store: store)
        await quota.refreshIfDue(expanded: true); await quota.waitForRefresh()
        let state = await quota.currentState()
        XCTAssertEqual(state.snapshot, saved); XCTAssertNil(state.error); XCTAssertEqual(state.failureCount, 0)
        await quota.stop()
    }

    func testSlowReplyStillReportsWhenNoReadingOfTheVerifiedAccountExists() async throws {
        let clock = SlowReplyClock(), first = try reading(clock)
        for (scope, label) in [(nil, "unverified account"), ("synthetic-account-b", "another account")] as [(String?, String)] {
            let connection = SlowReplyConnection(.success(first), scope: first.accountScope)
            let quota = await coordinator(SlowReplyFactory(connection), clock: clock)
            await quota.refreshIfDue(expanded: true); await quota.waitForRefresh()
            await connection.set(.failure(slow), scope: scope)
            await quota.refreshIfDue(expanded: true, force: true); await quota.waitForRefresh()
            let state = await quota.currentState()
            XCTAssertNil(state.snapshot, label); XCTAssertNotNil(state.error, label)
            XCTAssertEqual(state.failure, .init(kind: "timeout", method: "account/rateLimits/read"), label)
            XCTAssertEqual(state.failureCount, 1, label)
            await quota.stop()
        }
        let connection = SlowReplyConnection(.failure(slow), scope: first.accountScope)
        let quota = await coordinator(SlowReplyFactory(connection), clock: clock)
        await quota.refreshIfDue(expanded: true); await quota.waitForRefresh()
        let empty = await quota.currentState()
        XCTAssertNil(empty.snapshot); XCTAssertNotNil(empty.error, "With nothing to keep, the reason is shown")
        await quota.stop()
    }

    func testOtherFailuresKeepTheirVisibleErrorAndBackoff() async throws {
        let clock = SlowReplyClock(), first = try reading(clock)
        let connection = SlowReplyConnection(.success(first), scope: first.accountScope), factory = SlowReplyFactory(connection)
        let quota = await coordinator(factory, clock: clock)
        await quota.refreshIfDue(expanded: true); await quota.waitForRefresh()
        await connection.set(.failure(.server(method: "account/rateLimits/read", code: -32000, message: "synthetic")), scope: first.accountScope)
        await quota.refreshIfDue(expanded: true, force: true); await quota.waitForRefresh()
        let state = await quota.currentState(), made = await factory.made, shutdowns = await connection.shutdowns
        XCTAssertEqual(state.snapshot, first); XCTAssertNotNil(state.error); XCTAssertEqual(state.failureCount, 1)
        XCTAssertEqual(ring(state, clock).availability, .stale)
        XCTAssertEqual(made, 1); XCTAssertEqual(shutdowns, 1, "Other failures still replace the client")
        await quota.stop()
    }
}

private actor SlowClaudeConnection: ClaudeQuotaConnection {
    private var result: Result<QuotaSnapshot, ClaudeQuotaError>
    private var scope: String?
    private(set) var reads = 0
    init(_ result: Result<QuotaSnapshot, ClaudeQuotaError>, scope: String?) { self.result = result; self.scope = scope }
    func set(_ result: Result<QuotaSnapshot, ClaudeQuotaError>, scope: String?) { self.result = result; self.scope = scope }
    func readQuota() throws -> QuotaSnapshot { reads += 1; return try result.get() }
    func currentAccountScope() -> String? { scope }
    func currentSource() -> ClaudeQuotaSource? { .webSession }
    func organizations() -> [ClaudeWebOrganization] { [] }
    func nextRetryAt() -> Date? { nil }
    func shutdown() {}
}

private final class SlowBalanceReads: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Result<DeepSeekBalance, DeepSeekBalanceError>
    private(set) var count = 0
    init(_ next: Result<DeepSeekBalance, DeepSeekBalanceError>) { self.next = next }
    func set(_ value: Result<DeepSeekBalance, DeepSeekBalanceError>) { lock.lock(); next = value; lock.unlock() }
    func read() throws -> DeepSeekBalance { lock.lock(); defer { lock.unlock() }; count += 1; return try next.get() }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// The same rule for Claude's quota and DeepSeek's balance.
final class ClaudeAndDeepSeekSlowReplyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/synthetic/slow-quota")

    func testClaudeSlowReplyKeepsTheReadingCadenceAndScreen() async throws {
        let clock = SlowReplyClock()
        let bytes = Data(#"{"rateLimits":{"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1800500000}}}"#.utf8)
        var first = try QuotaSnapshot.decode(bytes, capturedAt: clock.now()); first.accountScope = "synthetic-claude-a"
        let connection = SlowClaudeConnection(.success(first), scope: first.accountScope)
        let quota = ClaudeQuotaCoordinator(services: .init(makeClient: { _, _, _ in connection }, history: nil), webAvailable: true,
            now: { clock.now() }, output: { _ in })
        await quota.configure(home: home, organization: "", enabled: true, context: 1)
        _ = await quota.refreshIfDue(expanded: false); await quota.waitForRefresh()

        await connection.set(.failure(.timedOut), scope: first.accountScope)
        clock.advance(ProviderQuotaRefreshPolicy.interval(expanded: false, failures: 0))
        _ = await quota.refreshIfDue(expanded: false); await quota.waitForRefresh()
        let slow = await quota.currentState()
        XCTAssertEqual(slow.snapshot, first); XCTAssertNil(slow.error); XCTAssertNil(slow.failure); XCTAssertEqual(slow.failureCount, 0)
        clock.advance(ProviderQuotaRefreshPolicy.interval(expanded: false, failures: 0))
        let next = await quota.refreshIfDue(expanded: false); await quota.waitForRefresh()
        XCTAssertTrue(next, "A slow reply cannot push the next reading back")
        XCTAssertEqual(QuotaDashboardPresentation.Reading(provider: .claude, period: .weekly, snapshot: slow.snapshot,
            failed: slow.error != nil, now: clock.now()).availability, .available, "Under ten minutes the reading looks current")

        await connection.set(.failure(.connectionFailed), scope: first.accountScope)
        _ = await quota.refreshIfDue(expanded: false, force: true); await quota.waitForRefresh()
        let failed = await quota.currentState()
        XCTAssertEqual(failed.snapshot, first); XCTAssertEqual(failed.failure, .connectionFailed); XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.failureCount, 1, "Other failures keep their visible error and backoff")

        await connection.set(.failure(.timedOut), scope: nil)
        _ = await quota.refreshIfDue(expanded: false, force: true); await quota.waitForRefresh()
        let unverified = await quota.currentState()
        XCTAssertNil(unverified.snapshot); XCTAssertEqual(unverified.failure, .timedOut, "An unverified account cannot keep a reading")
        await quota.stop()
    }

    func testDeepSeekSlowReplyKeepsTheBalanceCadenceAndScreen() async throws {
        let clock = SlowReplyClock(), fingerprint = String(repeating: "7", count: 64)
        let balance = DeepSeekBalance(total: 42, capturedAt: clock.now(), source: .web, sessionFingerprint: fingerprint)
        let reads = SlowBalanceReads(.success(balance))
        let salts = DeepSeekHistoryCredential(loadSalt: { Data(repeating: 7, count: 32) }, saveSalt: { _ in })
        let services = DeepSeekBalanceServices(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
            readAPI: { _ in throw DeepSeekBalanceError.connectionFailed }, fingerprint: { salts.fingerprint(source: $0, identity: $1) },
            readWeb: { _ in try reads.read() }, detect: { _, _ in .account })
        let wallet = DeepSeekBalanceCoordinator(services: services, now: { clock.now() }, output: { _ in })
        await wallet.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
        _ = await wallet.refreshIfDue(active: true, force: true); await wallet.refreshCompletion?.value

        reads.set(.failure(.timedOut))
        let cadence = DeepSeekBalanceCoordinator.refreshInterval(active: true, failures: 0)
        clock.advance(cadence)
        _ = await wallet.refreshIfDue(active: true); await wallet.refreshCompletion?.value
        let slow = await wallet.currentState()
        XCTAssertEqual(slow.balance, balance); XCTAssertNil(slow.error); XCTAssertEqual(slow.failureCount, 0)
        XCTAssertNil(DeepSeekBalanceStatusPresentation(error: slow.error, refreshing: false), "No error line under the dial")
        XCTAssertEqual(DeepSeekWallet(balance: slow.balance, connected: true, ledger: .init(), now: clock.now()).state, .normal)
        clock.advance(cadence)
        let next = await wallet.refreshIfDue(active: true); await wallet.refreshCompletion?.value
        XCTAssertTrue(next, "A slow reply cannot push the next reading back"); XCTAssertEqual(reads.reads, 3)
        clock.advance(QuotaSnapshot.staleInterval + 1 - clock.now().timeIntervalSince(balance.capturedAt))
        XCTAssertEqual(DeepSeekWallet(balance: slow.balance, connected: true, ledger: .init(), now: clock.now()).state, .stale,
            "Ten minutes without a balance only marks it")

        reads.set(.failure(.connectionFailed))
        _ = await wallet.refreshIfDue(active: true, force: true); await wallet.refreshCompletion?.value
        let failed = await wallet.currentState()
        XCTAssertEqual(failed.balance, balance); XCTAssertEqual(failed.error, .connectionFailed); XCTAssertEqual(failed.failureCount, 1)
        await wallet.stop()

        let empty = DeepSeekBalanceCoordinator(services: services, now: { clock.now() }, output: { _ in })
        reads.set(.failure(.timedOut))
        await empty.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 2)
        _ = await empty.refreshIfDue(active: true, force: true); await empty.refreshCompletion?.value
        let nothing = await empty.currentState()
        XCTAssertNil(nothing.balance); XCTAssertEqual(nothing.error, .timedOut, "With no balance to keep, the reason is shown")
        XCTAssertNotNil(DeepSeekBalanceStatusPresentation(error: nothing.error, refreshing: false))
        await empty.stop()
    }

    func testDeepSeekKeyReadsTellASlowReplyFromAnUnreachableService() async throws {
        for (code, expected) in [(URLError.Code.timedOut, DeepSeekBalanceError.timedOut), (.notConnectedToInternet, .connectionFailed)] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FailingBalanceProtocol.self]
            FailingBalanceProtocol.code = code
            let session = URLSession(configuration: configuration)
            do { _ = try await DeepSeekAPIBalanceClient.read(key: "sk-synthetic-key-0000", session: session); XCTFail("expected \(expected)") }
            catch { XCTAssertEqual(error as? DeepSeekBalanceError, expected) }
            session.invalidateAndCancel()
        }
        XCTAssertFalse(DeepSeekBalanceError.timedOut.needsConnection)
        XCTAssertNotEqual(DeepSeekBalanceError.timedOut.errorDescription, DeepSeekBalanceError.connectionFailed.errorDescription)
    }
}

private final class FailingBalanceProtocol: URLProtocol {
    nonisolated(unsafe) static var code = URLError.Code.timedOut
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}
