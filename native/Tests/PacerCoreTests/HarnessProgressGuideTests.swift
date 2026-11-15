import XCTest
@testable import PacerCore

final class HarnessProgressGuideTests: XCTestCase {
    private func guide(_ setup: LocalHarnessProgressStatus?, _ connection: LocalHarnessProgressConnection? = nil,
                       reported: Bool = false, ringOn: Bool = true) -> HarnessProgressGuide? {
        HarnessProgressGuide(setup: setup, connection: connection, reported: reported, ringOn: ringOn, name: "WorkBuddy AI", language: .english)
    }

    func testTrustingInTheAppIsTheOneStepLeft() throws {
        let trust = try XCTUnwrap(guide(.configured, .needsTrust))
        XCTAssertEqual(trust.stage, .trust)
        XCTAssertEqual(trust.chip, "1 step left")
        XCTAssertEqual(trust.steps.map(\.state), [.done, .current, .pending])
        XCTAssertEqual(trust.steps[1].title, "Trust pacer_progress in WorkBuddy AI", "Each module names its own app")
        XCTAssertEqual(trust.action, .openConnectors)
        XCTAssertEqual(trust.actionTitle, "Open WorkBuddy AI Connectors")
        XCTAssertTrue(trust.attention && trust.waiting && trust.showsTrustCard)
        XCTAssertNil(trust.line, "Steps carry the state; the explanation stays behind ⓘ")
        XCTAssertTrue(trust.info.contains("Refresh"))

        let again = try XCTUnwrap(guide(.configured, .retrust))
        XCTAssertEqual(again.chip, "Trust again")
        XCTAssertEqual(again.steps[1].title, "Trust pacer_progress in WorkBuddy AI again")
        XCTAssertEqual(again.summary, "Progress ring: trust again")
    }

    func testTheFirstReportCollapsesTheCard() throws {
        let trusted = try XCTUnwrap(guide(.configured, .trusted))
        XCTAssertEqual(trusted.stage, .firstTask)
        XCTAssertEqual(trusted.steps.map(\.state), [.done, .done, .current])
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
        XCTAssertEqual(guide(.settingUp)?.steps.map(\.state), [.current, .pending, .pending])
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
                       "WorkBuddy also needs one Trust in its connectors.")
        XCTAssertEqual(HarnessProgressGuide.onboardingNote(names: ["WorkBuddy", "WorkBuddy AI"], language: .simplifiedChinese),
                       "WorkBuddy 和 WorkBuddy AI 还要各自在连接器里点一次「信任」。")
    }
}
