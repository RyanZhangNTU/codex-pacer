import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekBalanceMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = URL(fileURLWithPath: "/synthetic/deepseek")

    func testRefreshCadenceRetainedReadingsAndConnectionFailuresMatchTheMacPolicy() async {
        let clock = Clock(start), memory = Memory(), capture = Capture()
        memory.setKey("sk-synthetic-first-key-0000")
        let monitor = DeepSeekBalanceMonitor(services: memory.services(clock), now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .automatic, enabled: true, recentProvider: nil, context: 1)
        var began = await monitor.refreshIfDue(active: true); XCTAssertTrue(began); await monitor.refreshCompletion?.value
        var state = await monitor.currentState(); XCTAssertEqual(state.balance?.total, 100); XCTAssertEqual(memory.counts().reads, 1)
        clock.advance(59); began = await monitor.refreshIfDue(active: true); XCTAssertFalse(began)
        memory.setFailure(.connectionFailed); clock.advance(1)
        began = await monitor.refreshIfDue(active: true); XCTAssertTrue(began); await monitor.refreshCompletion?.value
        state = await monitor.currentState(); XCTAssertEqual(state.balance?.total, 100); XCTAssertEqual(state.error, .connectionFailed)
        clock.advance(119); began = await monitor.refreshIfDue(active: true); XCTAssertFalse(began)
        memory.setFailure(.invalidKey); clock.advance(1)
        began = await monitor.refreshIfDue(active: true); XCTAssertTrue(began); await monitor.refreshCompletion?.value
        state = await monitor.currentState(); XCTAssertNil(state.balance); XCTAssertEqual(state.error, .invalidKey)
        clock.advance(10000); began = await monitor.refreshIfDue(active: true); XCTAssertFalse(began, "Authentication failures require an explicit retry or replacement key")
        memory.setFailure(nil); began = await monitor.refreshIfDue(active: false, force: true); XCTAssertTrue(began); await monitor.refreshCompletion?.value
        clock.advance(20); began = await monitor.refreshIfDue(active: false, turnEnded: true); XCTAssertFalse(began)
        clock.advance(1); began = await monitor.refreshIfDue(active: false, turnEnded: true); XCTAssertTrue(began); await monitor.refreshCompletion?.value
        clock.advance(299); began = await monitor.refreshIfDue(active: false); XCTAssertFalse(began)
        clock.advance(1); began = await monitor.refreshIfDue(active: false); XCTAssertTrue(began); await monitor.refreshCompletion?.value
        for active in [false, true] { for failures in [0, 1, 2, 3, 4] {
            XCTAssertEqual(DeepSeekBalanceMonitor.refreshInterval(active: active, failures: failures), (active ? 60 : 300) * pow(2, Double(min(3, failures))))
        } }
        await monitor.stop()
    }
    func testScopedKeyCommandsClearHistoryAndRejectStaleOrDisabledControls() async throws {
        let clock = Clock(start), memory = Memory(), capture = Capture()
        let monitor = DeepSeekBalanceMonitor(services: memory.services(clock), now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 3)
        let missing = await monitor.currentState(); XCTAssertEqual(missing.error, .missingKey)
        var saved = await monitor.saveKey("short", token: missing.token); XCTAssertFalse(saved); XCTAssertEqual(memory.counts().writes, 0)
        saved = await monitor.saveKey(String(repeating: "a", count: 257), token: missing.token); XCTAssertFalse(saved); XCTAssertEqual(memory.counts().writes, 0)
        saved = await monitor.saveKey("sk-synthetic-first-key-0000", token: missing.token); XCTAssertTrue(saved); await monitor.refreshCompletion?.value
        let known = await monitor.currentState(); XCTAssertNotEqual(known.token, missing.token); XCTAssertEqual(known.balance?.total, 100)
        saved = await monitor.saveKey("sk-synthetic-other-key-0000", token: missing.token); XCTAssertFalse(saved)
        var removed = await monitor.removeKey(token: missing.token); XCTAssertFalse(removed)
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 4)
        let same = await monitor.currentState(); XCTAssertEqual(same.token, known.token, "Presentation or privacy revisions do not replace a billing connection")
        memory.setRemovalAllowed(false)
        removed = await monitor.removeKey(token: same.token); XCTAssertFalse(removed)
        let failedRemoval = await monitor.currentState(); XCTAssertEqual(failedRemoval, same, "A denied credential deletion cannot claim success or clear the known balance")
        memory.setRemovalAllowed(true)
        removed = await monitor.removeKey(token: same.token); XCTAssertTrue(removed)
        let cleared = await monitor.currentState(); XCTAssertNil(cleared.balance); XCTAssertTrue(cleared.history.samples.isEmpty); XCTAssertFalse(cleared.hasKey)
        await monitor.configure(home: home, source: .apiKey, enabled: false, recentProvider: nil, context: 5)
        let disabled = await monitor.currentState()
        saved = await monitor.saveKey("sk-synthetic-first-key-0000", token: disabled.token); XCTAssertFalse(saved)
        XCTAssertEqual(memory.counts().writes, 1)
        let bytes = try JSONEncoder().encode(DeepSeekConnectionPresentation(source: same.source, detected: same.detected,
            balance: same.balance, error: same.error, refreshing: same.refreshing, now: start))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic-first-key"))
        await monitor.stop()
    }
    func testAResponseFromAChangedProfileOrStoppedModuleIsDiscardedEvenIfCancellationIsIgnored() async {
        let clock = Clock(start), memory = Memory(), capture = Capture(), gate = Gate()
        memory.setKey("sk-synthetic-first-key-0000")
        var services = memory.services(clock); services.readAPI = { _ in await gate.read() }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 1)
        let began = await monitor.refreshIfDue(active: true); XCTAssertTrue(began); await gate.waitUntilStarted()
        await monitor.configure(home: home.appendingPathComponent("changed"), source: .web, enabled: true, recentProvider: nil, context: 2)
        await gate.finish(.init(total: 999, capturedAt: start, source: .apiKey))
        try? await Task.sleep(nanoseconds: 30_000_000)
        var state = await monitor.currentState(); XCTAssertNil(state.balance); XCTAssertEqual(state.error, .signedOut)
        XCTAssertFalse(capture.values().contains { $0.context == 2 && $0.balance != nil })
        await monitor.stop(); state = await monitor.currentState(); XCTAssertFalse(state.refreshing); XCTAssertNil(state.balance)
    }
    func testTheDetectedBillingModeIsRecheckedBeforeAcceptingAnInflightResponse() async {
        let clock = Clock(start), memory = Memory(), capture = Capture(), gate = Gate()
        memory.setKey("sk-synthetic-first-key-0000")
        var services = memory.services(clock); services.readAPI = { _ in await gate.read() }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .automatic, enabled: true, recentProvider: nil, context: 1)
        _ = await monitor.refreshIfDue(active: true); await gate.waitUntilStarted()
        memory.setMode(.account); await gate.finish(.init(total: 999, capturedAt: start, source: .apiKey))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let state = await monitor.currentState(); XCTAssertEqual(state.mode, .account); XCTAssertNil(state.balance)
        XCTAssertFalse(capture.values().contains { $0.balance?.total == 999 })
        await monitor.stop()
    }
    func testRotatingAKeyRevokesTheOldReadBeforeStartingTheReplacement() async {
        let clock = Clock(start), memory = Memory(), capture = Capture(), old = Gate()
        memory.setKey("sk-synthetic-first-key-0000")
        var services = memory.services(clock)
        services.readAPI = { key in
            if key == "sk-synthetic-first-key-0000" { return await old.read() }
            return .init(total: 42, capturedAt: clock.read(), source: .apiKey)
        }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 1)
        _ = await monitor.refreshIfDue(active: true); await old.waitUntilStarted()
        let initial = await monitor.currentState(), oldCompletion = await monitor.refreshCompletion
        let saved = await monitor.saveKey("sk-synthetic-next-key-00000", token: initial.token)
        XCTAssertTrue(saved); await monitor.refreshCompletion?.value
        let replacement = await monitor.currentState()
        XCTAssertNotEqual(initial.token, replacement.token); XCTAssertEqual(replacement.balance?.total, 42)
        await old.finish(.init(total: 999, capturedAt: start, source: .apiKey)); await oldCompletion?.value
        let final = await monitor.currentState(); XCTAssertEqual(final.balance?.total, 42)
        XCTAssertFalse(capture.values().contains { $0.balance?.total == 999 })
        await monitor.stop()
    }
    func testStoppingAnInflightModuleRejectsItsLateReadAndCacheWrite() async {
        let clock = Clock(start), memory = Memory(), capture = Capture(), gate = Gate()
        memory.setKey("sk-synthetic-first-key-0000")
        var services = memory.services(clock)
        services.readAPI = { _ in await gate.read() }
        services.saveHistory = { _, _ in memory.recordHistoryWrite() }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 1)
        _ = await monitor.refreshIfDue(active: true); await gate.waitUntilStarted()
        let writesBeforeStop = memory.historyWrites(), oldCompletion = await monitor.refreshCompletion
        await monitor.stop(); await gate.finish(.init(total: 999, capturedAt: start, source: .apiKey)); await oldCompletion?.value
        let stopped = await monitor.currentState()
        XCTAssertNil(stopped.balance); XCTAssertFalse(stopped.refreshing)
        XCTAssertEqual(memory.historyWrites(), writesBeforeStop)
        XCTAssertFalse(capture.values().contains { $0.balance != nil })
        let began = await monitor.refreshIfDue(active: true, force: true); XCTAssertFalse(began)
    }
    func testNumericHistorySurvivesRelaunchAndRejectsCorruptOrOversizedCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-balance-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json"), store = DeepSeekBalanceHistoryStore(file: file)
        var history = DeepSeekBalanceHistory(); history.record(total: 100, at: start, source: "apiKey")
        history.record(total: 90, at: start.addingTimeInterval(60), source: "apiKey")
        await store.save(history)
        var restored = await store.load(now: start.addingTimeInterval(60)); XCTAssertEqual(restored, history)
        let bytes = try Data(contentsOf: file); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("sk-"))
        try Data(repeating: 32, count: 65537).write(to: file)
        restored = await store.load(now: start); XCTAssertTrue(restored.samples.isEmpty)
        try Data("{\"version\":1,\"history\":{\"samples\":[],\"charged\":[0,-3]}}".utf8).write(to: file)
        restored = await store.load(now: start); XCTAssertTrue(restored.samples.isEmpty)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for field in ["samples", "since", "charged"] {
            var damaged = envelope, raw = try XCTUnwrap(envelope["history"] as? [String: Any])
            if field == "samples" { raw[field] = [["at": -1e300, "total": 100]] }
            else if field == "charged" { raw[field] = [-1e300, 3] }
            else { raw[field] = -1e300 }
            damaged["history"] = raw
            try JSONSerialization.data(withJSONObject: damaged).write(to: file)
            restored = await store.load(now: start); XCTAssertNil(restored.source, "Extreme cached dates cannot reach calendar or spend calculations")
        }
    }

    func testBillingChangesKeepOnlyCompatibleRestoredHistory() async {
        let clock = Clock(start), memory = Memory(), capture = Capture()
        var restored = DeepSeekBalanceHistory()
        restored.record(total: 100, at: start.addingTimeInterval(-60), source: "apiKey")
        restored.record(total: 90, at: start, source: "apiKey")
        let saved = restored
        var services = memory.services(clock); services.loadHistory = { saved }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 1)
        var state = await monitor.currentState(); XCTAssertEqual(state.history, saved)
        await monitor.configure(home: home.appendingPathComponent("other"), source: .automatic, enabled: true, recentProvider: nil, context: 2)
        state = await monitor.currentState(); XCTAssertEqual(state.history, saved, "A new log home still uses Pacer's same global API balance key")
        memory.setMode(nil)
        await monitor.configure(home: home.appendingPathComponent("other"), source: .automatic, enabled: true, recentProvider: nil, context: 3)
        state = await monitor.currentState(); XCTAssertTrue(state.history.samples.isEmpty, "Losing a previously resolved billing mode invalidates its history")
        memory.setMode(.apiKey)
        await monitor.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 4)
        state = await monitor.currentState(); XCTAssertTrue(state.history.samples.isEmpty)
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 5)
        state = await monitor.currentState(); XCTAssertTrue(state.history.samples.isEmpty, "Switching back cannot resurrect a discarded account history")
        await monitor.stop()
    }
    func testAnOlderSuspendedCacheWriteCannotRestoreThePreviousKeysHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-balance-cache-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeepSeekBalanceHistoryStore(file: directory.appendingPathComponent("history.json"))
        let clock = Clock(start), memory = Memory(), capture = Capture(), oldCache = Gate(), nextRead = Gate()
        memory.setKey("sk-synthetic-first-key-0000")
        var services = memory.services(clock)
        services.readAPI = { key in
            if key == "sk-synthetic-first-key-0000" { return .init(total: 100, capturedAt: clock.read(), source: .apiKey) }
            return await nextRead.read()
        }
        services.saveHistory = { value, revision in
            if value.last?.total == 100 { _ = await oldCache.read() }
            await store.save(value, revision: revision)
            if value.last?.total == 100 { await oldCache.wrote() }
        }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .apiKey, enabled: true, recentProvider: nil, context: 1)
        _ = await monitor.refreshIfDue(active: true); await oldCache.waitUntilStarted()
        let old = await monitor.currentState()
        let saved = await monitor.saveKey("sk-synthetic-next-key-00000", token: old.token); XCTAssertTrue(saved)
        await nextRead.waitUntilStarted(); let completion = await monitor.refreshCompletion
        await nextRead.finish(.init(total: 42, capturedAt: start, source: .apiKey)); await completion?.value
        await oldCache.finish(.init(total: 0, capturedAt: start, source: .apiKey)); await oldCache.waitUntilWritten()
        let persisted = await store.load(now: start), current = await monitor.currentState()
        XCTAssertEqual(current.balance?.total, 42); XCTAssertEqual(persisted.last?.total, 42)
        XCTAssertEqual(persisted.samples.count, 1, "Key rotation clears the old account before recording the replacement")
        await monitor.stop()
    }

    func testDisconnectPausesReadsUntilTheMatchingBrowserClearFinishes() async {
        let clock = Clock(start), memory = Memory(), capture = Capture()
        memory.setMode(.account); memory.setKey("sk-synthetic-first-key-0000")
        var services = memory.services(clock)
        services.readWeb = { _ in .init(total: 100, capturedAt: clock.read(), source: .web, sessionFingerprint: String(repeating: "1", count: 64)) }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
        _ = await monitor.refreshIfDue(active: true); await monitor.refreshCompletion?.value
        let initial = await monitor.currentState()
        let operation = await monitor.beginDisconnect(token: initial.token)
        XCTAssertNotNil(operation)
        let clearing = await monitor.currentState()
        XCTAssertNotEqual(clearing.token, initial.token); XCTAssertTrue(clearing.refreshing)
        XCTAssertNil(clearing.balance); XCTAssertNil(memory.getKey()); XCTAssertTrue(clearing.history.samples.isEmpty)
        await monitor.setWebReader(nil); await monitor.setWebReader(services.readWeb)
        let rediscovered = await monitor.currentState()
        XCTAssertEqual(rediscovered.token, clearing.token); XCTAssertTrue(rediscovered.refreshing)
        var began = await monitor.refreshIfDue(active: true, force: true); XCTAssertFalse(began)
        var completed = await monitor.completeDisconnect(token: initial.token, success: true); XCTAssertFalse(completed)
        completed = await monitor.completeDisconnect(token: clearing.token, success: true); XCTAssertTrue(completed)
        let signedOut = await monitor.currentState(); XCTAssertFalse(signedOut.refreshing); XCTAssertEqual(signedOut.error, .signedOut)
        began = await monitor.refreshIfDue(active: true); XCTAssertFalse(began)
        let connected = await monitor.webSessionChanged(token: signedOut.token); XCTAssertTrue(connected); await monitor.refreshCompletion?.value
        let fresh = await monitor.currentState(); XCTAssertEqual(fresh.balance?.total, 100); XCTAssertNotEqual(fresh.token, signedOut.token)
        await monitor.stop()
    }
    func testAFailedBrowserClearDoesNotAutomaticallyReadTheOldAccountAgain() async {
        let clock = Clock(start), memory = Memory(), capture = Capture()
        memory.setMode(.account)
        var services = memory.services(clock)
        services.readWeb = { _ in .init(total: 100, capturedAt: clock.read(), source: .web, sessionFingerprint: String(repeating: "1", count: 64)) }
        let monitor = DeepSeekBalanceMonitor(services: services, now: { clock.read() }, output: { await capture.append($0) })
        await monitor.configure(home: home, source: .web, enabled: true, recentProvider: nil, context: 1)
        let initial = await monitor.currentState()
        _ = await monitor.beginDisconnect(token: initial.token)
        let clearing = await monitor.currentState()
        let completed = await monitor.completeDisconnect(token: clearing.token, success: false); XCTAssertTrue(completed)
        clock.advance(10000)
        let began = await monitor.refreshIfDue(active: true); XCTAssertFalse(began)
        await monitor.setWebReader(nil); await monitor.setWebReader(services.readWeb)
        await monitor.refreshCompletion?.value
        let failed = await monitor.currentState(); XCTAssertEqual(failed.error, .connectionFailed); XCTAssertNil(failed.balance); XCTAssertFalse(failed.refreshing)
        let connected = await monitor.webSessionChanged(token: failed.token); XCTAssertTrue(connected); await monitor.refreshCompletion?.value
        let fresh = await monitor.currentState(); XCTAssertEqual(fresh.balance?.total, 100)
        await monitor.stop()
    }
    func testReadOnlyDiagnosticsCannotPersistHistorySaltOrCredentials() async {
        let memory = Memory(), clock = Clock(start), calls = ReadOnlyCalls()
        let key = "sk-synthetic-readonly-history-key"
        memory.setKey(key)
        var live = memory.services(clock)
        live.fingerprint = { _, _ in calls.add(); return String(repeating: "a", count: 32) }
        live.loadHistory = { calls.add(); return .init() }
        live.saveHistory = { _, _ in calls.add() }
        let readOnly = live.forReadOnlyDiagnostics()
        XCTAssertNil(readOnly.fingerprint(.apiKey, key))
        let history = await readOnly.loadHistory()
        XCTAssertTrue(history.samples.isEmpty)
        await readOnly.saveHistory(.init(), 1)
        XCTAssertFalse(readOnly.saveKey("sk-synthetic-replacement-key"))
        XCTAssertFalse(readOnly.removeKey())
        XCTAssertEqual(calls.count(), 0, "Diagnostics cannot invoke writable history or salt services")
        XCTAssertEqual(memory.getKey(), key)
        XCTAssertEqual(memory.counts().writes, 0)
    }
    private final class ReadOnlyCalls: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var date: Date
        init(_ date: Date) { self.date = date }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: Double) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock(); private var states: [DeepSeekBalanceState] = []
        func append(_ state: DeepSeekBalanceState) async { store(state) }
        private func store(_ state: DeepSeekBalanceState) { lock.lock(); states.append(state); lock.unlock() }
        func values() -> [DeepSeekBalanceState] { lock.lock(); defer { lock.unlock() }; return states }
    }
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock(); private var key: String?, failure: DeepSeekBalanceError?, mode: DeepSeekAuthMode? = .apiKey
        private var reads = 0, writes = 0, cacheWrites = 0, removalAllowed = true
        func setKey(_ key: String?) { lock.lock(); self.key = key; lock.unlock() }
        func setMode(_ mode: DeepSeekAuthMode?) { lock.lock(); self.mode = mode; lock.unlock() }
        func setRemovalAllowed(_ value: Bool) { lock.lock(); removalAllowed = value; lock.unlock() }
        func removeKey() -> Bool {
            lock.lock(); defer { lock.unlock() }; guard removalAllowed else { return false }; key = nil; return true
        }
        func setFailure(_ failure: DeepSeekBalanceError?) { lock.lock(); self.failure = failure; lock.unlock() }
        func getKey() -> String? { lock.lock(); defer { lock.unlock() }; return key }
        func getMode() -> DeepSeekAuthMode? { lock.lock(); defer { lock.unlock() }; return mode }
        func save(_ value: String) -> Bool { lock.lock(); writes += 1; key = value; lock.unlock(); return true }
        func response(_ date: Date) throws -> DeepSeekBalance {
            lock.lock(); reads += 1; let failure = failure; lock.unlock()
            if let failure { throw failure }; return .init(total: 100, capturedAt: date, source: .apiKey)
        }
        func counts() -> (reads: Int, writes: Int) { lock.lock(); defer { lock.unlock() }; return (reads, writes) }
        func recordHistoryWrite() { lock.lock(); cacheWrites += 1; lock.unlock() }
        func historyWrites() -> Int { lock.lock(); defer { lock.unlock() }; return cacheWrites }
        func services(_ clock: Clock) -> DeepSeekBalanceServices {
            let fingerprints = DeepSeekHistoryCredential(loadSalt: { Data(repeating: 7, count: 32) }, saveSalt: { _ in })
            return .init(readKey: { self.getKey() }, saveKey: { self.save($0) }, removeKey: { self.removeKey() },
                readAPI: { _ in try self.response(clock.read()) }, fingerprint: { fingerprints.fingerprint(source: $0, identity: $1) }, detect: { _, _ in self.getMode() })
        }
    }
    private actor Gate {
        private var continuation: CheckedContinuation<DeepSeekBalance, Never>?
        private var written = false
        func read() async -> DeepSeekBalance { await withCheckedContinuation { continuation = $0 } }
        func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
        func wrote() { written = true }
        func waitUntilWritten() async { while !written { await Task.yield() } }
        func finish(_ balance: DeepSeekBalance) { continuation?.resume(returning: balance); continuation = nil }
    }
}
