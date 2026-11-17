@testable import PacerEngineSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PacerCore

private final class ClaudeHostFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ClaudeWebHostMessage] = []
    func append(_ value: ClaudeWebHostMessage) { lock.lock(); defer { lock.unlock() }; messages.append(value) }
    func all() -> [ClaudeWebHostMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    func request() async throws -> ClaudeWebHostMessage {
        try await TestWait.until { all().contains { $0.type == "hostRequest" } }
        if let value = all().last(where: { $0.type == "hostRequest" }) { return value }
        throw ClaudeQuotaError.timedOut
    }
}

final class ClaudeWebBridgeTests: XCTestCase {
    private let key = "synthetic-owned-cookie"
    private func reply() -> ClaudeWebSessionReply {
        .init(state: "ok", cookieHeader: "sessionKey=" + key, sessionHash: ClaudeQuotaDecoder.digest(key))
    }
    func testOnlyTheOwnedRequestAndSourceCanReceiveAnEphemeralSession() async throws {
        let frames = ClaudeHostFrames(), bridge = ClaudeWebBridge { frames.append($0) }
        await bridge.setAvailable(true)
        let context = UUID().uuidString, reading = Task { try await bridge.read(context: context) }
        let request = try await frames.request()
        let foreignSource = await bridge.complete(id: request.requestID, context: UUID().uuidString, reply: reply())
        let foreignRequest = await bridge.complete(id: UUID().uuidString, context: context, reply: reply())
        XCTAssertFalse(foreignSource); XCTAssertFalse(foreignRequest)
        let accepted = await bridge.complete(id: request.requestID, context: context, reply: reply())
        let value = try await reading.value
        XCTAssertTrue(accepted); XCTAssertEqual(value?.sessionHash, ClaudeQuotaDecoder.digest(key))
        let repeated = await bridge.complete(id: request.requestID, context: context, reply: reply()); XCTAssertFalse(repeated)
        let output = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        XCTAssertFalse(output.contains(key)); XCTAssertFalse(output.contains("cookieHeader")); XCTAssertEqual(request.operation, "claude.session")
        await bridge.setAvailable(false)
    }
    func testCancellationRevocationAndDeadlineRejectLateReplies() async throws {
        for mode in ["cancel", "revoke", "deadline"] {
            let frames = ClaudeHostFrames(), bridge = ClaudeWebBridge(timeout: mode == "deadline" ? 50_000_000 : 1_000_000_000) { frames.append($0) }
            await bridge.setAvailable(true)
            let context = UUID().uuidString, reading = Task { try await bridge.read(context: context) }
            let request = try await frames.request()
            if mode == "cancel" { reading.cancel() }
            else if mode == "revoke" { await bridge.setAvailable(false) }
            do { _ = try await reading.value; XCTFail("A revoked cookie request completed") }
            catch { XCTAssertTrue(error is CancellationError || error as? ClaudeQuotaError == .connectionFailed) }
            let accepted = await bridge.complete(id: request.requestID, context: context, reply: reply()); XCTAssertFalse(accepted)
            try await TestWait.until { frames.all().contains { $0.type == "hostCancel" } }
            XCTAssertTrue(frames.all().contains { $0.type == "hostCancel" && $0.context == context })
            await bridge.setAvailable(false)
        }
    }
    func testSessionValidationRejectsTamperedUnboundedAndMalformedValuesWithoutSecretErrors() throws {
        let valid = reply(); XCTAssertNotNil(try valid.session())
        XCTAssertNil(try ClaudeWebSessionReply(state: "signedOut").session())
        for invalid in [
            ClaudeWebSessionReply(state: "ok", cookieHeader: valid.cookieHeader, sessionHash: String(repeating: "0", count: 64)),
            .init(state: "ok", cookieHeader: "sessionKey=a; sessionKey=b", sessionHash: ClaudeQuotaDecoder.digest("a")),
            .init(state: "ok", cookieHeader: "sessionKey=" + key + "\n", sessionHash: valid.sessionHash),
            .init(state: "ok", cookieHeader: String(repeating: "x", count: 32769), sessionHash: valid.sessionHash),
            .init(state: "ok", cookieHeader: valid.cookieHeader, sessionHash: valid.sessionHash, organizationID: "not-a-workspace"),
            .init(state: "ok", cookieHeader: valid.cookieHeader, sessionHash: valid.sessionHash, userAgent: String(repeating: "x", count: 513)),
            .init(state: "unknown")
        ] {
            XCTAssertThrowsError(try invalid.session()) {
                XCTAssertEqual($0 as? ClaudeQuotaError, .invalidReply)
                XCTAssertFalse($0.localizedDescription.contains(key))
            }
        }
    }

