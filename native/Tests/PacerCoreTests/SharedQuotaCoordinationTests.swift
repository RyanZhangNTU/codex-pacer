import Foundation
import XCTest
@testable import PacerCore

private final class CoordinationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor CoordinationClient: ClaudeQuotaConnection {
    let snapshot: QuotaSnapshot
    private var failing = true
    private(set) var reads = 0
    init(_ snapshot: QuotaSnapshot) { self.snapshot = snapshot }
    func readQuota() throws -> QuotaSnapshot {
        reads += 1
        if failing { throw ClaudeQuotaError.notLoggedIn }
        return snapshot
    }
    func succeed() { failing = false }
    func currentAccountScope() -> String? { failing ? nil : snapshot.accountScope }
    func currentSource() -> ClaudeQuotaSource? { .statusLine }
    func organizations() -> [ClaudeWebOrganization] { [] }
    func nextRetryAt() -> Date? { nil }
    func shutdown() {}
}

private actor CoordinationCounts {
    private var values: [String: Int] = [:]
    func add(_ key: String) { values[key, default: 0] += 1 }
    func count(_ key: String) -> Int { values[key, default: 0] }
}

private actor CoordinationGate<Value: Sendable> {
    private var pending: CheckedContinuation<Value, Never>?
    private(set) var waiting = false
    func wait() async -> Value { await withCheckedContinuation { waiting = true; pending = $0 } }
    func release(_ value: Value) { let old = pending; pending = nil; old?.resume(returning: value) }
}

