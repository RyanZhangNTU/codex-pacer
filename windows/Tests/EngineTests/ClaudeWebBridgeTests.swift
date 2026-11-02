import Foundation
import XCTest
@testable import PacerCore

private final class ClaudeHostFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ClaudeWebHostMessage] = []
    func append(_ value: ClaudeWebHostMessage) { lock.lock(); defer { lock.unlock() }; messages.append(value) }
    func all() -> [ClaudeWebHostMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    func request() async throws -> ClaudeWebHostMessage {
        for _ in 0..<200 { if let value = all().last(where: { $0.type == "hostRequest" }) { return value }; try await Task.sleep(nanoseconds: 1_000_000) }
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
            for _ in 0..<100 where !frames.all().contains(where: { $0.type == "hostCancel" }) { try await Task.sleep(nanoseconds: 1_000_000) }
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
}
