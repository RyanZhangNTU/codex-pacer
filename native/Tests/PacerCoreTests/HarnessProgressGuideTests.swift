import XCTest
@testable import PacerCore

final class HarnessProgressGuideTests: XCTestCase {
    private let added = Date(timeIntervalSince1970: 1_800_000_000)
    private var loaded: HarnessProgressGuide.AppPresence { .running(since: added.addingTimeInterval(60)) }
    private func guide(_ setup: LocalHarnessProgressStatus?, _ connection: LocalHarnessProgressConnection? = nil,
                       reported: Bool = false, ringOn: Bool = true, app: HarnessProgressGuide.AppPresence? = nil,
                       view: HarnessProgressGuide.AppView? = nil, opened: Bool = false) -> HarnessProgressGuide? {
        HarnessProgressGuide(setup: setup, connection: connection, reported: reported, ringOn: ringOn, name: "WorkBuddy AI",
                             addedAt: added, app: app, view: view, openedConnectors: opened, language: .english)
    }

    func testAnAppRunningSinceBeforeTheToolMustBeReopenedFirst() throws {
        // The app reads its MCP file only at start, so it can't list a tool added after.
        let reopen = try XCTUnwrap(guide(.configured, .needsTrust, app: .running(since: added.addingTimeInterval(-600))))
        XCTAssertEqual(reopen.stage, .reopen)
        XCTAssertEqual(reopen.steps.map(\.state), [.done, .current, .pending, .pending, .pending, .pending])
        XCTAssertEqual(reopen.steps[1].title, "Quit WorkBuddy AI completely, then reopen it")
        XCTAssertEqual(reopen.chip, "4 steps left")
        XCTAssertNil(reopen.action, "Only the user quits the app; Pacer sees it start again")
        XCTAssertEqual(reopen.waitingText, "Waiting for WorkBuddy AI to start again")
        XCTAssertNil(reopen.picture)

        let closed = try XCTUnwrap(guide(.configured, .needsTrust, app: .notRunning))
        XCTAssertEqual(closed.stage, .launch)
        XCTAssertEqual(closed.steps[1].title, "Open WorkBuddy AI")
        XCTAssertEqual(closed.action, .openConnectors, "Opening the connectors starts the app, which then lists the tool")
    }

    func testEachClickInTheAppIsItsOwnStep() throws {
        let open = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded))
        XCTAssertEqual(open.stage, .openConnectors)
        XCTAssertEqual(open.steps.map(\.state), [.done, .done, .current, .pending, .pending, .pending])
        XCTAssertEqual(open.steps[1].title, "WorkBuddy AI has loaded the tool")
        XCTAssertEqual(open.chip, "3 steps left")
        XCTAssertEqual(open.action, .openConnectors)

        // Pacer reaches the connector market; no link reaches the custom connectors.
        let custom = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded, opened: true))
        XCTAssertEqual(custom.stage, .customConnector)
        XCTAssertEqual(custom.steps[3].title, "Click Custom Connector at the top right")
        XCTAssertEqual(custom.steps.map(\.state), [.done, .done, .done, .current, .pending, .pending])
        XCTAssertEqual(custom.action, .point)
        XCTAssertEqual(custom.actionTitle, "Show Me in WorkBuddy AI")
        XCTAssertEqual(custom.picture, .customConnector)
        XCTAssertEqual(custom.pointerText, "Click here for Custom Connector")
        XCTAssertEqual(guide(.configured, .needsTrust, app: loaded, view: .connectors)?.stage, .customConnector,
                       "A host that sees the connectors page skips the open step")

        let trust = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded, view: .customConnectors))
        XCTAssertEqual(trust.stage, .trust)
        XCTAssertEqual(trust.steps[4].title, "Click Trust on pacer_progress")
        XCTAssertEqual(trust.chip, "1 step left")
        XCTAssertEqual(trust.picture, .trust)
        XCTAssertEqual(trust.action, .point)
        XCTAssertTrue(trust.attention && trust.waiting)
        XCTAssertNil(trust.line, "Steps carry the state; the explanation stays behind ⓘ")
        XCTAssertTrue(trust.info.contains("Custom Connector") && !trust.info.contains("Refresh"))

        let again = try XCTUnwrap(guide(.configured, .retrust, app: loaded, view: .customConnectors))
        XCTAssertEqual(again.chip, "Trust again")
        XCTAssertEqual(again.steps[4].title, "Click Trust on pacer_progress again")
        XCTAssertEqual(again.summary, "Progress ring: trust again")
    }

    func testTheFirstReportCollapsesTheCard() throws {
        let trusted = try XCTUnwrap(guide(.configured, .trusted))
        XCTAssertEqual(trusted.stage, .firstTask)
        XCTAssertEqual(trusted.steps.map(\.state), [.done, .done, .done, .done, .done, .current])
        XCTAssertEqual(trusted.steps[4].title, "WorkBuddy AI trusts pacer_progress")
        XCTAssertFalse(trusted.attention, "Starting a task is not a chore to flag")
        let ready = try XCTUnwrap(guide(.configured, .trusted, reported: true))
        XCTAssertEqual(ready.stage, .ready)
        XCTAssertEqual(ready.chip, "Ready")
        XCTAssertTrue(ready.steps.isEmpty)
        XCTAssertNil(ready.action)
        XCTAssertEqual(guide(.configured, .unknown, reported: true)?.stage, .ready, "Reports prove the tool works even when its status can't be read")
    }

    func testProblemsSayWhatToDoInOneLine() throws {
        let off = try XCTUnwrap(guide(.configured, .disabled))
        XCTAssertEqual(off.chip, "Off in WorkBuddy AI")
        XCTAssertEqual(off.line, "Turn pacer_progress back on in WorkBuddy AI.")
        XCTAssertEqual(off.action, .openConnectors)
        XCTAssertEqual(guide(.configured, .toolDisabled)?.line, "Turn the report_progress tool back on in WorkBuddy AI.")
        let open = try XCTUnwrap(guide(.missingHome))
        XCTAssertEqual(open.action, .openApp)
        XCTAssertTrue(open.waiting, "Setup continues by itself once the app has made its folder")
        for setup in [LocalHarnessProgressStatus.conflict, .failed] {
            let failed = try XCTUnwrap(guide(setup))
            XCTAssertEqual(failed.tone, .error)
            XCTAssertEqual(failed.action, .retry)
            XCTAssertTrue(failed.attention)
        }
        XCTAssertEqual(guide(.settingUp)?.steps.map(\.state), [.current, .pending, .pending, .pending, .pending, .pending])
    }

    func testARingThatIsOffShowsNothingUnlessCleanupFailed() {
        XCTAssertNil(guide(.configured, .needsTrust, ringOn: false))
        XCTAssertNil(guide(nil))
        XCTAssertEqual(guide(.failed, ringOn: false)?.stage, .cleanupFailed)
        XCTAssertEqual(guide(.failed, ringOn: false)?.attention, false)
    }

    func testOnboardingNamesEveryAppThatStillNeedsAStep() {
        XCTAssertNil(HarnessProgressGuide.onboardingNote(names: [], language: .english))
        XCTAssertEqual(HarnessProgressGuide.onboardingNote(names: ["WorkBuddy"], language: .english),
                       "WorkBuddy needs a few steps before its ring shows.")
        XCTAssertEqual(HarnessProgressGuide.onboardingNote(names: ["WorkBuddy", "WorkBuddy AI"], language: .simplifiedChinese),
                       "WorkBuddy 和 WorkBuddy AI 还要各自完成几步，圆环才会出现。")
    }
}
