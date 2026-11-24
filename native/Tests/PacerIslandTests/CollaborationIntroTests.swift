import XCTest
@testable import PacerCore
@testable import PacerIsland

/// Settings → Collaboration's first-run guide: which steps tick, and what its
/// demo shows at each moment. Synthetic choices only.
final class CollaborationIntroTests: XCTestCase {
    func testStepsTickFromTheChoicesAndWhatTheLedgerShowed() {
        var preferences = CodexDelegationPreferences()
        var state = CollaborationIntroState(preferences: preferences, blocked: false)
        XCTAssertEqual(state, .init())
        XCTAssertEqual(state.current, 0, "Turning the pair on comes first")

        preferences.enabled = true
        XCTAssertFalse(CollaborationIntroState(preferences: preferences, blocked: true).on, "Something keeping the pair from working leaves step 1 open")
        state = .init(preferences: preferences, blocked: false)
        XCTAssertTrue(state.on); XCTAssertEqual(state.current, 1)

        preferences.introFinished = true
        state = .init(preferences: preferences, blocked: false)
        XCTAssertTrue(state.ran, "A run that ended was also a run")
        XCTAssertTrue(state.allDone); XCTAssertNil(state.current)

        preferences.trigger = .command
        XCTAssertTrue(CollaborationIntroState(preferences: preferences, blocked: false).commandOnly)
    }

    func testTheDemoShowsEachStepAtItsMoment() {
        typealias Frame = CollaborationDemo.Frame
        XCTAssertEqual(CollaborationDemo.starts.count, 5)
        XCTAssertEqual(CollaborationDemo.stills.enumerated().map { Frame(t: $0.element, moving: false).beat }, [0, 1, 2, 3, 4],
                       "Each still frame belongs to its own step")
        for (index, start) in CollaborationDemo.starts.enumerated() {
            XCTAssertEqual(Frame(t: start, moving: true).beat, index)
        }
        XCTAssertLessThan(CollaborationDemo.starts.last!, CollaborationDemo.loop)

        // The ask types in, then sends.
        let prompt = "0123456789"
        XCTAssertEqual(Frame(t: 0.9, moving: true).typed(prompt), "01234")
        XCTAssertFalse(Frame(t: 1.5, moving: true).sent)
        XCTAssertTrue(Frame(t: 2.0, moving: true).sent)
        XCTAssertEqual(Frame(t: 3.0, moving: true).typed(prompt), prompt)

        // The run starts dashed with no readings, fills, then holds its time.
        XCTAssertEqual(Frame(t: 2.8, moving: false).readings, "— t/s · 0:00")
        XCTAssertEqual(Frame(t: 5.4, moving: false).fraction, 0.5, accuracy: 0.0001)
        XCTAssertTrue(Frame(t: 5.4, moving: false).readings.hasSuffix(" t/s · 0:40"))
        XCTAssertEqual(Frame(t: 7.3, moving: false).readings, "74 t/s · 1:20")
        XCTAssertEqual(Frame(t: 7.3, moving: false).status, "collab.intro.demo.replying")

        // The run's line shows from step 2 to 4, then gives way to the cleanup.
        XCTAssertEqual(Frame(t: 2.2, moving: false).runOpacity, 0)
        XCTAssertEqual(Frame(t: 2.2, moving: false).runOffset, 6)
        XCTAssertEqual(Frame(t: 2.4, moving: true).runOpacity, 0, "It fades in as it starts")
        XCTAssertEqual(Frame(t: 2.85, moving: true).runOpacity, 1)
        XCTAssertEqual(Frame(t: 2.85, moving: true).runOffset, 0)
        XCTAssertEqual(Frame(t: 9.8, moving: false).runOpacity, 0)
        XCTAssertEqual(Frame(t: 9.8, moving: false).cleanedOpacity, 1)
        XCTAssertEqual(Frame(t: 8.7, moving: true).cleanedOpacity, 0, "The cleanup follows a quarter second later")
        XCTAssertEqual(Frame(t: 9.8, moving: false).status, "collab.intro.demo.finished")
    }
}
