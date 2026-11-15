import XCTest
@testable import PacerCore

final class HarnessProgressGuideTests: XCTestCase {
    private let added = Date(timeIntervalSince1970: 1_800_000_000)
    private func guide(_ setup: LocalHarnessProgressStatus?, _ connection: LocalHarnessProgressConnection? = nil,
                       reported: Bool = false, ringOn: Bool = true, app: HarnessProgressGuide.AppPresence? = nil) -> HarnessProgressGuide? {
        HarnessProgressGuide(setup: setup, connection: connection, reported: reported, ringOn: ringOn, name: "WorkBuddy AI",
                             addedAt: added, app: app, language: .english)
    }

    func testAnAppRunningSinceBeforeTheToolMustBeReopenedFirst() throws {
        // The app reads its MCP file only at start, so it can't list a tool added after.
        let reopen = try XCTUnwrap(guide(.configured, .needsTrust, app: .running(since: added.addingTimeInterval(-600))))
        XCTAssertEqual(reopen.stage, .reopen)
        XCTAssertEqual(reopen.steps.map(\.state), [.done, .current, .pending, .pending])
        XCTAssertEqual(reopen.steps[1].title, "Quit WorkBuddy AI completely, then reopen it")
        XCTAssertEqual(reopen.chip, "2 steps left")
        XCTAssertNil(reopen.action, "Only the user quits the app; Pacer sees it start again")
        XCTAssertTrue(reopen.waiting && reopen.attention)
        XCTAssertEqual(reopen.waitingText, "Waiting for WorkBuddy AI to start again")
        XCTAssertFalse(reopen.showsTrustCard, "The trust card would show a tool the app can't list yet")

        let closed = try XCTUnwrap(guide(.configured, .needsTrust, app: .notRunning))
        XCTAssertEqual(closed.stage, .launch)
        XCTAssertEqual(closed.steps[1].title, "Open WorkBuddy AI")
        XCTAssertEqual(closed.action, .openConnectors, "Opening the connectors starts the app, which then lists the tool")

        let reopened = try XCTUnwrap(guide(.configured, .needsTrust, app: .running(since: added.addingTimeInterval(5))))
        XCTAssertEqual(reopened.stage, .trust)
        XCTAssertEqual(reopened.steps.map(\.state), [.done, .done, .current, .pending])
        XCTAssertEqual(reopened.steps[1].title, "WorkBuddy AI has loaded the tool")
        XCTAssertEqual(guide(.configured, .needsTrust)?.stage, .trust, "A host that can't tell keeps the trust step")
    }

    func testTrustingInTheAppIsTheLastStepLeft() throws {
        let trust = try XCTUnwrap(guide(.configured, .needsTrust, app: .running(since: added.addingTimeInterval(60))))
        XCTAssertEqual(trust.chip, "1 step left")
        XCTAssertEqual(trust.steps[2].title, "In WorkBuddy AI, click Custom Connector, then Trust next to pacer_progress",
                       "WorkBuddy has no link to its custom connectors, so the step names that click; each module names its own app")
        XCTAssertEqual(trust.action, .openConnectors)
        XCTAssertEqual(trust.actionTitle, "Open WorkBuddy AI Connectors")
        XCTAssertTrue(trust.attention && trust.waiting && trust.showsTrustCard)
        XCTAssertNil(trust.line, "Steps carry the state; the explanation stays behind ⓘ")
        XCTAssertTrue(trust.info.contains("reopened") && !trust.info.contains("Refresh"))

        let again = try XCTUnwrap(guide(.configured, .retrust))
        XCTAssertEqual(again.chip, "Trust again")
        XCTAssertEqual(again.steps[2].title, "In WorkBuddy AI, click Custom Connector, then Trust next to pacer_progress again")
        XCTAssertEqual(again.summary, "Progress ring: trust again")
        XCTAssertEqual(guide(.configured, .retrust, app: .running(since: added.addingTimeInterval(-60)))?.chip, "Trust again",
                       "After an update, the app may need reopening too, but the chip says why")
    }

    func testTheFirstReportCollapsesTheCard() throws {
        let trusted = try XCTUnwrap(guide(.configured, .trusted))
        XCTAssertEqual(trusted.stage, .firstTask)
        XCTAssertEqual(trusted.steps.map(\.state), [.done, .done, .done, .current])
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
        XCTAssertEqual(guide(.settingUp)?.steps.map(\.state), [.current, .pending, .pending, .pending])
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
