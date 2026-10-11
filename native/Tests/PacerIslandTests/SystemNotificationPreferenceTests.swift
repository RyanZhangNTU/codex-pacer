import XCTest
@testable import PacerIsland

@MainActor
final class SystemNotificationPreferenceTests: XCTestCase {
    private final class Prompt {
        var onRequest: (() -> Void)?
        private var nextID = 0
        private var replies: [Int: CheckedContinuation<Bool, Never>] = [:]

        func request() async -> Bool {
            nextID += 1
            let id = nextID
            return await withCheckedContinuation { continuation in
                replies[id] = continuation
                onRequest?()
            }
        }
        func answer(_ allowed: Bool, request: Int = 1) {
            replies.removeValue(forKey: request)?.resume(returning: allowed)
        }
    }

    private func defaults() throws -> UserDefaults {
        let domain = "com.codexpacer.notification-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return defaults
    }

    func testLateAuthorizationCannotReenableNotificationsAfterUserTurnsThemOff() async throws {
        let defaults = try defaults(), prompt = Prompt(), started = expectation(description: "permission pending")
        prompt.onRequest = { started.fulfill() }
        let preference = SystemNotificationPreference(defaults: defaults, requestPermission: { await prompt.request() })
        let request = try XCTUnwrap(preference.setEnabled(true))
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(preference.enabled)
        XCTAssertFalse(defaults.bool(forKey: "systemNotifications"), "Delivery stays off until authorization succeeds")
        preference.setEnabled(false)
        prompt.answer(true)
        await request.value
        XCTAssertFalse(preference.enabled)
        XCTAssertFalse(preference.denied)
        XCTAssertFalse(defaults.bool(forKey: "systemNotifications"))
        XCTAssertFalse(SystemNotificationPreference(defaults: defaults).enabled, "Normal relaunch must retain the last switch choice")
    }

    func testDeniedPermissionTurnsSwitchOffAndRetainsExplanationUntilNextUserChoice() async throws {
        let defaults = try defaults(), prompt = Prompt(), started = expectation(description: "permission pending")
        prompt.onRequest = { started.fulfill() }
        let preference = SystemNotificationPreference(defaults: defaults, requestPermission: { await prompt.request() })
        let request = try XCTUnwrap(preference.setEnabled(true))
        await fulfillment(of: [started], timeout: 1)
        prompt.answer(false)
        await request.value
        XCTAssertFalse(preference.enabled)
        XCTAssertTrue(preference.denied, "The programmatic rollback must not clear the refusal explanation")
        XCTAssertFalse(defaults.bool(forKey: "systemNotifications"))
        preference.setEnabled(false)
        XCTAssertFalse(preference.denied, "A later explicit user choice can clear the explanation")
    }

    func testOlderReplyCannotOverrideNewPermissionRequest() async throws {
        let defaults = try defaults(), prompt = Prompt()
        let firstStarted = expectation(description: "first permission request")
        prompt.onRequest = { firstStarted.fulfill() }
        let preference = SystemNotificationPreference(defaults: defaults, requestPermission: { await prompt.request() })
        let first = try XCTUnwrap(preference.setEnabled(true))
        await fulfillment(of: [firstStarted], timeout: 1)
        preference.setEnabled(false)
        let nextStarted = expectation(description: "new permission request")
        prompt.onRequest = { nextStarted.fulfill() }
        let next = try XCTUnwrap(preference.setEnabled(true))
        await fulfillment(of: [nextStarted], timeout: 1)
        prompt.answer(true, request: 2)
        await next.value
        prompt.answer(false, request: 1)
        await first.value
        XCTAssertTrue(preference.enabled)
        XCTAssertFalse(preference.denied)
        XCTAssertTrue(defaults.bool(forKey: "systemNotifications"))
        XCTAssertTrue(SystemNotificationPreference(defaults: defaults).enabled)
        XCTAssertNil(preference.setEnabled(true), "Already enabled notifications do not request permission again")
    }
}
