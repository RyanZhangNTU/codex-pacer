import CryptoKit
import XCTest
@testable import PacerIsland

@MainActor
final class ClaudeWebSessionBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let token = "synthetic-pacer-web-session"

    private func cookie(_ name: String = "sessionKey", value: String? = nil, domain: String = "claude.ai",
                        path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value ?? token, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testBridgeIncludesOnlyClaudeAPICookiesAndHashesOnlyTheSessionKey() throws {
        let cookies = try [cookie(), cookie("cf_clearance", value: "synthetic-clearance", domain: ".claude.ai", path: "/api/"),
            cookie("api_preference", value: "yes", path: "/api"),
            cookie("settings_only", path: "/settings"), cookie("near_api", path: "/api-private"),
            cookie("foreign", domain: "accounts.google.com"), cookie("subdomain", domain: "auth.claude.ai"),
            cookie("suffix", domain: "claude.ai.example.invalid")]
        let session = try XCTUnwrap(ClaudeWebSessionStore.session(from: cookies, now: now))
        let fields = Set(session.cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(fields, Set(["sessionKey=" + token, "cf_clearance=synthetic-clearance", "api_preference=yes"]))
        let expectedHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(session.sessionHash, expectedHash)
        XCTAssertNil(session.organizationID, "Cookie presence cannot choose an organization")
    }

    func testDuplicateApplicableSessionKeysAreRejectedButOtherPathsAndDomainsCannotAuthenticate() throws {
        let root = try cookie()
        XCTAssertNil(ClaudeWebSessionStore.session(from: [root, try cookie(value: "other", path: "/api")], now: now))
        let ignored = try [cookie(value: "other", path: "/settings"), cookie(value: "other", domain: "accounts.google.com")]
        XCTAssertNil(ClaudeWebSessionStore.session(from: ignored, now: now))
        let session = try XCTUnwrap(ClaudeWebSessionStore.session(from: [root] + ignored, now: now))
        XCTAssertEqual(session.cookieHeader, "sessionKey=" + token)
    }

    func testExpiryAndOrganizationUUIDKeepUnavailableDataExplicit() throws {
        XCTAssertNil(ClaudeWebSessionStore.session(from: [try cookie(expires: now)], now: now))
        XCTAssertNil(ClaudeWebSessionStore.session(from: [try cookie(expires: now.addingTimeInterval(-1))], now: now))
        let current = try cookie(expires: now.addingTimeInterval(60))
        let organization = "019A0000-0000-7000-8000-000000000031"
        let session = try XCTUnwrap(ClaudeWebSessionStore.session(from: [current,
            try cookie("cf_clearance", value: "expired", expires: now.addingTimeInterval(-1)),
            try cookie("lastActiveOrg", value: organization)], now: now))
        XCTAssertEqual(session.organizationID, organization.lowercased())
        XCTAssertFalse(session.cookieHeader.contains("cf_clearance"))
        let invalid = try XCTUnwrap(ClaudeWebSessionStore.session(from: [current, try cookie("lastActiveOrg", value: "unknown")], now: now))
        XCTAssertNil(invalid.organizationID, "An invalid workspace cookie must require explicit selection")
    }

    func testUnsafeAndOversizedCookieInputCannotCreateAnUnboundedHeader() throws {
        for value in ["value\r\nInjected: true", "value; injected=true", String(repeating: "x", count: 16_385)] {
            let candidate = HTTPCookie(properties: [.name: "sessionKey", .value: value, .domain: "claude.ai", .path: "/"])
            let result = candidate.flatMap { ClaudeWebSessionStore.session(from: [$0], now: now) }
            XCTAssertNil(result)
        }
        let many = try [cookie()] + (0..<64).map { try cookie("aux\($0)", value: "synthetic") }
        XCTAssertNil(ClaudeWebSessionStore.session(from: many, now: now))
        let oversizedHeader = try [cookie()] + (0..<40).map { try cookie("aux\($0)", value: String(repeating: "x", count: 1_000)) }
        XCTAssertNil(ClaudeWebSessionStore.session(from: oversizedHeader, now: now))
    }
}