    // #243: quota reads run in Pacer's own browser profile, which passed claude.ai's verification.
    func testPageReadsNameOnlyQuotaPathsAndReachOnlyTheirRequest() async throws {
        let frames = ClaudeHostFrames(), bridge = ClaudeWebBridge { frames.append($0) }
        let context = UUID().uuidString, organization = UUID().uuidString.lowercased()
        let path = "/api/organizations/" + organization + "/usage?cedar_ember=1"
        await bridge.setAvailable(true)
        do { _ = try await bridge.fetch(context: context, path: path); XCTFail("A host without page reads was asked to read") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .connectionFailed) }
        await bridge.setAvailable(true, fetching: true)
        for refused in ["/api/organizations/" + organization + "/members", "/api/organizations/" + organization.uppercased() + "/usage",
                        "/api/organizations/" + organization + "/usage?other=1", "/api/bootstrap", "https://claude.ai/api/account"] {
            do { _ = try await bridge.fetch(context: context, path: refused); XCTFail("A read outside the quota reads was sent: " + refused) }
            catch { XCTAssertEqual(error as? ClaudeQuotaError, .connectionFailed) }
        }
        XCTAssertTrue(frames.all().isEmpty)
        let reading = Task { try await bridge.fetch(context: context, path: path) }
        let request = try await frames.request()
        XCTAssertEqual(request.operation, "claude.fetch"); XCTAssertEqual(request.path, path)
        let reply = ClaudeWebFetchReply(state: "ok", status: 200, contentType: "application/json", body: "{}")
        let asCookies = await bridge.complete(id: request.requestID, context: context, reply: .init(state: "signedOut"))
        let foreign = await bridge.complete(id: request.requestID, context: UUID().uuidString, fetched: reply)
        XCTAssertFalse(asCookies); XCTAssertFalse(foreign)
        let accepted = await bridge.complete(id: request.requestID, context: context, fetched: reply)
        let value = try await reading.value
        XCTAssertTrue(accepted); XCTAssertEqual(value.body, "{}")
        let cookies = Task { try await bridge.read(context: context) }
        _ = try await TestWait.until { frames.all().contains { $0.type == "hostRequest" && $0.requestID != request.requestID } }
        let cookieRequest = try XCTUnwrap(frames.all().last { $0.type == "hostRequest" && $0.requestID != request.requestID })
        XCTAssertEqual(cookieRequest.operation, "claude.session"); XCTAssertNil(cookieRequest.path)
        let asPage = await bridge.complete(id: cookieRequest.requestID, context: context, fetched: reply)
        XCTAssertFalse(asPage); cookies.cancel()
        await bridge.setAvailable(false)
        let revoked = await bridge.fetchesInBrowser; XCTAssertFalse(revoked)
    }

    func testPageRepliesBecomeTheOriginalClientsResponses() throws {
        let url = URL(string: "https://claude.ai/api/account")!
        let (page, challenge) = try ClaudeWebFetchReply(state: "ok", status: 403, contentType: "text/html; charset=utf-8",
            cfMitigated: "challenge", retryAfter: "30", body: "<!doctype html><title>Just a moment...</title>").response(for: url)
        XCTAssertEqual(challenge.statusCode, 403); XCTAssertEqual(challenge.url, url)
        XCTAssertEqual(challenge.value(forHTTPHeaderField: "cf-mitigated"), "challenge"); XCTAssertEqual(challenge.value(forHTTPHeaderField: "Retry-After"), "30")
        XCTAssertTrue(ClaudeWebQuotaDecoder.isChallenge(page, response: challenge))
        let (json, ok) = try ClaudeWebFetchReply(state: "ok", status: 200, contentType: "application/json", body: "{\"uuid\":1}").response(for: url)
        XCTAssertEqual(ok.statusCode, 200); XCTAssertEqual(String(data: json, encoding: .utf8), "{\"uuid\":1}")
        XCTAssertFalse(ClaudeWebQuotaDecoder.isChallenge(json, response: ok))
        XCTAssertThrowsError(try ClaudeWebFetchReply(state: "signedOut").response(for: url)) { XCTAssertEqual($0 as? ClaudeQuotaError, .notLoggedIn) }
        XCTAssertThrowsError(try ClaudeWebFetchReply(state: "offline").response(for: url)) { XCTAssertEqual($0 as? ClaudeQuotaError, .connectionFailed) }
        for invalid in [ClaudeWebFetchReply(state: "tooLarge"), .init(state: "unknown", status: 200, body: "{}"), .init(state: "ok", status: 99, body: ""),
                        .init(state: "ok", status: 200), .init(state: "ok", status: 200, body: String(repeating: "x", count: ClaudeWebFetchReply.maximumBodyBytes + 1)),
                        .init(state: "ok", status: 200, contentType: "application/json\r\nSet-Cookie: x=1", body: "{}"),
                        .init(state: "ok", status: 200, retryAfter: String(repeating: "1", count: 257), body: "{}")] {
            XCTAssertThrowsError(try invalid.response(for: url)) { XCTAssertEqual($0 as? ClaudeQuotaError, .invalidReply) }
        }
    }

    func testQuotaReadsGoThroughThePageOnlyWhenTheHostOffersIt() async throws {
        let frames = ClaudeHostFrames(), bridge = ClaudeWebBridge { frames.append($0) }, context = UUID().uuidString, direct = DirectReads()
        let transport = BridgedClaudeQuotaClient.browserTransport(bridge: bridge, context: context) { request in
            direct.add(); return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let url = URL(string: "https://claude.ai/api/organizations/" + UUID().uuidString.lowercased() + "/usage?cedar_ember=1")!
        var request = URLRequest(url: url); request.setValue("sessionKey=" + key, forHTTPHeaderField: "Cookie")
        await bridge.setAvailable(true)
        _ = try await transport(request)
        XCTAssertEqual(direct.count, 1); XCTAssertTrue(frames.all().isEmpty, "A host without page reads keeps the engine's own client")
        await bridge.setAvailable(true, fetching: true)
        let reading = Task { try await transport(request) }
        let message = try await frames.request()
        XCTAssertEqual(message.path, url.path + "?cedar_ember=1")
        XCTAssertFalse(String(data: try JSONEncoder().encode(message), encoding: .utf8)!.contains(key), "The browser sends its own cookies")
        _ = await bridge.complete(id: message.requestID, context: context, fetched: .init(state: "ok", status: 403, contentType: "text/html",
            cfMitigated: "challenge", body: "<html>"))
        let (data, response) = try await reading.value
        XCTAssertEqual(response.statusCode, 403); XCTAssertEqual(response.url, url); XCTAssertTrue(ClaudeWebQuotaDecoder.isChallenge(data, response: response))
        XCTAssertEqual(direct.count, 1)
        var write = URLRequest(url: url); write.httpMethod = "POST"
        do { _ = try await transport(write); XCTFail("A write reached the browser") } catch { XCTAssertEqual(error as? ClaudeQuotaError, .invalidReply) }
        do { _ = try await transport(URLRequest(url: URL(string: "https://example.com/api/account")!)); XCTFail("Another site reached the browser") }
        catch { XCTAssertEqual(error as? ClaudeQuotaError, .invalidReply) }
        await bridge.setAvailable(false)
    }

    func testAChallengeRightAfterASignInNamesTheNetworkUntilAReadSucceeds() {
        func state(_ failure: ClaudeQuotaError?, snapshot: Bool = false) -> ClaudeQuotaState {
            .init(context: 1, connectionContext: UUID().uuidString, enabled: true, webAvailable: true, refreshing: false,
                snapshot: snapshot ? QuotaSnapshot(buckets: [], capturedAt: Date(), accountScope: nil, resetCredits: nil) : nil,
                history: .init(), error: failure?.errorDescription, warning: nil, failure: failure, source: nil, organizations: [],
                lastAttempt: nil, failureCount: failure == nil ? 0 : 1, successCount: 0)
        }
        let challenged = state(.webChallenge), blocked = L10n.text("claude.quota.web_blocked")
        var verification = ClaudeVerificationAfterSignIn()
        XCTAssertEqual(verification.error(challenged), challenged.error, "A challenge without a fresh sign-in still asks for one")
        verification.reset(signedIn: false)
        XCTAssertEqual(verification.error(challenged), challenged.error, "A cancelled sign-in proves nothing about the network")
        verification.reset(signedIn: true)
        XCTAssertEqual(verification.error(challenged), blocked)
        XCTAssertEqual(EngineClaudeConnection(challenged, paused: false, verification: verification).message, blocked)
        XCTAssertEqual(verification.error(state(.notLoggedIn)), state(.notLoggedIn).error, "Other failures keep their own message")
        verification.receive(challenged); XCTAssertEqual(verification.error(challenged), blocked)
        verification.receive(state(nil, snapshot: true))
        XCTAssertEqual(verification.error(challenged), challenged.error, "After a read succeeds, a later challenge asks for verification again")
        XCTAssertNotEqual(blocked, challenged.error)
    }
}

private final class DirectReads: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
