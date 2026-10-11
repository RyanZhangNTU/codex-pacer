import XCTest
import CommonCrypto
@testable import PacerCore

final class ClaudeQuotaCredentialCacheTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let organization = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private var scope: String { ClaudeQuotaDecoder.digest("claude|" + account + "|" + organization) }
    private var binding: String { ClaudeQuotaDecoder.digest("fixture-home|" + account) }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    func testPersistentPayloadContainsOnlyNarrowTokenExpiryAndOpaqueBindings() throws {
        let credential = ClaudeOAuthCredential(token: "fixture-access-token", expiresAt: date.addingTimeInterval(100), plan: "pro", scope: scope)
        let data = try XCTUnwrap(ClaudeQuotaCredentialCache.encode(credential, accountBinding: binding, now: date))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version", "account_binding", "scope", "access_token", "expires_at", "plan"])
        let restored = try XCTUnwrap(ClaudeQuotaCredentialCache.decode(data, accountBinding: binding, expectedScope: scope, now: date))
        XCTAssertEqual(restored.token, credential.token)
        XCTAssertEqual(restored.expiresAt, credential.expiresAt)
        XCTAssertNil(try ClaudeQuotaCredentialCache.decode(data, accountBinding: String(repeating: "c", count: 64), expectedScope: scope, now: date))
        XCTAssertNil(try ClaudeQuotaCredentialCache.decode(data, accountBinding: binding, expectedScope: String(repeating: "d", count: 64), now: date))
        XCTAssertThrowsError(try ClaudeQuotaCredentialCache.decode(data, accountBinding: binding, expectedScope: scope, now: date.addingTimeInterval(101))) {
            XCTAssertEqual($0 as? ClaudeQuotaError, .credentialsExpired)
        }
        XCTAssertNil(ClaudeQuotaCredentialCache.encode(ClaudeOAuthCredential(token: "fixture-access-token", expiresAt: nil, plan: nil, scope: scope), accountBinding: binding, now: date))
        let home = URL(fileURLWithPath: "/fixture/claude")
        XCTAssertNotEqual(ClaudeQuotaCredentialCache.location(home: home, source: "desktop"), ClaudeQuotaCredentialCache.location(home: home, source: "cli"))
        XCTAssertNotEqual(ClaudeQuotaCredentialCache.location(home: home, source: "desktop"), ClaudeQuotaCredentialCache.location(home: URL(fileURLWithPath: "/other/claude"), source: "desktop"))
    }

    private func encrypted(token: String, org: String? = nil) throws -> Data {
        let key = try XCTUnwrap(ClaudeDesktopCredentialStore.deriveKey(password: Data("fixture-safe-storage-password".utf8)))
        let fields: [String: Any] = ["acct:\(account)|desktop-client:\(org ?? organization):https://api.anthropic.com:user:profile user:inference":
            ["token": token, "expiresAt": date.addingTimeInterval(100).timeIntervalSince1970 * 1000]]
        let plain = try JSONSerialization.data(withJSONObject: fields), iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var result = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128), count = 0
        let status = key.withUnsafeBytes { key in plain.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key.baseAddress, key.count, iv, input.baseAddress, plain.count, &result, result.count, &count)
        } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + Data(result.prefix(count))
    }

    func testOneConnectRetainsMemoryKeyRotatesNarrowTokenAndQuietRelaunchUsesOnlyCache() throws {
        let identity = ClaudeAccountIdentity(accountID: account, scope: scope, organizationID: organization)
        let config = Box(ClaudeDesktopCredentialStore.Configuration(account: account, ciphertext: try encrypted(token: "first-fixture-token"), identity: identity))
        let persisted = Box<Data?>(nil), passwordReads = Box(0), forgotten = Box(0)
        let capturedAt = date, accountBinding = binding
        func reader(interactive: Bool) -> ClaudeDesktopCredentialReader {
            ClaudeDesktopCredentialReader(allowInteraction: interactive, configuration: { config.value }, password: {
                passwordReads.value += 1
                return Data("fixture-safe-storage-password".utf8)
            }, cached: { _, scope, fingerprint in
                guard let data = persisted.value else { return nil }
                return try ClaudeQuotaCredentialCache.decode(data, accountBinding: accountBinding, expectedScope: scope, now: capturedAt,
                                                            expectedCiphertextFingerprint: fingerprint)
            }, remember: { credential, _, fingerprint in
                persisted.value = ClaudeQuotaCredentialCache.encode(credential, accountBinding: accountBinding, now: capturedAt,
                                                                   ciphertextFingerprint: fingerprint)
                return persisted.value != nil
            }, forget: { forgotten.value += 1; persisted.value = nil }, now: { capturedAt })
        }
        let connected = reader(interactive: true)
        let first = try XCTUnwrap(connected.read())
        XCTAssertEqual(passwordReads.value, 1)
        XCTAssertNil(persisted.value, "An unverified credential must not be persisted")
        XCTAssertTrue(connected.rememberVerified(first))
        connected.finishConnectionAttempt()
        config.value = ClaudeDesktopCredentialStore.Configuration(account: account, ciphertext: try encrypted(token: "rotated-fixture-token"), identity: identity)
        let rotated = try XCTUnwrap(connected.read())
        XCTAssertEqual(rotated.token, "rotated-fixture-token")
        XCTAssertEqual(passwordReads.value, 1)
        XCTAssertTrue(connected.rememberVerified(rotated))
        connected.shutdown()
        let relaunched = reader(interactive: false)
        XCTAssertEqual(try relaunched.read()?.token, "rotated-fixture-token")
        XCTAssertEqual(passwordReads.value, 1, "Normal relaunch must not read Claude Safe Storage")
        XCTAssertEqual(forgotten.value, 0)
    }

    func testQuietMissingExpiredAndConsumedConnectionNeverReadForeignPassword() throws {
        let identity = ClaudeAccountIdentity(accountID: account, scope: scope, organizationID: organization)
        let configuration = ClaudeDesktopCredentialStore.Configuration(account: account, ciphertext: try encrypted(token: "fixture-token"), identity: identity)
        let passwordReads = Box(0), capturedAt = date, savedScope = scope
        for interactive in [false, true] {
            let reader = ClaudeDesktopCredentialReader(allowInteraction: interactive, configuration: { configuration }, password: {
                passwordReads.value += 1; return Data("fixture-safe-storage-password".utf8)
            }, cached: { _, _, _ in nil }, remember: { _, _, _ in XCTFail("unverified token"); return false }, forget: {}, now: { capturedAt })
            if interactive { reader.finishConnectionAttempt() }
            XCTAssertThrowsError(try reader.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .keychainAccessRequired) }
        }
        let expired = ClaudeDesktopCredentialReader(allowInteraction: false, configuration: { configuration }, password: {
            passwordReads.value += 1; return Data("fixture-safe-storage-password".utf8)
        }, cached: { _, _, _ in
            let credential = ClaudeOAuthCredential(token: "fixture-token", expiresAt: capturedAt.addingTimeInterval(1), plan: nil, scope: savedScope)
            let data = ClaudeQuotaCredentialCache.encode(credential, accountBinding: savedScope, now: capturedAt)!
            return try ClaudeQuotaCredentialCache.decode(data, accountBinding: savedScope, expectedScope: savedScope, now: capturedAt.addingTimeInterval(2))
        }, remember: { _, _, _ in false }, forget: {}, now: { capturedAt })
        XCTAssertThrowsError(try expired.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .credentialsExpired) }
        XCTAssertEqual(passwordReads.value, 0)
    }

    func testAccountChangeDiscardsMemoryAndCannotPersistPreviousCredentialUnderNewAccount() throws {
        let capturedAt = date, savedScope = scope
        let identity = ClaudeAccountIdentity(accountID: account, scope: scope, organizationID: organization)
        let config = Box(ClaudeDesktopCredentialStore.Configuration(account: account, ciphertext: try encrypted(token: "fixture-token"), identity: identity))
        let remembered = Box(0), passwordReads = Box(0)
        let reader = ClaudeDesktopCredentialReader(allowInteraction: true, configuration: { config.value }, password: {
            passwordReads.value += 1; return Data("fixture-safe-storage-password".utf8)
        }, cached: { _, _, _ in nil }, remember: { _, _, _ in remembered.value += 1; return true }, forget: {}, now: { capturedAt })
        let issued = try XCTUnwrap(reader.read())
        config.value = ClaudeDesktopCredentialStore.Configuration(account: "cccccccc-cccc-cccc-cccc-cccccccccccc", ciphertext: config.value.ciphertext,
            identity: ClaudeAccountIdentity(accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc", scope: savedScope, organizationID: identity.organizationID))
        XCTAssertFalse(reader.rememberVerified(issued))
        XCTAssertEqual(remembered.value, 0)
        XCTAssertThrowsError(try reader.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .keychainAccessRequired) }
        XCTAssertEqual(passwordReads.value, 1)
    }

    func testAbsentCurrentOrganizationCannotReuseUnprovedPreviousOrganizationToken() throws {
        let capturedAt = date, savedScope = scope
        let configuration = ClaudeDesktopCredentialStore.Configuration(account: account, ciphertext: try encrypted(token: "fixture-token"), identity: nil)
        let cachedReads = Box(0), passwordReads = Box(0)
        let reader = ClaudeDesktopCredentialReader(allowInteraction: false, configuration: { configuration }, password: {
            passwordReads.value += 1; return Data("fixture-safe-storage-password".utf8)
        }, cached: { _, _, fingerprint in
            cachedReads.value += 1
            let previous = ClaudeOAuthCredential(token: "previous-org-fixture-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: savedScope)
            let unproved = ClaudeQuotaCredentialCache.encode(previous, accountBinding: savedScope, now: capturedAt)!
            return try ClaudeQuotaCredentialCache.decode(unproved, accountBinding: savedScope, expectedScope: nil, now: capturedAt,
                                                        expectedCiphertextFingerprint: fingerprint)
        }, remember: { _, _, _ in XCTFail("unverified organization"); return false }, forget: {}, now: { capturedAt })
        XCTAssertThrowsError(try reader.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .keychainAccessRequired) }
        XCTAssertEqual(cachedReads.value, 1)
        XCTAssertEqual(passwordReads.value, 0)
    }

    func testDesktopOnlyUniqueOrganizationCacheRequiresIdenticalEncryptedBlobOnRelaunch() throws {
        let capturedAt = date, accountBinding = binding
        let config = Box(ClaudeDesktopCredentialStore.Configuration(account: account, ciphertext: try encrypted(token: "fixture-token"), identity: nil))
        let persisted = Box<Data?>(nil), foreignReads = Box(0)
        func reader(interactive: Bool) -> ClaudeDesktopCredentialReader {
            ClaudeDesktopCredentialReader(allowInteraction: interactive, configuration: { config.value }, password: {
                foreignReads.value += 1; return Data("fixture-safe-storage-password".utf8)
            }, cached: { account, scope, fingerprint in
                guard let data = persisted.value else { return nil }
                return try ClaudeQuotaCredentialCache.decode(data, accountBinding: ClaudeQuotaDecoder.digest("fixture-home|" + account),
                    expectedScope: scope, now: capturedAt, expectedCiphertextFingerprint: fingerprint)
            }, remember: { credential, _, fingerprint in
                persisted.value = ClaudeQuotaCredentialCache.encode(credential, accountBinding: accountBinding, now: capturedAt,
                                                                   ciphertextFingerprint: fingerprint)
                return persisted.value != nil
            }, forget: { persisted.value = nil }, now: { capturedAt })
        }
        let connected = reader(interactive: true)
        XCTAssertTrue(connected.rememberVerified(try XCTUnwrap(connected.read())))
        connected.shutdown()
        let relaunched = reader(interactive: false)
        XCTAssertEqual(try relaunched.read()?.token, "fixture-token")
        XCTAssertEqual(foreignReads.value, 1)
        config.value = ClaudeDesktopCredentialStore.Configuration(account: account,
            ciphertext: try encrypted(token: "other-org-fixture-token", org: "cccccccc-cccc-cccc-cccc-cccccccccccc"), identity: nil)
        XCTAssertThrowsError(try relaunched.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .keychainAccessRequired) }
        XCTAssertEqual(foreignReads.value, 1, "Changed organization evidence cannot trigger an automatic password query")
    }

    func testCLIOnlyExplicitConnectionIsOneShotAndQuietReadsRespectAccountAndExpiry() throws {
        let capturedAt = date, savedScope = scope
        let clock = Box(date), activeScope = Box<String?>(scope), foreignReads = Box(0), forgotten = Box(0)
        let reader = ClaudeCLICredentialReader(allowInteraction: true, quiet: { throw ClaudeQuotaError.keychainAccessRequired }, interactive: {
            foreignReads.value += 1
            return ClaudeOAuthCredential(token: "fixture-cli-access-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: savedScope)
        }, identity: { activeScope.value }, forget: { forgotten.value += 1 }, now: { clock.value })
        XCTAssertEqual(try reader.read()?.token, "fixture-cli-access-token")
        reader.finishConnectionAttempt()
        XCTAssertEqual(try reader.read()?.token, "fixture-cli-access-token")
        XCTAssertEqual(foreignReads.value, 1)
        activeScope.value = String(repeating: "c", count: 64)
        XCTAssertThrowsError(try reader.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .keychainAccessRequired) }
        XCTAssertEqual(foreignReads.value, 1)
        XCTAssertEqual(forgotten.value, 1)
        let quiet = ClaudeCLICredentialReader(allowInteraction: false, quiet: {
            throw ClaudeQuotaError.credentialsExpired
        }, interactive: {
            foreignReads.value += 1; return nil
        }, identity: { activeScope.value }, forget: {}, now: { clock.value })
        XCTAssertThrowsError(try quiet.read()) { XCTAssertEqual($0 as? ClaudeQuotaError, .credentialsExpired) }
        XCTAssertEqual(foreignReads.value, 1)
    }

    func testCLIOnlyConnectDoesNotLetStaleFileCredentialHideFreshAuthorizedToken() throws {
        let capturedAt = date, savedScope = scope
        let quietReads = Box(0), foreignReads = Box(0)
        let reader = ClaudeCLICredentialReader(allowInteraction: true, quiet: {
            quietReads.value += 1
            return ClaudeOAuthCredential(token: "stale-file-fixture-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: savedScope)
        }, interactive: {
            foreignReads.value += 1
            return ClaudeOAuthCredential(token: "fresh-keychain-fixture-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: savedScope)
        }, identity: { savedScope }, forget: {}, now: { capturedAt })
        XCTAssertEqual(try reader.read()?.token, "fresh-keychain-fixture-token")
        reader.finishConnectionAttempt()
        XCTAssertEqual(try reader.read()?.token, "fresh-keychain-fixture-token", "Reply verification must preserve the chosen source")
        XCTAssertEqual(foreignReads.value, 1)
        XCTAssertEqual(quietReads.value, 0)
    }

    func testCLINormalRelaunchPrefersVerifiedOwnedTokenOverStaleFileWithoutForeignRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-cli-cache-relaunch-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity: [String: Any] = ["oauthAccount": ["accountUuid": account, "organizationUuid": organization]]
        try JSONSerialization.data(withJSONObject: identity).write(to: root.appendingPathComponent(".claude.json"))
        let capturedAt = date
        let stale: [String: Any] = ["claudeAiOauth": ["accessToken": "stale-file-fixture-token",
            "expiresAt": capturedAt.addingTimeInterval(100).timeIntervalSince1970 * 1000]]
        try JSONSerialization.data(withJSONObject: stale).write(to: home.appendingPathComponent(".credentials.json"))
        let active = try XCTUnwrap(ClaudeCredentialStore.identity(userHome: root, home: home))
        let persisted = Box<Data?>(nil), foreignReads = Box(0)
        let accountBinding = ClaudeQuotaCredentialCache.accountBinding(home: home, account: active.accountID)
        let quiet: @Sendable () throws -> ClaudeOAuthCredential? = {
            try ClaudeCredentialStore.read(userHome: root, home: home, environment: [:], cachedCredential: { identity in
                guard let data = persisted.value else { return nil }
                return try ClaudeQuotaCredentialCache.decode(data, accountBinding: accountBinding, expectedScope: identity.scope, now: capturedAt)
            }, now: capturedAt)
        }
        let connected = ClaudeCLICredentialReader(allowInteraction: true, quiet: quiet, interactive: {
            foreignReads.value += 1
            return ClaudeOAuthCredential(token: "fresh-keychain-fixture-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: active.scope)
        }, identity: { active.scope }, forget: {}, now: { capturedAt })
        let verified = try XCTUnwrap(connected.read())
        persisted.value = ClaudeQuotaCredentialCache.encode(verified, accountBinding: accountBinding, now: capturedAt)
        connected.shutdown()
        let relaunched = ClaudeCLICredentialReader(allowInteraction: false, quiet: quiet, interactive: {
            foreignReads.value += 1; XCTFail("normal relaunch must not access Claude's Keychain"); return nil
        }, identity: { active.scope }, forget: {}, now: { capturedAt })
        XCTAssertEqual(try relaunched.read()?.token, "fresh-keychain-fixture-token")
        XCTAssertEqual(foreignReads.value, 1)
        persisted.value = nil
        XCTAssertEqual(try quiet()?.token, "stale-file-fixture-token", "Quiet file fallback remains available without a saved token")
    }
}