private actor BalancePublicationRecorder {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var waiting = false
    private(set) var values: [DeepSeekBalanceState] = []
    func publish(_ state: DeepSeekBalanceState) async {
        if state.refreshing && !released {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        values.append(state)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class SharedQuotaCoordinationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/synthetic/shared-quota")
    private func snapshot() throws -> QuotaSnapshot {
        let bytes = Data(#"{"rateLimits":{"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1800500000}}}"#.utf8)
        var value = try QuotaSnapshot.decode(bytes, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        value.accountScope = "synthetic-verified-scope"
        return value
    }
    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The controlled shared operation did not reach its boundary")
        throw CancellationError()
    }

    func testBalanceReadCannotOvertakeItsPendingPublication() async throws {
        let recorder = BalancePublicationRecorder(), reads = CoordinationCounts(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = DeepSeekBalanceCoordinator(services: .init(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
            readAPI: { _ in throw DeepSeekBalanceError.missingKey },
            readWeb: { _ in await reads.add("read"); return .init(total: 42, capturedAt: date, source: .web) }, detect: { _, _ in .account }),
            now: { date }, output: { await recorder.publish($0) })
        await coordinator.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
        let starting = Task { await coordinator.refreshIfDue(active: true) }
        do { try await until { await recorder.waiting } }
        catch { await recorder.release(); _ = await starting.value; await coordinator.stop(); throw error }
        let earlyRead = await coordinator.refreshCompletion
        XCTAssertNil(earlyRead, "No reader can run while its pending state is still held at the host boundary")
        let earlyCount = await reads.count("read")
        XCTAssertEqual(earlyCount, 0)
        // On the previous implementation this completes the immediate reader
        // before releasing pending, reproducing the stale last publication.
        await earlyRead?.value
        await recorder.release()
        let accepted = await starting.value
        await coordinator.refreshCompletion?.value
        let observed = await recorder.values, current = await coordinator.currentState()
        XCTAssertTrue(accepted)
        XCTAssertEqual(observed.last?.balance?.total, 42)
        XCTAssertEqual(observed.last?.refreshing, false)
        XCTAssertEqual(observed.last, current)
        XCTAssertEqual(observed.filter(\.refreshing).count, 1)
        await coordinator.stop()
    }

    func testBalancePendingPublicationKeepsSingleFlightAndCanBeRevokedBeforeIO() async throws {
        for stop in [false, true] {
            let recorder = BalancePublicationRecorder(), reads = CoordinationCounts(), date = Date(timeIntervalSince1970: 1_800_000_000)
            let coordinator = DeepSeekBalanceCoordinator(services: .init(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
                readAPI: { _ in throw DeepSeekBalanceError.missingKey },
                readWeb: { _ in await reads.add("read"); return .init(total: 42, capturedAt: date, source: .web) }, detect: { _, _ in .account }),
                now: { date }, output: { await recorder.publish($0) })
            await coordinator.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
            let starting = Task { await coordinator.refreshIfDue(active: true) }
            do { try await until { await recorder.waiting } }
            catch { await recorder.release(); _ = await starting.value; await coordinator.stop(); throw error }
            let pending = await coordinator.currentState()
            XCTAssertTrue(pending.refreshing)
            let duplicate = await coordinator.refreshIfDue(active: true, force: true)
            XCTAssertFalse(duplicate, "A pending publication still reserves the single flight")
            if stop { await coordinator.stop() }
            else { await coordinator.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 2) }
            await recorder.release()
            let accepted = await starting.value, count = await reads.count("read"), final = await coordinator.currentState()
            XCTAssertTrue(accepted)
            XCTAssertEqual(count, 0, "Revocation during publication cannot start the old reader")
            XCTAssertFalse(final.refreshing)
            XCTAssertNil(final.balance)
            if !stop { XCTAssertEqual(final.source, .apiKey); XCTAssertEqual(final.error, .missingKey) }
            await coordinator.stop()
        }
    }

    func testEveryFailureRetainsMacCadenceThroughTheCapAndRecoveryForBothQuotaProviders() async throws {
        for expanded in [true, false] {
            let clock = CoordinationClock(), codexClient = CoordinationClient(try snapshot()), claudeClient = CoordinationClient(try snapshot())
            let codex = CodexQuotaCoordinator(services: .init(makeClient: { _, _ in codexClient }, history: nil), now: { clock.now() }, output: { _ in })
            let claude = ClaudeQuotaCoordinator(services: .init(makeClient: { _, _, _ in claudeClient }, history: nil), webAvailable: true,
                now: { clock.now() }, output: { _ in })
            await codex.configure(home: home, customPath: "", enabled: true, context: 1)
            await claude.configure(home: home, organization: "", enabled: true, context: 1)
            let intervals: [TimeInterval] = expanded ? [60, 120, 240, 480, 480, 480] : [240, 480, 600, 600, 600, 600]
            await codex.refreshIfDue(expanded: expanded); await codex.waitForRefresh()
            _ = await claude.refreshIfDue(expanded: expanded); await claude.waitForRefresh()
            for (index, interval) in intervals.enumerated() {
                let codexState = await codex.currentState(), claudeState = await claude.currentState()
                XCTAssertEqual(codexState.failureCount, min(index + 1, 4))
                XCTAssertEqual(claudeState.failureCount, min(index + 1, 4))
                clock.advance(interval - 1)
                await codex.refreshIfDue(expanded: expanded); await codex.waitForRefresh()
                let rejected = await claude.refreshIfDue(expanded: expanded)
                XCTAssertFalse(rejected)
                let beforeCodex = await codexClient.reads, beforeClaude = await claudeClient.reads
                XCTAssertEqual(beforeCodex, index + 1); XCTAssertEqual(beforeClaude, index + 1)
                clock.advance(1)
                await codex.refreshIfDue(expanded: expanded); await codex.waitForRefresh()
                let started = await claude.refreshIfDue(expanded: expanded); await claude.waitForRefresh()
                XCTAssertTrue(started)
                let afterCodex = await codexClient.reads, afterClaude = await claudeClient.reads
                XCTAssertEqual(afterCodex, index + 2); XCTAssertEqual(afterClaude, index + 2)
            }
            await codexClient.succeed(); await claudeClient.succeed()
            await codex.refreshIfDue(expanded: expanded, force: true); await codex.waitForRefresh()
            _ = await claude.refreshIfDue(expanded: expanded, force: true); await claude.waitForRefresh()
            let recoveredCodex = await codex.currentState(), recoveredClaude = await claude.currentState()
            XCTAssertEqual(recoveredCodex.failureCount, 0); XCTAssertEqual(recoveredClaude.failureCount, 0)
            XCTAssertEqual(recoveredCodex.snapshot, try snapshot()); XCTAssertEqual(recoveredClaude.snapshot, try snapshot())
            XCTAssertEqual(ProviderQuotaRefreshPolicy.interval(expanded: expanded, failures: 0), expanded ? 30 : 120)
            await codex.stop(); await claude.stop()
        }
    }

    func testSleepReplacementKeepsFailureCapAndLastAttemptRatherThanPollingImmediately() async throws {
        let clock = CoordinationClock(), client = CoordinationClient(try snapshot())
        let old = CodexQuotaCoordinator(services: .init(makeClient: { _, _ in client }, history: nil), now: { clock.now() }, output: { _ in })
        await old.configure(home: home, customPath: "", enabled: true, context: 1)
        for _ in 0..<6 { await old.refreshIfDue(expanded: true, force: true); await old.waitForRefresh() }
        let seed = await old.currentState(); await old.stop()
        let resumedClient = CoordinationClient(try snapshot())
        let resumed = CodexQuotaCoordinator(services: .init(makeClient: { _, _ in resumedClient }, history: nil), seed: seed,
            now: { clock.now() }, output: { _ in })
        await resumed.configure(home: home, customPath: "", enabled: true, context: 2)
        await resumed.refreshIfDue(expanded: true); await resumed.waitForRefresh()
        let before = await resumedClient.reads, state = await resumed.currentState()
        XCTAssertEqual(before, 0); XCTAssertEqual(state.failureCount, 4); XCTAssertEqual(state.lastAttempt, seed.lastAttempt)
        clock.advance(480)
        await resumed.refreshIfDue(expanded: true); await resumed.waitForRefresh()
        let after = await resumedClient.reads; XCTAssertEqual(after, 1)
        await resumed.stop()
    }

    func testPassiveReadWinsWithoutTouchingWebSessionOrCompatibility() async throws {
        let counts = CoordinationCounts(), value = try snapshot(), legacy = CoordinationClient(try snapshot())
        let client = PrioritizedClaudeQuotaConnection(services: .init(
            passive: { await counts.add("passive"); return value },
            webAvailable: { await counts.add("cookies"); return true },
            makeWeb: { await counts.add("web"); return legacy }, compatibility: legacy))
        let reading = try await client.readQuota(), source = await client.currentSource()
        let passive = await counts.count("passive"), cookies = await counts.count("cookies"), web = await counts.count("web"), compatibility = await legacy.reads
        XCTAssertEqual(reading, value); XCTAssertEqual(source, .statusLine)
        XCTAssertEqual(passive, 1); XCTAssertEqual(cookies, 0); XCTAssertEqual(web, 0); XCTAssertEqual(compatibility, 0)
        await client.shutdown()
    }

    func testSynchronousRevocationStopsBothPassiveAndCookieContinuationBeforeFallback() async throws {
        for cookieBoundary in [false, true] {
            let passive = CoordinationGate<QuotaSnapshot?>(), cookies = CoordinationGate<Bool>()
            let counts = CoordinationCounts(), legacy = CoordinationClient(try snapshot())
            let client = PrioritizedClaudeQuotaConnection(services: .init(
                passive: { cookieBoundary ? nil : await passive.wait() },
                webAvailable: { await cookies.wait() },
                makeWeb: { await counts.add("web"); return legacy }, compatibility: legacy))
            let reading = Task { try await client.readQuota() }
            try await until { cookieBoundary ? await cookies.waiting : await passive.waiting }
            client.invalidateSource()
            if cookieBoundary { await cookies.release(true) } else { await passive.release(nil) }
            do { _ = try await reading.value; XCTFail("Revoked source unexpectedly read quota") }
            catch { XCTAssertTrue(error is CancellationError) }
            let web = await counts.count("web"), fallback = await legacy.reads
            XCTAssertEqual(web, 0); XCTAssertEqual(fallback, 0)
            await client.shutdown()
        }
    }

    func testCloudUnreadBindingSurvivesAnUnverifiedRestartButNotAnotherVerifiedAccount() {
        func state(_ scope: String?, verified: Bool, revision: UInt64) -> ClaudeCloudState {
            .init(context: 1, purgeRevision: revision, connectionContext: "synthetic", enabled: true, webAvailable: true,
                  activities: [], attention: [], status: nil, verifiedScope: scope, scopeVerified: verified)
        }
        var binding = ClaudeCloudHistoryBinding()
        XCTAssertFalse(binding.observe(state("first", verified: true, revision: 1)))
        XCTAssertFalse(binding.observe(state(nil, verified: false, revision: 1)))
        XCTAssertFalse(binding.observe(state("first", verified: true, revision: 2)))
        XCTAssertTrue(binding.observe(state("other", verified: true, revision: 3)))
        XCTAssertTrue(binding.observe(state(nil, verified: true, revision: 4)))
        XCTAssertFalse(binding.observe(state(nil, verified: true, revision: 5)))
    }

    func testChallengeRetainsHistoryWhileNewSessionAndBillingChangesRejectIt() {
        var history = DeepSeekBalanceHistory()
        history.record(total: 100, at: Date(timeIntervalSince1970: 1_800_000_000), source: "web")
        XCTAssertEqual(DeepSeekBalanceBinding.sessionHistory(history, newSession: false), history)
        XCTAssertEqual(DeepSeekBalanceBinding.sessionHistory(history, newSession: true), .init())
        XCTAssertEqual(DeepSeekBalanceBinding(source: .automatic, mode: nil).restoredHistory(history), history)
        XCTAssertEqual(DeepSeekBalanceBinding(source: .web, mode: .account).retainedHistory(history, previousMode: nil), history)
        XCTAssertEqual(DeepSeekBalanceBinding(source: .apiKey, mode: .apiKey).restoredHistory(history), .init())
        XCTAssertEqual(DeepSeekBalanceBinding(source: .web, mode: .account).retainedHistory(history, previousMode: .apiKey), .init())
    }

    func testSameSessionChallengeKeepsStoredBalanceHistoryInTheActualCoordinator() async throws {
        for newSession in [false, true] {
            var saved = DeepSeekBalanceHistory()
            saved.record(total: 100, at: Date(timeIntervalSince1970: 1_800_000_000), source: "web")
            let history = saved, counts = CoordinationCounts()
            let coordinator = DeepSeekBalanceCoordinator(services: .init(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
                readAPI: { _ in throw DeepSeekBalanceError.connectionFailed }, fingerprint: { _, _ in nil }, readWeb: { _ in throw DeepSeekBalanceError.challenge },
                detect: { _, _ in .account }, loadHistory: { history }, saveHistory: { _, _ in await counts.add("write") }), output: { _ in })
            await coordinator.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
            let before = await coordinator.currentState()
            let changed = await coordinator.webSessionChanged(token: before.token, newSession: newSession)
            await coordinator.refreshCompletion?.value
            let after = await coordinator.currentState(), writes = await counts.count("write")
            XCTAssertTrue(changed)
            XCTAssertNotEqual(after.token, before.token)
            XCTAssertEqual(after.history, newSession ? .init() : history)
            XCTAssertEqual(writes, newSession ? 1 : 0)
            XCTAssertEqual(after.error, .challenge)
            await coordinator.stop()
        }
    }
    func testBalanceReplacementRetainsTheSeededNumericHistoryAcrossSleep() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let services = DeepSeekBalanceServices(readKey: { nil }, saveKey: { _ in false }, removeKey: { true },
            readAPI: { _ in throw DeepSeekBalanceError.connectionFailed },
            readWeb: { _ in .init(total: 42, capturedAt: date, source: .web) }, detect: { _, _ in .account })
        let first = DeepSeekBalanceCoordinator(services: services, now: { date }, output: { _ in })
        await first.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
        _ = await first.refreshIfDue(active: true, force: true)
        await first.refreshCompletion?.value
        let seed = await first.currentState()
        XCTAssertFalse(seed.history.samples.isEmpty)
        await first.stop()
        let replacement = DeepSeekBalanceCoordinator(services: services, seed: seed, now: { date }, output: { _ in })
        await replacement.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 2)
        let resumed = await replacement.currentState()
        XCTAssertEqual(resumed.history, seed.history)
        XCTAssertEqual(resumed.balance, seed.balance)
        XCTAssertEqual(resumed.lastAttempt, seed.lastAttempt)
        XCTAssertEqual(resumed.successCount, seed.successCount)
        XCTAssertNotEqual(resumed.token, seed.token)
        await replacement.stop()
        let changedBilling = DeepSeekBalanceCoordinator(services: services, seed: seed, now: { date }, output: { _ in })
        await changedBilling.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 3)
        let changed = await changedBilling.currentState()
        XCTAssertTrue(changed.history.samples.isEmpty)
        XCTAssertNil(changed.balance, "A previous web reading cannot seed a different billing source")
        await changedBilling.stop()
    }
}
