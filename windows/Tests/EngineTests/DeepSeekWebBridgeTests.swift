import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekWebBridgeTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    func testHostReadWaitsForItsMatchingPublishedSnapshotAndCancellationReleasesIt() {
        var publication = DeepSeekWebHostPublication()
        let request = DeepSeekWebHostMessage(type: "hostRequest", requestID: "next", context: "new-web-source")
        XCTAssertTrue(publication.receive(request, publishedContext: "old-api-source", ready: false).isEmpty)
        XCTAssertEqual(publication.count, 1)
        let ready = publication.published(context: "new-web-source")
        XCTAssertEqual(ready.map(\.requestID), ["next"])
        XCTAssertEqual(publication.count, 0)
        XCTAssertEqual(publication.receive(request, publishedContext: "new-web-source", ready: true).map(\.requestID), ["next"])
        XCTAssertTrue(publication.receive(request, publishedContext: "old-api-source", ready: true).isEmpty,
            "A ready activity projection may still precede a new balance binding")
        XCTAssertTrue(publication.published(context: "old-api-source").isEmpty)
        XCTAssertEqual(publication.count, 1, "An unrelated earlier snapshot cannot discard the future binding's read")
        let cancel = DeepSeekWebHostMessage(type: "hostCancel", requestID: "next", context: "new-web-source")
        XCTAssertEqual(publication.receive(cancel, publishedContext: "old-api-source", ready: false).map(\.type), ["hostCancel"])
        XCTAssertEqual(publication.count, 0)
        XCTAssertTrue(publication.published(context: "new-web-source").isEmpty)
    }
    func testHostPublicationDropsSupersededSourcesAndBoundsPendingReadsAcrossSleepOrStop() {
        var publication = DeepSeekWebHostPublication()
        for index in 0..<12 {
            let request = DeepSeekWebHostMessage(type: "hostRequest", requestID: String(index), context: "old-source")
            XCTAssertTrue(publication.receive(request, publishedContext: nil, ready: false).isEmpty)
            XCTAssertLessThanOrEqual(publication.count, DeepSeekWebBridge.maximumPendingRequests)
        }
        publication.rebind(context: "replacement-source")
        XCTAssertTrue(publication.published(context: "replacement-source").isEmpty)
        XCTAssertEqual(publication.count, 0)
        let current = DeepSeekWebHostMessage(type: "hostRequest", requestID: "current", context: "replacement-source")
        _ = publication.receive(current, publishedContext: nil, ready: false)
        publication.reset()
        XCTAssertEqual(publication.count, 0)
        XCTAssertTrue(publication.published(context: "replacement-source").isEmpty)
    }
    func testOnlyAnOptedInHostCanCompleteTheMatchingNumericRequest() async throws {
        let capture = Capture(), at = date, context = UUID().uuidString
        let bridge = DeepSeekWebBridge(now: { at }, output: { await capture.add($0) })
        do { _ = try await bridge.read(context: context); XCTFail("A host must opt in before collection") }
        catch { XCTAssertEqual(error as? DeepSeekBalanceError, .connectionFailed) }
        await bridge.setAvailable(true)
        let task = Task { try await bridge.read(context: context) }
        let received = await capture.request(), request = try XCTUnwrap(received)
        XCTAssertEqual(request.context, context); XCTAssertEqual(request.operation, "deepseek.balance")
        let reply = DeepSeekWebReply(state: "ok", normal: ["80"], bonus: ["6.4"], estimation: "21600000", alertEnabled: true, alertBound: "20", sessionFingerprint: String(repeating: "1", count: 64))
        var accepted = await bridge.complete(id: request.requestID, context: UUID().uuidString, reply: reply); XCTAssertFalse(accepted)
        accepted = await bridge.complete(id: UUID().uuidString, context: context, reply: reply); XCTAssertFalse(accepted)
        accepted = await bridge.complete(id: request.requestID, context: context, reply: reply); XCTAssertTrue(accepted)
        let balance = try await task.value
        XCTAssertEqual(balance.total, 86.4); XCTAssertEqual(balance.source, .web); XCTAssertEqual(balance.capturedAt, at)
        XCTAssertEqual(balance.alertBound, 20); XCTAssertEqual(balance.tokenEstimation, 21600000)
        XCTAssertEqual(balance.sessionFingerprint, String(repeating: "1", count: 64))
        accepted = await bridge.complete(id: request.requestID, context: context, reply: reply); XCTAssertFalse(accepted)
        let frame = try JSONEncoder().encode(request)
        XCTAssertFalse(String(decoding: frame, as: UTF8.self).contains("userToken"))
        await bridge.setAvailable(false)
    }
    func testCancellationRevokesTheRequestAndNotifiesTheBrowser() async throws {
        let capture = Capture(), at = date
        let bridge = DeepSeekWebBridge(now: { at }, output: { await capture.add($0) })
        await bridge.setAvailable(true)
        let task = Task { try await bridge.read(context: UUID().uuidString) }
        let received = await capture.request(), request = try XCTUnwrap(received); task.cancel()
        let cancelled = await capture.waitForCancel(); XCTAssertTrue(cancelled)
        do { _ = try await task.value; XCTFail("The cancelled request returned a wallet") } catch { XCTAssertTrue(error is CancellationError) }
        let accepted = await bridge.complete(id: request.requestID, context: request.context, reply: .init(state: "ok", normal: ["999"]))
        XCTAssertFalse(accepted)
        await bridge.setAvailable(false)
    }
    func testTimeoutAndHostShutdownCannotLeaveAReadWaiting() async throws {
        let capture = Capture(), at = date
        let bridge = DeepSeekWebBridge(timeout: 100_000_000, now: { at }, output: { await capture.add($0) })
        await bridge.setAvailable(true)
        let task = Task { try await bridge.read(context: UUID().uuidString) }
        do { _ = try await task.value; XCTFail("An unanswered request must time out") }
        catch { XCTAssertEqual(error as? DeepSeekBalanceError, .connectionFailed) }
        let cancelled = await capture.waitForCancel(); XCTAssertTrue(cancelled)
        let shutdownCapture = Capture()
        let shutdown = DeepSeekWebBridge(now: { at }, output: { await shutdownCapture.add($0) })
        await shutdown.setAvailable(true)
        let next = Task { try await shutdown.read(context: UUID().uuidString) }
        let pending = await shutdownCapture.request(); XCTAssertNotNil(pending)
        await shutdown.setAvailable(false); await bridge.setAvailable(false)
        do { _ = try await next.value; XCTFail("Host shutdown must finish its pending request") }
        catch { XCTAssertEqual(error as? DeepSeekBalanceError, .connectionFailed) }
    }
    func testInvalidOrUnboundedHostValuesNeverBecomeWalletReadings() throws {
        for reply in [
            DeepSeekWebReply(state: "ok", normal: ["not-an-amount"]),
            .init(state: "ok", normal: Array(repeating: "1", count: 65)),
            .init(state: "ok", normal: ["NaN"]), .init(state: "ok", normal: ["-1"]),
            .init(state: "ok", normal: ["1"], alertBound: "unrelated-private-text"),
            .init(state: "unknown")
        ] {
            XCTAssertThrowsError(try reply.balance(at: date)) { XCTAssertEqual($0 as? DeepSeekBalanceError, .invalidReply) }
        }
        XCTAssertThrowsError(try DeepSeekWebReply(state: "offline").balance(at: date)) { XCTAssertEqual($0 as? DeepSeekBalanceError, .connectionFailed) }
        XCTAssertThrowsError(try DeepSeekWebReply(state: "signedOut").balance(at: date)) { XCTAssertEqual($0 as? DeepSeekBalanceError, .signedOut) }
        XCTAssertThrowsError(try DeepSeekWebReply(state: "challenge").balance(at: date)) { XCTAssertEqual($0 as? DeepSeekBalanceError, .challenge) }
    }
    private actor Capture {
        private var messages: [DeepSeekWebHostMessage] = []
        func add(_ message: DeepSeekWebHostMessage) { messages.append(message) }
        func request(count: Int = 1) async -> DeepSeekWebHostMessage? {
            let start = ProcessInfo.processInfo.systemUptime
            while messages.filter({ $0.type == "hostRequest" }).count < count, ProcessInfo.processInfo.systemUptime - start < 3 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return messages.filter { $0.type == "hostRequest" }.dropFirst(count - 1).first
        }
        func waitForCancel() async -> Bool {
            let start = ProcessInfo.processInfo.systemUptime
            while !messages.contains(where: { $0.type == "hostCancel" }), ProcessInfo.processInfo.systemUptime - start < 3 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return messages.contains { $0.type == "hostCancel" }
        }
    }
}
