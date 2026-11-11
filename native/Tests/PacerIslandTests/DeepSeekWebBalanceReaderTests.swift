import WebKit
import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class DeepSeekWebBalanceReaderTests: XCTestCase {
    func testAStalledPageLoadUsesTheReadDeadline() async throws {
        var view: WKWebView?, failure: Error?
        let reader = DeepSeekWebBalanceReader(timeout: .milliseconds(50), dataStore: .nonPersistent()) { view = $0 }
        let task = Task { @MainActor in
            do { _ = try await reader.sessionFingerprint() } catch { failure = error }
        }
        defer { task.cancel() }
        let completed = try await TestWait.until { failure != nil }
        XCTAssertTrue(completed)
        XCTAssertEqual(failure as? DeepSeekBalanceError, .timedOut)
        XCTAssertNotNil(view)
        XCTAssertNil(view?.navigationDelegate)
    }

    func testCancellationAndProcessTerminationReleaseOnlyTheirOwnRead() async throws {
        var views: [WKWebView] = [], firstError: Error?, secondError: Error?
        let reader = DeepSeekWebBalanceReader(dataStore: .nonPersistent()) { views.append($0) }
        let first = Task { @MainActor in
            do { _ = try await reader.sessionFingerprint() } catch { firstError = error }
        }
        defer { first.cancel() }
        let firstStarted = try await TestWait.until { views.count == 1 }
        guard firstStarted else { return XCTFail("The first load did not start") }
        first.cancel()
        let cancelled = try await TestWait.until { firstError != nil }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(firstError is CancellationError)
        XCTAssertNil(views[0].navigationDelegate)

        let second = Task { @MainActor in
            do { _ = try await reader.sessionFingerprint() } catch { secondError = error }
        }
        defer { second.cancel() }
        let secondStarted = try await TestWait.until { views.count == 2 }
        guard secondStarted else { return XCTFail("Cancellation did not release the reader") }
        reader.webViewWebContentProcessDidTerminate(views[0])
        XCTAssertNotNil(views[1].navigationDelegate, "An old callback cannot end the new read")
        reader.webViewWebContentProcessDidTerminate(views[1])
        let terminated = try await TestWait.until { secondError != nil }
        XCTAssertTrue(terminated)
        XCTAssertEqual(secondError as? DeepSeekBalanceError, .connectionFailed)
        XCTAssertNil(views[1].navigationDelegate)
    }
}
