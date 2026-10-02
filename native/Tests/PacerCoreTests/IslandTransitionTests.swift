import XCTest
@testable import PacerCore

final class IslandTransitionTests: XCTestCase {
    private let folded = CGRect(x: 652, y: 1085, width: 424, height: 32)
    private let open = CGRect(x: 644, y: 535, width: 440, height: 582)

    func testNotchBackingClearsBeforeTheShellStartsOpening() {
        var transition = IslandTransition(from: .resting(at: folded, expanded: false, hasBlackHeader: true),
                                          to: open, opening: true, hasBlackHeader: true, start: 0)
        var opacity = 1.0
        for time in [0.0, 0.025, 0.05, 0.075, 0.099] {
            let sample = transition.sample(at: time)
            XCTAssertEqual(sample.frame, folded)
            XCTAssertEqual(sample.expansion, 0)
            XCTAssertEqual(sample.content, 0)
            XCTAssertGreaterThan(sample.blackOpacity, 0)
            XCTAssertLessThanOrEqual(sample.blackOpacity, opacity)
            XCTAssertFalse(sample.finished)
            opacity = sample.blackOpacity
        }
        let moving = transition.sample(at: 0.12)
        XCTAssertEqual(moving.blackOpacity, 0)
        XCTAssertGreaterThan(moving.frame.height, folded.height)
        let end = transition.sample(at: 2)
        XCTAssertTrue(end.finished)
        XCTAssertEqual(end.frame, open)
        XCTAssertEqual(end.blackOpacity, 0)
    }

    func testNotchBackingAppearsOnlyAfterTheVisibleWindowHasFolded() {
        for refreshRate in [30.0, 60.0, 120.0] {
            var transition = IslandTransition(from: .resting(at: open, expanded: true, hasBlackHeader: true),
                                              to: folded, opening: false, hasBlackHeader: true, start: 0)
            var reachedFoldedAt: Double?
            var firstBlackAt: Double?
            var opacity = 0.0
            var sawPartialFade = false
            var finished = false
            for tick in 0...Int(refreshRate * 2) {
                let time = Double(tick) / refreshRate
                let sample = transition.sample(at: time)
                let window = IslandGeometry.windowFrame(sample.frame)
                if window == folded, reachedFoldedAt == nil { reachedFoldedAt = time }
                if window != folded { XCTAssertEqual(sample.blackOpacity, 0) }
                if sample.blackOpacity > 0 {
                    XCTAssertEqual(window, folded)
                    XCTAssertEqual(sample.content, 0)
                    if firstBlackAt == nil { firstBlackAt = time }
                }
                if sample.blackOpacity > 0 && sample.blackOpacity < 1 {
                    sawPartialFade = true
                    XCTAssertFalse(sample.finished)
                }
                XCTAssertGreaterThanOrEqual(sample.blackOpacity, opacity)
                opacity = sample.blackOpacity
                if sample.finished {
                    XCTAssertEqual(sample.blackOpacity, 1)
                    XCTAssertEqual(window, folded)
                    finished = true
                    break
                }
            }
            XCTAssertTrue(finished)
            XCTAssertTrue(sawPartialFade)
            if let reachedFoldedAt, let firstBlackAt {
                XCTAssertLessThanOrEqual(firstBlackAt - reachedFoldedAt, 2 / refreshRate)
            } else { XCTFail("Missing the folded window or the backing fade") }
        }
    }

    func testClosingJustAfterTheOpeningFadeDoesNotStopBeforeBlackReturns() {
        var opening = IslandTransition(from: .resting(at: folded, expanded: false, hasBlackHeader: true),
                                       to: open, opening: true, hasBlackHeader: true, start: 0)
        let clear = opening.sample(at: 0.1)
        XCTAssertEqual(clear.frame, folded)
        XCTAssertEqual(clear.blackOpacity, 0)
        var closing = IslandTransition(from: clear, to: folded, opening: false, hasBlackHeader: true, start: 0.1)
        let fade = closing.sample(at: 0.15)
        XCTAssertTrue(fade.geometry.finished)
        XCTAssertGreaterThan(fade.blackOpacity, 0)
        XCTAssertLessThan(fade.blackOpacity, 1)
        XCTAssertFalse(fade.finished)
        XCTAssertTrue(closing.sample(at: 0.3).finished)
    }

