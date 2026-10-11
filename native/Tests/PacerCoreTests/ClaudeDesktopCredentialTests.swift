import XCTest
@testable import PacerCore

final class ClaudeDesktopCredentialTests: XCTestCase {
    private let account = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let organization = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let otherOrganization = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testChromiumMacV10KnownAnswerAndUnsupportedCipherRejection() throws {
        // Chromium's published macOS known-answer vector uses mock_password and
        // plaintext bytes 0..31. This is synthetic cryptographic test data.
        let bytes: [UInt8] = [0x76, 0x31, 0x30, 0xbf, 0x08, 0x6d, 0x20, 0x56, 0x86, 0x1a, 0x80,
            0xde, 0x82, 0x5f, 0xc9, 0x35, 0x86, 0x86, 0x30, 0x64, 0x4f, 0x2c, 0xa1, 0x87, 0x45,
            0x02, 0x13, 0xae, 0x66, 0x81, 0xb4, 0xd6, 0x43, 0xd1, 0x9b, 0x25, 0x81, 0xc8, 0x5c,
            0x88, 0x78, 0xc1, 0xbc, 0x97, 0xe7, 0x26, 0xa1, 0x0e, 0x51, 0xea, 0x77]
        let ciphertext = Data(bytes), password = Data("mock_password".utf8)
        XCTAssertEqual(ClaudeDesktopCredentialStore.decryptV10(ciphertext, password: password), Data((0..<32).map(UInt8.init)))
        XCTAssertNil(ClaudeDesktopCredentialStore.decryptV10(Data("v11".utf8) + ciphertext.dropFirst(3), password: password))
        XCTAssertNil(ClaudeDesktopCredentialStore.decryptV10(ciphertext.dropLast(), password: password))
        // CBC padding alone does not authenticate a key. Any bytes returned for
        // the wrong key must still fail the token-cache schema/account checks.
        if let wrong = ClaudeDesktopCredentialStore.decryptV10(ciphertext, password: Data("wrong-fixture-password".utf8)) {
            XCTAssertNil(ClaudeDesktopCredentialStore.decodeCache(wrong, activeAccount: account, now: date))
        }
        XCTAssertNil(ClaudeDesktopCredentialStore.decryptV10(ciphertext, password: Data()))
    }

    private func key(org: String, account: String? = nil, endpoint: String = "https://api.anthropic.com",
                     scopes: String = "user:profile user:inference") -> String {
        "acct:\(account ?? self.account)|desktop-client:\(org):\(endpoint):\(scopes)"
    }
    private func entry(token: String = "fixture-desktop-token", expires: Double = 1_800_000_100_000) -> [String: Any] {
        ["token": token, "expiresAt": expires]
    }

    func testActiveAccountAndObservedOrganizationSelectOnlyMatchingUnexpiredToken() throws {
        let entries: [String: Any] = [key(org: organization): entry(), key(org: otherOrganization): entry(token: "other-org-fixture-token"),
            key(org: organization, account: "dddddddd-dddd-dddd-dddd-dddddddddddd"): entry(token: "other-account-fixture-token")]
        let data = try JSONSerialization.data(withJSONObject: entries)
        let identity = ClaudeAccountIdentity(accountID: account.lowercased(), scope: "verified", organizationID: organization)
        let selected = try XCTUnwrap(ClaudeDesktopCredentialStore.decodeCache(data, activeAccount: account, expectedIdentity: identity, now: date))
        XCTAssertEqual(selected.token, "fixture-desktop-token")
        XCTAssertEqual(selected.scope, ClaudeQuotaDecoder.digest("claude|" + account.lowercased() + "|" + organization))
        XCTAssertNil(ClaudeDesktopCredentialStore.decodeCache(data, activeAccount: account, now: date))
        let wrong = ClaudeAccountIdentity(accountID: "dddddddd-dddd-dddd-dddd-dddddddddddd", scope: "different", organizationID: organization)
        XCTAssertNil(ClaudeDesktopCredentialStore.decodeCache(data, activeAccount: account, expectedIdentity: wrong, now: date))
    }

    func testDesktopOnlySingleOrganizationIsUsableButUnknownHostAndScopesAreRejected() throws {
        let valid = try JSONSerialization.data(withJSONObject: [key(org: organization): entry()])
        XCTAssertNotNil(ClaudeDesktopCredentialStore.decodeCache(valid, activeAccount: account, now: date))
        for entries: [String: Any] in [
            [key(org: organization, endpoint: "https://untrusted.example"): entry()],
            [key(org: organization, scopes: "user:inference"): entry()],
            [key(org: organization): entry(expires: 1_799_999_999_000)],
            [key(org: organization): entry(token: "fixture token with whitespace")],
            ["legacy-untagged-entry": entry()]
        ] {
            let data = try JSONSerialization.data(withJSONObject: entries)
            XCTAssertNil(ClaudeDesktopCredentialStore.decodeCache(data, activeAccount: account, now: date))
        }
    }
}
