import XCTest
@testable import PacerCore

final class IslandMotionTests: XCTestCase {
    private let folded = CGRect(x: 550, y: 768, width: 300, height: 32)
    private let open = CGRect(x: 480, y: 240, width: 440, height: 560)

    private func motion(opening: Bool, start: TimeInterval = 0) -> IslandMotion {
        IslandMotion(from: .resting(at: opening ? folded : open, expanded: !opening),
                     to: opening ? open : folded, opening: opening, start: start)
    }

    func testBothDimensionsMoveTogetherFromTheFirstFrame() {
        for opening in [true, false] {
            let motion = motion(opening: opening)
            for time in [1.0 / 120, 1.0 / 60, 0.08, 0.15, 0.25] {
                let sample = motion.sample(at: time)
                let widthProgress = (sample.frame.width - folded.width) / (open.width - folded.width)
                let heightProgress = (sample.frame.height - folded.height) / (open.height - folded.height)
                XCTAssertEqual(widthProgress, heightProgress, accuracy: 0.000001)
                XCTAssertEqual(heightProgress, sample.expansion, accuracy: 0.000001)
                XCTAssertGreaterThan(widthProgress, 0)
                XCTAssertLessThan(widthProgress, 1)
            }
        }
    }

    func testShellKeepsTopAndCenterAnchoredWithoutOvershoot() {
        for opening in [true, false] {
            let motion = motion(opening: opening)
            var previous = motion.sample(at: 0)
            for tick in 1...120 {
                let sample = motion.sample(at: Double(tick) / 120)
                XCTAssertEqual(sample.frame.maxY, folded.maxY, accuracy: 0.000001)
                XCTAssertEqual(sample.frame.midX, folded.midX, accuracy: 0.000001)
                XCTAssertTrue((folded.width...open.width).contains(sample.frame.width))
                XCTAssertTrue((folded.height...open.height).contains(sample.frame.height))
                XCTAssertTrue((0...1).contains(sample.content))
                if opening {
                    XCTAssertGreaterThanOrEqual(sample.frame.height, previous.frame.height)
                    XCTAssertGreaterThanOrEqual(sample.content, previous.content)
                } else {
                    XCTAssertLessThanOrEqual(sample.frame.height, previous.frame.height)
                    XCTAssertLessThanOrEqual(sample.content, previous.content)
                }
                previous = sample
            }
        }
    }

    func testRevealWaitsForSpaceButCollapseDoesNotLeaveAnEmptyShell() {
        let opening = motion(opening: true)
        XCTAssertEqual(opening.sample(at: 1.0 / 60).content, 0)
        XCTAssertGreaterThan(opening.sample(at: 0.1).content, 0.5)
        let closing = motion(opening: false)
        let middle = closing.sample(at: 0.06)
        XCTAssertLessThan(middle.frame.height, open.height)
        XCTAssertGreaterThan(middle.content, 0.3)
        XCTAssertLessThan(middle.content, 0.9)
        XCTAssertEqual(closing.sample(at: 0.2).content, 0)
    }

    func testReversalPreservesPositionRevealAndVelocity() {
        for opening in [true, false] {
            let current = motion(opening: opening).sample(at: 0.1)
            let reversed = IslandMotion(from: current, to: opening ? folded : open,
                                        opening: !opening, start: 0.1)
            let first = reversed.sample(at: 0.1)
            XCTAssertEqual(first.frame, current.frame)
            XCTAssertEqual(first.expansion, current.expansion)
            XCTAssertEqual(first.content, current.content)
            XCTAssertEqual(first.velocity.width, current.velocity.width)
            XCTAssertEqual(first.velocity.height, current.velocity.height)
            XCTAssertEqual(first.velocity.expansion, current.velocity.expansion)
            // A reversal decelerates through zero, rather than stopping at the
            // interruption. Check the actual curve derivative, not just metadata.
            let delta = 0.000001
            let next = reversed.sample(at: 0.1 + delta)
            XCTAssertEqual((next.frame.height - first.frame.height) / delta, current.velocity.height, accuracy: 0.2)
            XCTAssertEqual((next.expansion - first.expansion) / delta, current.velocity.expansion, accuracy: 0.001)
            XCTAssertEqual(reversed.sample(at: 2).frame, opening ? folded : open)
        }
    }

