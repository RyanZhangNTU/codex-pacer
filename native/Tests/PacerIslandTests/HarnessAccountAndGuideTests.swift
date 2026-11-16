import XCTest
import PacerCore
@testable import PacerIsland
import PacerTestSupport

/// The credits connection's timing and sign-in window rules, and the
/// floating guide's own lifetime, without signing in or opening a module's app.
@MainActor
final class HarnessAccountAndGuideTests: XCTestCase {
    func testCreditsReadEveryTwoMinutesAndBackOffAfterFailures() {
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .ready, failures: 0), 120)
        // A reading resets the count, but ready never waits longer whatever the count says.
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .ready, failures: 7), 120)
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .unavailable, failures: 0), 300)
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .unavailable, failures: 1), 300)
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .unavailable, failures: 2), 600)
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .unavailable, failures: 3), 1_200)
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .unavailable, failures: 4), 1_800, "Capped at 30 minutes")
        XCTAssertEqual(HarnessAccountConnection.nextRead(state: .unavailable, failures: 60), 1_800, "A long outage never overflows the shift")
    }

    func testSignInWindowChecksQuicklyForTwoMinutesThenSlower() {
        XCTAssertEqual(HarnessAccountConnection.loginCheckInterval(after: 0), .seconds(3))
        XCTAssertEqual(HarnessAccountConnection.loginCheckInterval(after: 119.9), .seconds(3))
        XCTAssertEqual(HarnessAccountConnection.loginCheckInterval(after: 120), .seconds(10))
        XCTAssertEqual(HarnessAccountConnection.loginCheckInterval(after: 3_600), .seconds(10))
    }

    func testSignInPopupsStartBlankOrSecureAndStayFew() throws {
        // A popup opened by script often has no URL yet, or starts blank.
        XCTAssertTrue(HarnessAccountConnection.opensLoginPopup(nil, open: 0))
        XCTAssertTrue(HarnessAccountConnection.opensLoginPopup(URL(string: "about:blank"), open: 0))
        XCTAssertTrue(HarnessAccountConnection.opensLoginPopup(URL(string: "https://sso.example.com/qr"), open: 3))
        XCTAssertTrue(HarnessAccountConnection.opensLoginPopup(URL(string: "HTTPS://sso.example.com/"), open: 0))
        XCTAssertFalse(HarnessAccountConnection.opensLoginPopup(URL(string: "http://sso.example.com/"), open: 0))
        XCTAssertFalse(HarnessAccountConnection.opensLoginPopup(URL(string: "javascript:alert(1)"), open: 0))
        XCTAssertFalse(HarnessAccountConnection.opensLoginPopup(URL(string: "file:///etc/hosts"), open: 0))
        XCTAssertFalse(HarnessAccountConnection.opensLoginPopup(URL(string: "https://sso.example.com/"), open: 4), "At most four at once")
    }

    func testConnectionStaysSignedOutAndIdleWhileOffOrNeverSignedIn() throws {
        let domain = testDefaultsName("harness-account-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { removeTestDefaults(domain) }
        let definition = try XCTUnwrap(HarnessRegistry.descriptor(for: .workbuddy)?.accountCredits)
        let connection = HarnessAccountConnection(provider: .workbuddy, definition: definition, defaults: defaults)
        var changes = 0
        connection.onChange = { changes += 1 }

        // Off: signing in does nothing.
        connection.connect()
        XCTAssertFalse(connection.busy)
        XCTAssertFalse(connection.signedIn)
        // On without a stored sign-in: nothing is read, and the state stays quiet.
        connection.configure(enabled: true)
        connection.refresh()
        XCTAssertFalse(connection.busy)
        XCTAssertEqual(connection.state, .signIn)
        XCTAssertNil(connection.credits)
        XCTAssertEqual(changes, 0)
        connection.stop()
    }

    func testGuideFloatShowsPendingWordsAndClosesWithNothingToSay() throws {
        let domain = testDefaultsName("harness-guide-float-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults)
        addTeardownBlock {
            await model.shutdown()
            removeTestDefaults(domain)
        }
        let float = HarnessGuideFloat(model: model)

        float.show(.workbuddy, on: nil, pending: (title: "Restarting", next: "Then trust it"))
        XCTAssertTrue(float.isShowing)
        XCTAssertEqual(float.provider, .workbuddy)
        XCTAssertEqual(float.pending?.title, "Restarting")
        XCTAssertFalse(float.followsApp)

        // A restart that goes on to open the app keeps the float, with the newer words.
        float.show(.workbuddy, on: nil, pending: (title: "Opening", next: "Then trust it"))
        XCTAssertTrue(float.isShowing)
        XCTAssertEqual(float.pending?.title, "Opening")

        float.close()
        XCTAssertFalse(float.isShowing)
        XCTAssertNil(float.provider)

        // With no step from the app and nothing pending, there is nothing to show.
        float.show(.workbuddy, on: nil, pending: nil)
        XCTAssertFalse(float.isShowing)
        XCTAssertNil(float.provider)
    }
}
