import XCTest
@testable import PacerIsland

final class WebLoginSessionWatchTests: XCTestCase {
    func testFirstSignInIsNewOnlyAfterTheSignedOutBaseline() {
        var watch = WebLoginSessionWatch()
        XCTAssertFalse(watch.observe(nil), "The first observation is the baseline")
        XCTAssertEqual(watch.outcome(for: nil), .none, "Closing while signed out completes nothing")
        XCTAssertTrue(watch.observe("synthetic-a"))
        XCTAssertTrue(watch.observe("synthetic-a"), "A repeated check keeps reporting the same new session")
        XCTAssertEqual(watch.outcome(for: "synthetic-a"), .new)
    }

    func testReopeningWhileSignedInKeepsTheSessionUntilAnotherAppears() {
        var watch = WebLoginSessionWatch()
        XCTAssertFalse(watch.observe("synthetic-a"))
        XCTAssertFalse(watch.observe("synthetic-a"), "A challenge or reload on the same session is not a sign-in")
        XCTAssertEqual(watch.outcome(for: "synthetic-a"), .existing)
        XCTAssertFalse(watch.observe(nil), "Signing out on the page is not a sign-in")
        XCTAssertEqual(watch.outcome(for: nil), .none)
        XCTAssertTrue(watch.observe("synthetic-b"), "Switching accounts gives a different session")
        XCTAssertEqual(watch.outcome(for: "synthetic-b"), .new)
    }

    func testUnknownBaselineNeverClaimsANewSession() {
        let watch = WebLoginSessionWatch()
        XCTAssertEqual(watch.outcome(for: "synthetic-a"), .existing,
            "Without a baseline a present session is only retried, keeping saved choices")
        XCTAssertEqual(watch.outcome(for: nil), .none)
    }
}