    func testRepeatedRapidTogglesStayBoundedAndEventuallySettle() {
        var current = IslandMotion.Sample.resting(at: folded, expanded: false)
        var time = 0.0
        for index in 0..<100 {
            let opening = index.isMultiple(of: 2)
            let motion = IslandMotion(from: current, to: opening ? open : folded, opening: opening, start: time)
            let interval = [0.016, 0.045, 0.08, 0.025][index % 4]
            for tick in 0...10 {
                let sample = motion.sample(at: time + interval * Double(tick) / 10)
                XCTAssertTrue((folded.width...open.width).contains(sample.frame.width))
                XCTAssertTrue((folded.height...open.height).contains(sample.frame.height))
                XCTAssertTrue((0...1).contains(sample.content))
                XCTAssertEqual(sample.frame.maxY, open.maxY, accuracy: 0.000001)
            }
            time += interval
            current = motion.sample(at: time)
        }
        let ending = IslandMotion(from: current, to: folded, opening: false, start: time).sample(at: time + 1)
        XCTAssertEqual(ending.frame, folded)
        XCTAssertEqual(ending.content, 0)
        XCTAssertTrue(ending.finished)
    }

    func testContentResizeRetainsRevealAndMomentum() {
        let current = motion(opening: true).sample(at: 0.15)
        let taller = CGRect(x: open.minX, y: open.minY - 64, width: open.width, height: open.height + 64)
        let resized = IslandMotion(from: current, to: taller, opening: true, start: 0.15)
        let first = resized.sample(at: 0.15)
        XCTAssertEqual(first.frame, current.frame)
        XCTAssertEqual(first.content, current.content)
        XCTAssertEqual(first.velocity.height, current.velocity.height)
        XCTAssertGreaterThan(resized.sample(at: 0.2).content, current.content)
        XCTAssertEqual(resized.sample(at: 2).frame, taller)
    }

    func testResizingAnOpenPanelDoesNotReplayReveal() {
        let taller = CGRect(x: open.minX, y: open.minY - 64, width: open.width, height: open.height + 64)
        let motion = IslandMotion(from: .resting(at: open, expanded: true), to: taller, opening: true, start: 0)
        for tick in 0...60 {
            let sample = motion.sample(at: Double(tick) / 60)
            XCTAssertEqual(sample.content, 1)
            XCTAssertEqual(sample.expansion, 1)
            XCTAssertEqual(sample.frame.maxY, open.maxY, accuracy: 0.000001)
        }
    }

    func testLandingSettlesAtSubpixelDistanceAndVelocity() {
        for opening in [true, false] {
            let motion = motion(opening: opening)
            var previous = motion.sample(at: 0)
            var settled = false
            for tick in 1...120 {
                let sample = motion.sample(at: Double(tick) / 120)
                if sample.finished {
                    XCTAssertLessThan(abs(previous.frame.height - sample.frame.height), 0.1)
                    XCTAssertLessThan(abs(previous.velocity.height), 1)
                    XCTAssertEqual(sample.velocity.height, 0)
                    XCTAssertEqual(sample.frame, opening ? open : folded)
                    settled = true
                    break
                }
                previous = sample
            }
            XCTAssertTrue(settled)
        }
    }

    func testDroppedFramesAndLongPauseStillReachExactDestination() {
        for opening in [true, false] {
            let motion = motion(opening: opening, start: 10)
            XCTAssertEqual(motion.sample(at: 9).frame, opening ? folded : open)
            for time in [10.016, 10.12, 10.3, 10.75] {
                let sample = motion.sample(at: time)
                XCTAssertTrue(sample.frame.height.isFinite)
                XCTAssertTrue((0...1).contains(sample.content))
            }
            let end = motion.sample(at: 300)
            XCTAssertEqual(end.frame, opening ? open : folded)
            XCTAssertEqual(end.expansion, opening ? 1 : 0)
            XCTAssertEqual(end.content, opening ? 1 : 0)
            XCTAssertTrue(end.finished)
        }
    }
}
