import AppKit
import ServiceManagement
import XCTest
@testable import PacerIsland

@MainActor
final class LaunchAtLoginPreferenceTests: XCTestCase {
    private final class LoginItems: LoginItemService {
        var status: SMAppService.Status
        var statusAfterRegister = SMAppService.Status.enabled
        var failure: Error?
        private(set) var calls: [String] = []

        init(_ status: SMAppService.Status) { self.status = status }
        func register() throws {
            calls.append("register")
            if let failure { throw failure }
            status = statusAfterRegister
        }
        func unregister() throws {
            calls.append("unregister")
            if let failure { throw failure }
            status = .notRegistered
        }
    }

    func testSwitchFollowsTheSystemRecordIncludingChangesMadeInSystemSettings() {
        let items = LoginItems(.notFound)
        let preference = LaunchAtLoginPreference(service: items)
        XCTAssertFalse(preference.enabled)
        items.status = .enabled
        XCTAssertFalse(preference.enabled, "The record is read, not pushed")
        preference.refresh()
        XCTAssertTrue(preference.enabled)
        XCTAssertFalse(preference.needsApproval)
        items.status = .requiresApproval
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(preference.enabled, "Returning to Pacer picks up a change made in System Settings")
        XCTAssertTrue(preference.needsApproval, "A registered item that macOS holds back stays on and explains why")
        XCTAssertEqual(items.calls, [], "Reading never registers or removes the item")
    }

    func testOnlyAnActualChangeReachesTheSystem() {
        let items = LoginItems(.notRegistered)
        let preference = LaunchAtLoginPreference(service: items)
        preference.setEnabled(true)
        XCTAssertTrue(preference.enabled)
        items.status = .notRegistered
        preference.setEnabled(false)
        XCTAssertFalse(preference.enabled, "Removed elsewhere meanwhile: nothing left to unregister")
        items.statusAfterRegister = .requiresApproval
        preference.setEnabled(true)
        preference.setEnabled(true)
        XCTAssertTrue(preference.needsApproval)
        preference.setEnabled(false)
        XCTAssertEqual(items.calls, ["register", "register", "unregister"])
        XCTAssertFalse(preference.enabled)
        XCTAssertFalse(preference.needsApproval)
    }

    func testFailedChangeKeepsTheSystemStateAndExplainsUntilTheNextChoice() {
        let items = LoginItems(.notRegistered)
        items.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let preference = LaunchAtLoginPreference(service: items)
        preference.setEnabled(true)
        XCTAssertFalse(preference.enabled)
        XCTAssertTrue(preference.failure?.contains("Operation not permitted") == true)
        preference.refresh()
        XCTAssertNotNil(preference.failure, "Rereading the record keeps the explanation")
        items.failure = nil
        preference.setEnabled(true)
        XCTAssertTrue(preference.enabled)
        XCTAssertNil(preference.failure)
    }

    func testDemoRecordNeverTouchesTheRealLoginItem() {
        let preference = LaunchAtLoginPreference(demo: true)
        XCTAssertFalse(preference.enabled)
        preference.setEnabled(true)
        XCTAssertTrue(preference.enabled)
        preference.setEnabled(false)
        XCTAssertFalse(preference.enabled)
    }
}