    func testReversingTheBackingFadeKeepsTheCurrentOpacityAndSize() {
        var opening = IslandTransition(from: .resting(at: folded, expanded: false, hasBlackHeader: true),
                                       to: open, opening: true, hasBlackHeader: true, start: 0)
        let current = opening.sample(at: 0.04)
        var closing = IslandTransition(from: current, to: folded, opening: false, hasBlackHeader: true, start: 0.04)
        let reversed = closing.sample(at: 0.04)
        XCTAssertEqual(reversed.blackOpacity, current.blackOpacity)
        XCTAssertEqual(reversed.frame, current.frame)
        let darkening = closing.sample(at: 0.08)
        XCTAssertGreaterThan(darkening.blackOpacity, current.blackOpacity)
        XCTAssertEqual(darkening.frame, folded)
        var reopened = IslandTransition(from: darkening, to: open, opening: true, hasBlackHeader: true, start: 0.08)
        XCTAssertEqual(reopened.sample(at: 0.08).blackOpacity, darkening.blackOpacity)
        let fading = reopened.sample(at: 0.12)
        XCTAssertLessThan(fading.blackOpacity, darkening.blackOpacity)
        XCTAssertEqual(fading.frame, folded)
        XCTAssertEqual(reopened.sample(at: 2).frame, open)
    }

    func testReversingMovingGeometryPreservesVelocityWithoutASecondFade() {
        var closing = IslandTransition(from: .resting(at: open, expanded: true, hasBlackHeader: true),
                                       to: folded, opening: false, hasBlackHeader: true, start: 0)
        let current = closing.sample(at: 0.1)
        XCTAssertEqual(current.blackOpacity, 0)
        var opening = IslandTransition(from: current, to: open, opening: true, hasBlackHeader: true, start: 0.1)
        let first = opening.sample(at: 0.1)
        XCTAssertEqual(first.frame, current.frame)
        XCTAssertEqual(first.geometry.velocity.height, current.geometry.velocity.height)
        let next = opening.sample(at: 0.100001)
        XCTAssertEqual((next.frame.height - current.frame.height) / 0.000001,
                       current.geometry.velocity.height, accuracy: 0.2)
        XCTAssertEqual(next.blackOpacity, 0)
        XCTAssertNotEqual(next.frame, first.frame)
    }

    func testFloatingAndClassicModesKeepTheirImmediateSpring() {
        for opening in [true, false] {
            let initial = IslandTransition.Sample.resting(at: opening ? folded : open,
                                                         expanded: !opening, hasBlackHeader: false)
            var transition = IslandTransition(from: initial, to: opening ? open : folded,
                                              opening: opening, hasBlackHeader: false, start: 0)
            let spring = IslandMotion(from: initial.geometry, to: opening ? open : folded, opening: opening, start: 0)
            for time in [0.0, 1.0 / 120, 0.1, 0.3, 1] {
                let sample = transition.sample(at: time)
                XCTAssertEqual(sample.frame, spring.sample(at: time).frame)
                XCTAssertEqual(sample.finished, spring.sample(at: time).finished)
                XCTAssertEqual(sample.blackOpacity, 0)
            }
        }
    }

    func testAnExpandedContentResizeDoesNotReplayTheBlackBacking() {
        let taller = CGRect(x: open.minX, y: open.minY - 64, width: open.width, height: open.height + 64)
        var transition = IslandTransition(from: .resting(at: open, expanded: true, hasBlackHeader: true),
                                          to: taller, opening: true, hasBlackHeader: true, start: 0)
        for tick in 0...120 {
            let sample = transition.sample(at: Double(tick) / 120)
            XCTAssertEqual(sample.blackOpacity, 0)
            XCTAssertEqual(sample.content, 1)
        }
        XCTAssertTrue(transition.sample(at: 2).finished)
    }
}
