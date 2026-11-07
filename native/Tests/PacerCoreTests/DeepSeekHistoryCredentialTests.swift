import Foundation
import CryptoKit
import XCTest
@testable import PacerCore

final class DeepSeekHistoryCredentialTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let firstKey = "sk-synthetic-history-first-0000"
    private let nextKey = "sk-synthetic-history-second-000"
    private let home = URL(fileURLWithPath: "/synthetic/deepseek")

    func testRFC4231AuthenticationAndTruncationVectors() {
        let vectors: [(Data, String, String)] = [
            (Data(repeating: 0x0b, count: 20), "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
            (Data("Jefe".utf8), "what do ya want for nothing?", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
            (Data(repeating: 0xaa, count: 131), "Test Using Larger Than Block-Size Key - Hash Key First", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
        ]
        for (key, message, expected) in vectors {
            XCTAssertEqual(hex(DeepSeekHistoryCredential.authenticationCode(message: Data(message.utf8), key: key)), expected)
        }
        let shortened = DeepSeekHistoryCredential.authenticationCode(message: Data("Test With Truncation".utf8), key: Data(repeating: 0x0c, count: 20))
        XCTAssertEqual(hex(shortened.prefix(16)), "a3b6167473100ee06e0c796c2955552b")
    }

    func testLocalSaltIsReusedAndDomainSeparatedWithoutStoringCredentials() throws {
        let memory = Memory(key: firstKey, at: start)
        let first = memory.credentials(), second = memory.credentials()
        let api = try XCTUnwrap(first.fingerprint(source: .apiKey, identity: firstKey))
        XCTAssertEqual(api.count, 32)
        XCTAssertEqual(second.fingerprint(source: .apiKey, identity: firstKey), api)
        XCTAssertNotEqual(first.fingerprint(source: .apiKey, identity: nextKey), api)
        XCTAssertNotEqual(first.fingerprint(source: .web, identity: firstKey), api)
        let persisted = try XCTUnwrap(memory.saltBytes())
        XCTAssertEqual(persisted.count, 32)
        XCTAssertEqual(memory.saltWriteCount(), 1)
        XCTAssertNotEqual(persisted, Data(firstKey.utf8))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(firstKey))
        let otherMachine = Memory(key: firstKey, at: start)
        XCTAssertNotEqual(otherMachine.credentials().fingerprint(source: .apiKey, identity: firstKey), api)
    }

    func testReplacingKeyWhileClosedStartsHistoryWithoutAnInventedCharge() async throws {
        let memory = Memory(key: firstKey, at: start)
        let first = coordinator(memory)
        await configure(first)
        _ = await refresh(first)
        memory.advance(total: 90)
        let previous = await refresh(first)
        XCTAssertEqual(previous.history.samples.count, 2)
        XCTAssertEqual(previous.history.spent(1, of: 120, endingAt: memory.date()), [10])
        await first.stop()

        memory.changeKey(nextKey)
        memory.advance(total: 5)
        let restarted = coordinator(memory)
        await configure(restarted)
        let current = await refresh(restarted)
        XCTAssertEqual(current.balance?.total, 5)
        XCTAssertEqual(current.history.samples.count, 1)
        XCTAssertEqual(current.history.last?.total, 5)
        XCTAssertEqual(current.history.since, memory.date())
        XCTAssertEqual(current.history.source, "apiKey")
        XCTAssertEqual(current.history.spent(1, of: 600, endingAt: memory.date()), [0])
        XCTAssertNotEqual(current.history.credentialFingerprint, previous.history.credentialFingerprint)
        XCTAssertEqual(memory.savedHistory(), current.history)
        try assertPrivate(current.history, forbidden: [firstKey, nextKey])
        await restarted.stop()
    }

    func testSameKeySurvivesRestartAndHomeChangeWithTheExistingNumericHistory() async throws {
        let memory = Memory(key: firstKey, at: start)
        let first = coordinator(memory)
        await configure(first)
        _ = await refresh(first)
        memory.advance(total: 90)
        let previous = await refresh(first)
        await first.stop()

        memory.advance(total: 80)
        let restarted = coordinator(memory)
        await configure(restarted)
        var current = await refresh(restarted)
        XCTAssertEqual(current.history.samples.count, 3)
        XCTAssertEqual(current.history.since, start)
        XCTAssertEqual(current.history.credentialFingerprint, previous.history.credentialFingerprint)
        XCTAssertEqual(current.history.spent(1, of: 600, endingAt: memory.date()), [20])
        XCTAssertEqual(memory.saltWriteCount(), 1)
        let otherHome = URL(fileURLWithPath: "/synthetic/another-home")
        await restarted.configure(home: otherHome, source: .apiKey, enabled: true, recentProvider: nil, context: 2)
        memory.advance(total: 70)
        current = await refresh(restarted)
        XCTAssertEqual(current.history.samples.count, 4, "Billing history remains global for the same credential")
        XCTAssertEqual(current.history.since, start)
        XCTAssertEqual(current.history.spent(1, of: 600, endingAt: memory.date()), [30])
        XCTAssertEqual(current.history.credentialFingerprint, previous.history.credentialFingerprint)
        await restarted.stop()
    }

    func testLegacyJSONAdoptsIdentityOnlyAfterSuccessfulRead() async throws {
        let memory = Memory(key: firstKey, at: start)
        var legacy = DeepSeekBalanceHistory()
        legacy.record(total: 100, at: start, source: "apiKey")
        legacy.record(total: 90, at: start.addingTimeInterval(60), source: "apiKey")
        let bytes = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["credentialFingerprint"])
        memory.saveHistory(try JSONDecoder().decode(DeepSeekBalanceHistory.self, from: bytes))
        memory.advance(total: 80, seconds: 120)
        memory.failBalance(true)
        let reader = coordinator(memory)
        await configure(reader)
        let failed = await refresh(reader)
        XCTAssertEqual(failed.error, .connectionFailed)
        XCTAssertEqual(failed.history, legacy)
        XCTAssertNil(memory.savedHistory().credentialFingerprint)
        XCTAssertNil(memory.saltBytes())
        memory.failBalance(false)
        let success = await refresh(reader)
        XCTAssertNotNil(success.history.credentialFingerprint)
        XCTAssertEqual(success.history.samples.count, 3)
        XCTAssertEqual(success.history.since, start)
        XCTAssertEqual(success.history.spent(1, of: 600, endingAt: memory.date()), [20])
        XCTAssertEqual(memory.savedHistory(), success.history)
        try assertPrivate(success.history, forbidden: [firstKey])
        await reader.stop()
    }

    func testDamagedOrReplacedSaltCannotMergePreviouslyBoundHistory() async throws {
        let damagedSalts: [Data?] = [nil, Data(), Data(repeating: 0, count: 31), Data(repeating: 0xa5, count: 32)]
        for damage in damagedSalts {
            let memory = Memory(key: firstKey, at: start)
            let first = coordinator(memory)
            await configure(first)
            _ = await refresh(first)
            memory.advance(total: 90)
            let previous = await refresh(first)
            await first.stop()
            memory.damageSalt(damage)
            memory.advance(total: 80)
            let restarted = coordinator(memory)
            await configure(restarted)
            let current = await refresh(restarted)
            XCTAssertEqual(current.balance?.total, 80)
            XCTAssertEqual(current.history.samples.count, 1)
            XCTAssertEqual(current.history.since, memory.date())
            XCTAssertEqual(current.history.spent(1, of: 600, endingAt: memory.date()), [0])
            XCTAssertNotEqual(current.history.credentialFingerprint, previous.history.credentialFingerprint)
            XCTAssertEqual(memory.saltBytes()?.count, 32)
            await restarted.stop()
        }
    }

    func testSaltIOFailureKeepsBalanceAvailableWithoutPublishingOrOverwritingUnboundHistory() async {
        let memory = Memory(key: firstKey, at: start)
        let first = coordinator(memory)
        await configure(first)
        _ = await refresh(first)
        memory.advance(total: 90)
        let previous = await refresh(first)
        await first.stop()
        memory.changeKey(nextKey)
        memory.advance(total: 5)
        memory.failSalt(true)
        let reader = coordinator(memory)
        await configure(reader)
        var current = await refresh(reader)
        XCTAssertEqual(current.balance?.total, 5)
        XCTAssertNil(current.error)
        XCTAssertTrue(current.history.samples.isEmpty)
        XCTAssertEqual(memory.savedHistory(), previous.history, "A salt error cannot overwrite the known stored history")
        let seed = current
        await reader.stop()
        let resumed = coordinator(memory, seed: seed)
        await configure(resumed)
        let unverifiedSeed = await resumed.currentState()
        XCTAssertEqual(unverifiedSeed.balance?.total, 5)
        XCTAssertTrue(unverifiedSeed.history.samples.isEmpty, "A seed cannot pair an unbound balance with the restored old credential history")
        memory.failSalt(false)
        memory.advance(total: 4)
        current = await refresh(resumed)
        XCTAssertEqual(current.history.samples.count, 1)
        XCTAssertEqual(current.history.last?.total, 4)
        XCTAssertEqual(current.history.spent(1, of: 600, endingAt: memory.date()), [0])
        XCTAssertNotEqual(current.history.credentialFingerprint, previous.history.credentialFingerprint)
        await resumed.stop()
    }

    func testVerifiedWebSessionUsesTheSameBindingAndNeverPersistsThePageDigest() async throws {
        let memory = Memory(key: firstKey, at: start)
        let session = String(repeating: "1", count: 64)
        memory.changeSession(session)
        let first = coordinator(memory, web: true)
        await configure(first, web: true)
        _ = await refresh(first)
        memory.advance(total: 90)
        let previous = await refresh(first)
        await first.stop()
        memory.advance(total: 80)
        let restarted = coordinator(memory, web: true)
        await configure(restarted, web: true)
        let same = await refresh(restarted)
        XCTAssertEqual(same.history.samples.count, 3)
        XCTAssertEqual(same.history.credentialFingerprint, previous.history.credentialFingerprint)
        XCTAssertEqual(same.history.spent(1, of: 600, endingAt: memory.date()), [20])
        let next = String(repeating: "2", count: 64)
        memory.changeSession(next)
        memory.advance(total: 5)
        let changed = await refresh(restarted)
        XCTAssertEqual(changed.history.samples.count, 1)
        XCTAssertEqual(changed.history.source, "web")
        XCTAssertEqual(changed.history.spent(1, of: 600, endingAt: memory.date()), [0])
        XCTAssertNotEqual(changed.history.credentialFingerprint, same.history.credentialFingerprint)
        try assertPrivate(changed.history, forbidden: [firstKey, session, next])
        await restarted.stop()
    }

    func testMalformedSavedFingerprintIsRejectedRatherThanTreatedAsLegacy() throws {
        var history = DeepSeekBalanceHistory()
        history.record(total: 100, at: start, source: "apiKey")
        let bytes = try JSONEncoder().encode(history)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for invalid in ["", "not-a-fingerprint", String(repeating: "0", count: 31), String(repeating: "0", count: 33), String(repeating: "g", count: 32)] {
            object["credentialFingerprint"] = invalid
            let damaged = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(DeepSeekBalanceHistory.self, from: damaged))
        }
        XCTAssertEqual(try JSONDecoder().decode(DeepSeekBalanceHistory.self, from: bytes), history)
    }

    func testWebBalanceWithoutVerifiedSessionCannotReplaceKnownHistory() async {
        let memory = Memory(key: firstKey, at: start)
        memory.changeSession(String(repeating: "1", count: 64))
        let reader = coordinator(memory, web: true)
        await configure(reader, web: true)
        let before = await refresh(reader)
        memory.changeSession(nil)
        memory.advance(total: 5)
        let unverified = await refresh(reader)
        XCTAssertEqual(unverified.error, .invalidReply)
        XCTAssertEqual(unverified.history, before.history)
        XCTAssertEqual(memory.savedHistory(), before.history)
        XCTAssertNotEqual(unverified.balance?.total, 5)
        await reader.stop()
    }

    func testSaltUsesBoundedFileIOAndRefusesNonregularOrUnwritableStorage() throws {
        let file = URL(fileURLWithPath: "/synthetic/balance/history-salt-v1.bin")
        let files = SaltFiles()
        let credential = DeepSeekHistoryCredential(saltFile: file, files: files)
        XCTAssertNotNil(credential.fingerprint(source: .apiKey, identity: firstKey))
        XCTAssertEqual(files.bytes?.count, 32)
        XCTAssertEqual(files.readLimit, 33)
        XCTAssertEqual(files.readOffset, 0)
        XCTAssertEqual(files.replacedURL, file)
        for directory in [false, true] {
            let invalid = SaltFiles()
            invalid.bytes = Data(repeating: 7, count: 32)
            invalid.regular = false; invalid.directory = directory
            XCTAssertNil(DeepSeekHistoryCredential(saltFile: file, files: invalid).fingerprint(source: .apiKey, identity: firstKey))
            XCTAssertNil(invalid.replacedURL)
            XCTAssertEqual(invalid.bytes, Data(repeating: 7, count: 32))
        }
        let denied = SaltFiles(); denied.writable = false
        XCTAssertNil(DeepSeekHistoryCredential(saltFile: file, files: denied).fingerprint(source: .apiKey, identity: firstKey))
        XCTAssertNil(denied.bytes)
        XCTAssertNil(denied.replacedURL)
    }

    func testMacHistoryDefaultsKeyAndNumericJSONRemainIntactWhenSaltIsCreated() throws {
        let name = testDefaultsName("pacer-history-credential-test")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { removeTestDefaults(name) }
        var history = DeepSeekBalanceHistory()
        history.record(total: 100, at: start, source: "apiKey")
        history.record(total: 90, at: start.addingTimeInterval(60), source: "apiKey")
        history.save(to: defaults)
        let original = try XCTUnwrap(defaults.data(forKey: "deepseekBalanceHistory"))
        XCTAssertEqual(DeepSeekBalanceHistory.defaultsKey, "deepseekBalanceHistory")
        let first = try XCTUnwrap(DeepSeekHistoryCredential(defaults: defaults).fingerprint(source: .apiKey, identity: firstKey))
        XCTAssertEqual(defaults.data(forKey: DeepSeekHistoryCredential.saltDefaultsKey)?.count, 32)
        XCTAssertEqual(defaults.data(forKey: "deepseekBalanceHistory"), original)
        XCTAssertEqual(DeepSeekBalanceHistory.load(from: defaults), history)
        XCTAssertEqual(DeepSeekHistoryCredential(defaults: defaults).fingerprint(source: .apiKey, identity: firstKey), first)
        XCTAssertNotEqual(DeepSeekHistoryCredential(defaults: defaults).fingerprint(source: .apiKey, identity: nextKey), first)
        XCTAssertEqual(defaults.data(forKey: "deepseekBalanceHistory"), original)
    }

    private func coordinator(_ memory: Memory, web: Bool = false, seed: DeepSeekBalanceState? = nil) -> DeepSeekBalanceCoordinator {
        let credentials = memory.credentials()
        let webReader: (@Sendable (String) async throws -> DeepSeekBalance)?
        if web { webReader = { _ in try memory.balance(source: .web) } }
        else { webReader = nil }
        let services = DeepSeekBalanceServices(readKey: { memory.key() }, saveKey: { _ in false }, removeKey: { false },
            readAPI: { _ in try memory.balance(source: .apiKey) }, fingerprint: { credentials.fingerprint(source: $0, identity: $1) },
            readWeb: webReader,
            detect: { _, _ in web ? .account : .apiKey }, loadHistory: { memory.savedHistory() }, saveHistory: { value, _ in memory.saveHistory(value) })
        return .init(services: services, seed: seed, now: { memory.date() }, output: { _ in })
    }
    private func configure(_ reader: DeepSeekBalanceCoordinator, web: Bool = false) async {
        await reader.configure(home: home, source: web ? .web : .apiKey, enabled: true, recentProvider: nil, context: 1)
    }
    private func refresh(_ reader: DeepSeekBalanceCoordinator) async -> DeepSeekBalanceState {
        let started = await reader.refreshIfDue(active: true, force: true)
        XCTAssertTrue(started)
        await reader.refreshCompletion?.value
        return await reader.currentState()
    }
    private func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    private func assertPrivate(_ history: DeepSeekBalanceHistory, forbidden: [String]) throws {
        let bytes = try JSONEncoder().encode(history), text = String(decoding: bytes, as: UTF8.self)
        for value in forbidden {
            XCTAssertFalse(text.contains(value))
            XCTAssertFalse(text.contains(Data(value.utf8).base64EncodedString()))
            XCTAssertFalse(text.contains(hex(value.utf8)))
            let unsalted = hex(SHA256.hash(data: Data(value.utf8)))
            XCTAssertFalse(text.contains(unsalted))
            XCTAssertFalse(text.contains(String(unsalted.prefix(32))))
        }
        let roundtrip = try JSONDecoder().decode(DeepSeekBalanceHistory.self, from: bytes)
        XCTAssertEqual(roundtrip, history)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["samples", "charged", "since", "source", "credentialFingerprint"]))
    }

    private final class SaltFiles: PlatformFileSystem, @unchecked Sendable {
        var bytes: Data?, regular = true, directory = false, writable = true
        var readLimit: Int?, readOffset: UInt64?, replacedURL: URL?
        func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
            guard let bytes else { return nil }
            return .init(identity: "synthetic-salt", size: UInt64(bytes.count), modified: Date(timeIntervalSince1970: 1_800_000_000),
                created: nil, isRegularFile: regular, isDirectory: directory)
        }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
            readLimit = maximumBytes; readOffset = offset
            return Data((bytes ?? Data()).dropFirst(Int(offset)).prefix(maximumBytes))
        }
        func replace(_ url: URL, with data: Data) -> Bool {
            guard writable else { return false }
            replacedURL = url; bytes = data; return true
        }
        func entries(in directory: URL) throws -> [URL] { [] }
    }

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var saved = DeepSeekBalanceHistory(), rawKey: String, at: Date
        private var total = 100.0, session: String?, salt: Data?, saltWrites = 0
        private var balanceFails = false, saltFails = false
        init(key: String, at: Date) { rawKey = key; self.at = at }
        func key() -> String? { lock.lock(); defer { lock.unlock() }; return rawKey }
        func date() -> Date { lock.lock(); defer { lock.unlock() }; return at }
        func savedHistory() -> DeepSeekBalanceHistory { lock.lock(); defer { lock.unlock() }; return saved }
        func saveHistory(_ value: DeepSeekBalanceHistory) { lock.lock(); defer { lock.unlock() }; saved = value }
        func changeKey(_ value: String) { lock.lock(); defer { lock.unlock() }; rawKey = value }
        func changeSession(_ value: String?) { lock.lock(); defer { lock.unlock() }; session = value }
        func advance(total: Double, seconds: TimeInterval = 60) { lock.lock(); defer { lock.unlock() }; self.total = total; at.addTimeInterval(seconds) }
        func failBalance(_ value: Bool) { lock.lock(); defer { lock.unlock() }; balanceFails = value }
        func failSalt(_ value: Bool) { lock.lock(); defer { lock.unlock() }; saltFails = value }
        func damageSalt(_ value: Data?) { lock.lock(); defer { lock.unlock() }; salt = value }
        func saltBytes() -> Data? { lock.lock(); defer { lock.unlock() }; return salt }
        func saltWriteCount() -> Int { lock.lock(); defer { lock.unlock() }; return saltWrites }
        func balance(source: DeepSeekBalance.Source) throws -> DeepSeekBalance {
            lock.lock(); defer { lock.unlock() }
            if balanceFails { throw DeepSeekBalanceError.connectionFailed }
            return .init(total: total, capturedAt: at, source: source, sessionFingerprint: source == .web ? session : nil)
        }
        func credentials() -> DeepSeekHistoryCredential {
            .init(loadSalt: { [self] in
                lock.lock(); defer { lock.unlock() }
                if saltFails { throw DeepSeekBalanceError.unavailable }
                return salt
            }, saveSalt: { [self] value in
                lock.lock(); defer { lock.unlock() }
                if saltFails { throw DeepSeekBalanceError.unavailable }
                salt = value; saltWrites += 1
            })
        }
    }
}
