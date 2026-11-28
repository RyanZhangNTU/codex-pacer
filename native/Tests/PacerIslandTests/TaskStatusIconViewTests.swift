import AppKit
import XCTest
@testable import PacerCore
@testable import PacerIsland

/// The task row's status icon: ring continuity across rebuilt rows, looping
/// motion by mode, faces and their one-time arrivals, the glyph art, the
/// badge's estimate, and no clocks without motion.
@MainActor
final class TaskStatusIconViewTests: XCTestCase {
    private typealias Ring = TaskStatusIconNSView
    private let ink = NSColor.orange.cgColor
    private let loops: Set<String> = ["pending.spin", "pending.breath", "arc.breath", "flow.travel", "step.breath", "glyph.rhythm"]
    /// Whether the test windows count as on screen and unoccluded.
    private var shows = true
    private var windows: [NSWindow] = []
    private func shown() -> Ring {
        if windows.isEmpty {
            let original = Ring.windowShows
            Ring.windowShows = { [unowned self] _ in MainActor.assumeIsolated { self.shows } }
            addTeardownBlock { @MainActor in Ring.windowShows = original }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = Ring(frame: NSRect(x: 6, y: 6, width: Ring.diameter, height: Ring.diameter))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return view
    }
    private func input(_ id: String, _ state: TaskProgressRing.State?, _ mode: TaskProgressRing.Mode = .working,
                       _ fraction: Double = 0, stale: Bool = false, animates: Bool = true, codex: Bool = false) -> Ring.Input {
        .init(id: id, state: state, mode: mode, fraction: fraction, stale: stale, color: ink, animates: animates,
              completionPulseOnly: codex)
    }
    private func running(_ view: Ring) -> Set<String> { view.animationKeys.intersection(loops) }

    func testARowAppliesItsRingOnlyOnceShownAndRebuildsContinueTheSweepInEitherRemovalOrder() throws {
        let id = UUID().uuidString
        let detached = Ring(frame: NSRect(x: 0, y: 0, width: Ring.diameter, height: Ring.diameter))
        detached.update(input(id, .reported, .working, 0.3))
        XCTAssertNil(Ring.memory(for: id), "A row resumes motion only once it is in a window")

        for removeFirst in [false, true] {
            let id = UUID().uuidString, first = shown()
            first.update(input(id, .reported, .working, 0.3))
            XCTAssertEqual(Ring.memory(for: id)?.duration, 0, "A ring that appears with an estimate draws it at once")
            XCTAssertEqual(first.restingFraction, 0.3, accuracy: 0.0001)
            first.update(input(id, .reported, .working, 0.62))
            let sweep = try XCTUnwrap(Ring.memory(for: id)), firstBegin = try XCTUnwrap(first.sweepBegin())
            XCTAssertEqual(sweep.from, 0.3, accuracy: 0.0001); XCTAssertEqual(sweep.to, 0.62, accuracy: 0.0001)
            XCTAssertEqual(sweep.duration, 0.3 + 0.3 * 0.32, accuracy: 0.0001)

            if removeFirst { first.removeFromSuperview() }
            let second = shown()
            second.update(input(id, .reported, .working, 0.62))
            if !removeFirst { first.removeFromSuperview() }
            let resumed = try XCTUnwrap(Ring.memory(for: id))
            XCTAssertEqual(resumed.start, sweep.start, "Removing the previous row must preserve the sweep's clock")
            XCTAssertEqual(resumed.duration, sweep.duration)
            XCTAssertEqual(try XCTUnwrap(second.sweepBegin()), firstBegin, accuracy: 0.0001)
            XCTAssertTrue(first.animationKeys.isEmpty, "A removed row stops all its own animation")

            let before = CACurrentMediaTime()
            second.update(input(id, .reported, .working, 0.1))
            let after = CACurrentMediaTime(), falling = try XCTUnwrap(Ring.memory(for: id))
            XCTAssertGreaterThanOrEqual(falling.from, sweep.displayed(at: before) - 0.0001)
            XCTAssertLessThanOrEqual(falling.from, sweep.displayed(at: after) + 0.0001,
                "The next estimate starts from the displayed value rather than the previous target")
        }
    }

    func testALoweredEstimateStartsFromTheDisplayedValueAndLeavesATrace() throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .reported, .working, 0.3))
        view.update(input(id, .reported, .working, 0.9))
        view.update(input(id, .reported, .working, 0.1))
        let memory = try XCTUnwrap(Ring.memory(for: id))
        XCTAssertGreaterThanOrEqual(memory.from, 0.3); XCTAssertLessThanOrEqual(memory.from, 0.9)
        XCTAssertEqual(memory.to, 0.1, accuracy: 0.0001)
        XCTAssertEqual(memory.ease, .sineInOut); XCTAssertEqual(memory.duration, 0.5, accuracy: 0.0001)
        XCTAssertTrue(view.animationKeys.contains("ghost.opacity"))
    }

    func testOccludingAnOldRowCannotSettleItsVisibleSuccessor() throws {
        let id = UUID().uuidString, first = shown()
        first.update(input(id, .reported, .working, 0.3))
        first.update(input(id, .reported, .working, 0.8))
        let second = shown()
        second.update(input(id, .reported, .working, 0.8))
        let sweep = try XCTUnwrap(Ring.memory(for: id))
        shows = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first.window)
        shows = true
        XCTAssertTrue(first.animationKeys.isEmpty)
        XCTAssertTrue(second.animationKeys.contains("arc.sweep"))
        XCTAssertEqual(Ring.memory(for: id)?.start, sweep.start)
        XCTAssertEqual(Ring.memory(for: id)?.duration, sweep.duration)
    }

    func testRememberedSweepsDoNotRetainRemovedRows() {
        let id = UUID().uuidString
        weak var removed: Ring?
        autoreleasepool {
            let view = shown()
            view.update(input(id, .reported, .working, 0.3))
            view.update(input(id, .reported, .working, 0.8))
            removed = view
            view.removeFromSuperview()
        }
        XCTAssertNil(removed)
        XCTAssertNotNil(Ring.memory(for: id), "The next row can still resume the sweep after its owner is released")
    }

    func testLoopingMotionFollowsTheLifecycleMode() {
        let cases: [(TaskProgressRing.State, TaskProgressRing.Mode, Double, Bool, Set<String>)] = [
            (.pending, .working, 0, false, ["pending.spin"]),
            (.pending, .longStep, 0, false, ["pending.spin"]),
            (.pending, .attention, 0, false, []),
            (.pending, .waiting, 0, false, ["pending.breath"]),
            (.reported, .working, 0.5, false, ["flow.travel"]),
            (.reported, .working, 0.5, true, []),
            (.reported, .longStep, 0.5, false, ["step.breath"]),
            (.reported, .waiting, 0.5, false, ["arc.breath"]),
            (.reported, .attention, 0.5, false, []),
            (.reported, .done, 1, false, []),
            (.reported, .interrupted, 0.4, false, []),
            // A paused or limited Codex goal keeps still with or without an estimate.
            (.pending, .paused, 0, false, []),
            (.reported, .paused, 0.5, false, []),
        ]
        for (state, mode, fraction, stale, expected) in cases {
            let view = shown()
            view.update(input(UUID().uuidString, state, mode, fraction, stale: stale))
            XCTAssertEqual(running(view), expected, "\(state) \(mode) stale: \(stale)")
        }
        // One row moving through a request swaps its loops without leaving any behind.
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        view.update(input(id, .pending, .waiting))
        XCTAssertEqual(running(view), ["pending.breath"])
        view.update(input(id, .reported, .working, 0.4))
        XCTAssertEqual(running(view), ["flow.travel"])
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["pending.opacity", "track.opacity", "arc.sweep"]),
            "The comet closes into the track before the first estimate sweeps in")
        view.update(input(id, .reported, .done, 1))
        XCTAssertEqual(running(view), [])
        XCTAssertTrue(view.animationKeys.contains("icon.pulse"), "Reaching 100% settles with one pulse")
    }

    /// Codex pulses only on a confirmed ending: a working 100% fills the arc
    /// quietly, and neither a rebuilt row nor a first sight replays it.
    func testCodexPulsesOnceWhenTheRequestEndsRatherThanWhenItReportsFull() throws {
        let pulse = "icon.pulse"
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .reported, .working, 0.4, codex: true))
        view.update(input(id, .reported, .working, 1, codex: true))
        XCTAssertEqual(view.restingFraction, 1, accuracy: 0.0001)
        XCTAssertFalse(view.animationKeys.contains(pulse), "A working estimate of 100% is not an ending")
        view.update(input(id, .reported, .done, 1, codex: true))
        XCTAssertTrue(view.animationKeys.contains(pulse), "The confirmed ending pulses even after a full estimate")
        let rebuilt = shown()
        view.removeFromSuperview()
        rebuilt.update(input(id, .reported, .done, 1, codex: true))
        XCTAssertFalse(rebuilt.animationKeys.contains(pulse), "A rebuilt row of the same ending stays still")

        // The next request in the same chat drops a pulse that has yet to play.
        let next = UUID().uuidString, row = shown()
        row.update(input(next, .reported, .working, 0.8, codex: true))
        row.update(input(next, .reported, .done, 1, codex: true))
        XCTAssertTrue(row.animationKeys.contains(pulse))
        row.update(input(next, .pending, .working, codex: true))
        XCTAssertFalse(row.animationKeys.contains(pulse))
        row.update(input(next, .reported, .done, 1, codex: true))
        XCTAssertTrue(row.animationKeys.contains(pulse), "Each request's ending pulses once")

        // A request that never reported closes its comet, fills and pulses.
        let unreported = UUID().uuidString, dashed = shown()
        dashed.update(input(unreported, .pending, .working, codex: true))
        dashed.update(input(unreported, .reported, .done, 1, codex: true))
        XCTAssertTrue(dashed.animationKeys.isSuperset(of: ["pending.opacity", "arc.sweep", pulse]))

        let seen = shown()
        seen.update(input(UUID().uuidString, .reported, .done, 1, codex: true))
        XCTAssertFalse(seen.animationKeys.contains(pulse), "An ending seen for the first time draws without replaying")
        let quiet = UUID().uuidString, reduced = shown()
        reduced.update(input(quiet, .reported, .working, 0.4, animates: false, codex: true))
        reduced.update(input(quiet, .reported, .done, 1, animates: false, codex: true))
        XCTAssertTrue(reduced.animationKeys.isEmpty, "Reduced motion fills without a pulse")
    }

    func testReducedMotionAndAHiddenPanelSettleAtFinalValuesWithoutClocks() async throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .reported, .working, 0.3, animates: false))
        view.update(input(id, .reported, .working, 0.62, animates: false))
        XCTAssertEqual(running(view), [])
        XCTAssertFalse(view.animationKeys.contains("arc.sweep"))
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0)
        XCTAssertEqual(view.restingFraction, 0.62, accuracy: 0.0001)

        view.update(input(id, .reported, .working, 0.62))
        XCTAssertEqual(running(view), ["flow.travel"], "Motion returns with the setting")
        view.update(input(id, .reported, .working, 0.8))
        shows = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        try await TestWait.until { self.running(view).isEmpty }
        XCTAssertTrue(view.animationKeys.isEmpty, "An occluded or hidden panel runs no animations")
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0, "A rebuilt row inherits the settled value")
        shows = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        try await TestWait.until { !self.running(view).isEmpty }
        XCTAssertEqual(running(view), ["flow.travel"])
    }

    func testReducedMotionAndOcclusionCancelFiniteAnimationsDuringEveryTransition() throws {
        for occluded in [false, true] {
            let id = UUID().uuidString
            let transitions = [
                [input(id, .pending)],
                [input(id, .pending), input(id, .reported, .working, 0.62)],
                [input(id, .reported, .working, 0.8), input(id, .reported, .working, 0.1)],
                [input(id, .pending), input(id, .reported, .done, 1)],
                [input(id, .reported, .working, 0.8), input(id, .pending)],
                [input(id, .reported, .waiting, 0.5)],
                [input(id, .pending), input(id, nil)]
            ]
            for transition in transitions {
                shows = true
                let view = shown()
                // Each scenario has its own task memory.
                let taskID = UUID().uuidString
                for value in transition {
                    view.update(.init(id: taskID, state: value.state, mode: value.mode, fraction: value.fraction,
                        color: ink, animates: true))
                }
                let last = try XCTUnwrap(transition.last)
                XCTAssertFalse(view.animationKeys.isEmpty, "The transition must be in motion before it is stopped")
                if occluded {
                    shows = false
                    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
                } else {
                    view.update(.init(id: taskID, state: last.state, mode: last.mode, fraction: last.fraction,
                        color: ink, animates: false))
                }
                XCTAssertTrue(view.animationKeys.isEmpty, "Stopping motion cancels pulses, crossfades, traces and loops")
                XCTAssertEqual(view.restingFraction, last.fraction, accuracy: 0.0001)
                XCTAssertEqual(view.showsRing, last.state != nil)
                if last.state != nil { XCTAssertEqual(Ring.memory(for: taskID)?.duration, 0) }
            }
        }
    }

    func testReducedMotionAppliesANewEstimateWithoutKeepingAnEarlierCompletionPulse() {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending))
        view.update(input(id, .reported, .done, 1))
        XCTAssertTrue(view.animationKeys.contains("icon.pulse"))
        view.update(input(id, .reported, .working, 0.2, animates: false))
        XCTAssertTrue(view.animationKeys.isEmpty)
        XCTAssertEqual(view.restingFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(Ring.memory(for: id)?.duration, 0)
    }

    func testARingWithoutAnEstimateAtItsEndFadesAndIsForgotten() {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        XCTAssertTrue(view.showsRing)
        view.update(input(id, nil))
        XCTAssertNil(Ring.memory(for: id))
        XCTAssertTrue(view.animationKeys.contains("container.fade"))
        XCTAssertFalse(view.showsRing)
        XCTAssertEqual(running(view), [])

        let still = UUID().uuidString, reduced = shown()
        reduced.update(input(still, .pending, .working, animates: false))
        reduced.update(input(still, nil, animates: false))
        XCTAssertFalse(reduced.showsRing)
        XCTAssertFalse(reduced.animationKeys.contains("container.fade"))
    }

    func testACloudRunThatEndsClosesItsCometBeforeTheArcSweepsToFull() throws {
        let id = UUID().uuidString, view = shown()
        view.update(input(id, .pending, .working))
        let before = CACurrentMediaTime()
        view.update(input(id, .reported, .done, 1))
        let memory = try XCTUnwrap(Ring.memory(for: id))
        XCTAssertEqual(memory.from, 0); XCTAssertEqual(memory.to, 1)
        XCTAssertGreaterThanOrEqual(memory.start, before + 0.2, "The arc waits for the comet to close")
        XCTAssertEqual(memory.duration, 0.6, accuracy: 0.0001)
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["pending.opacity", "arc.sweep", "icon.pulse"]))
        XCTAssertEqual(running(view), [], "The comet stops where it is")
    }

    /// The middle of the icon: a working stage lights its glyph's parts in
    /// turn; a request for the user or an ending fills a disc once, and a
    /// rebuilt row or a first sight draws it without replaying the arrival.
    func testFacesPlayTheirArrivalOnceAndOnlyWorkingGlyphsLoop() {
        func face(_ id: String, _ face: Ring.Face, _ state: TaskProgressRing.State? = nil, _ mode: TaskProgressRing.Mode = .working,
                  _ fraction: Double = 0, animates: Bool = true) -> Ring.Input {
            .init(id: id, state: state, mode: mode, fraction: fraction, face: face, color: ink, animates: animates)
        }
        let id = UUID().uuidString, view = shown()
        view.update(face(id, .working(.thinking), .reported, .working, 0.5))
        XCTAssertTrue(view.showsOrb); XCTAssertFalse(view.showsDisc)
        XCTAssertEqual(running(view), ["flow.travel", "glyph.rhythm"])
        XCTAssertFalse(view.animationKeys.contains("glyph.swap"), "A first sight draws its glyph at once")
        view.update(face(id, .working(.tool), .reported, .working, 0.5))
        XCTAssertTrue(view.animationKeys.contains("glyph.swap"), "A new stage swaps its glyph")
        view.update(face(id, .solid(.completed, read: false), .reported, .done, 1))
        XCTAssertTrue(view.showsDisc); XCTAssertFalse(view.showsOrb)
        XCTAssertTrue(view.animationKeys.isSuperset(of: ["arc.sweep", "disc.fill", "glyph.draw", "icon.pulse", "ring.opacity"]),
            "The arc closes, the disc fills, the check is drawn and the icon pops")
        XCTAssertEqual(running(view), [], "A solid face keeps still")

        let rebuilt = shown()
        view.removeFromSuperview()
        rebuilt.update(face(id, .solid(.completed, read: false), .reported, .done, 1))
        XCTAssertTrue(rebuilt.showsDisc)
        XCTAssertTrue(rebuilt.animationKeys.isDisjoint(with: ["disc.fill", "glyph.draw", "icon.pulse"]), "A rebuilt row does not replay the ending")
        rebuilt.update(face(id, .solid(.completed, read: true), .reported, .done, 1))
        XCTAssertTrue(rebuilt.animationKeys.isDisjoint(with: ["disc.fill", "icon.pulse"]), "Reading an ending greys it without a second arrival")

        let asking = UUID().uuidString, row = shown()
        row.update(face(asking, .working(.tool), .pending))
        XCTAssertEqual(running(row), ["pending.spin", "glyph.rhythm"])
        row.update(face(asking, .solid(.approval, read: false), .pending, .attention))
        XCTAssertTrue(row.animationKeys.isSuperset(of: ["disc.fill", "icon.bounce", "ripple.ping"]), "A request for the user bounces and rings")
        XCTAssertEqual(running(row), [])
        row.update(face(asking, .working(.tool), .pending))
        XCTAssertTrue(row.animationKeys.isSuperset(of: ["disc.fill", "ring.opacity"]), "Back at work, the disc empties and the ring returns")
        XCTAssertFalse(row.showsDisc)
        XCTAssertEqual(running(row), ["pending.spin", "glyph.rhythm"])
        row.update(face(asking, .solid(.failed, read: false), .reported, .failed, 0.4))
        XCTAssertTrue(row.animationKeys.contains("icon.shake"), "A failure shakes once")

        let seen = shown()
        seen.update(face(UUID().uuidString, .solid(.approval, read: false), .pending, .attention))
        XCTAssertTrue(seen.showsDisc)
        XCTAssertEqual(seen.animationKeys, [], "A request seen for the first time draws without its arrival")

        let quiet = UUID().uuidString, reduced = shown()
        reduced.update(face(quiet, .working(.thinking), .reported, .working, 0.5, animates: false))
        reduced.update(face(quiet, .solid(.completed, read: false), .reported, .done, 1, animates: false))
        XCTAssertTrue(reduced.showsDisc)
        XCTAssertTrue(reduced.animationKeys.isEmpty, "Reduced motion fills the disc without motion")
        let still = shown()
        still.update(face(UUID().uuidString, .working(.responding), .pending, animates: false))
        XCTAssertTrue(still.animationKeys.isEmpty, "Without motion the glyph keeps all its parts lit and the comet stands still")
    }

    private func layer(named name: String, in root: CALayer?) -> CALayer? {
        guard let root else { return nil }
        if root.name == name { return root }
        return root.sublayers?.lazy.compactMap { self.layer(named: name, in: $0) }.first
    }

    func testOrbSurfaceEnclosesTheMeasuredAreaAndOnlyMovesForChanges() throws {
        let view = shown()
        var value = input(UUID().uuidString, .reported, .working, 0.35)
        value.face = .working(.thinking)
        view.update(value)
        XCTAssertNil(layer(named: "contextLevel", in: view.layer))
        for fraction in [0, 0.05, 0.25, 0.5, 0.81, 0.989, 0.99, 1] {
            value.contextFraction = fraction
            view.update(value)
            let fill = try XCTUnwrap(layer(named: "contextLevel", in: view.layer) as? CAGradientLayer)
            let stops = try XCTUnwrap(fill.locations?.map(\.doubleValue))
            let orb = try XCTUnwrap(fill.superlayer), diameter = orb.bounds.width
            let height = stops[1] * fill.bounds.height
            let x = 1 - 2 * height / diameter
            XCTAssertEqual((acos(x) - x * sqrt(1 - x * x)) / .pi, fraction, accuracy: 0.00001)
            XCTAssertEqual((stops[3] - stops[1]) * fill.bounds.height, (fraction > 0 && fraction < 0.99) ? 0.7 : 0, accuracy: 0.00001)
            XCTAssertEqual(fill.superlayer?.cornerRadius, diameter / 2)
            XCTAssertEqual(fill.superlayer?.masksToBounds, true)
            XCTAssertEqual(fill.startPoint.y, fill.anchorPoint.y)
            XCTAssertEqual(fill.startPoint.y, orb.contentsAreFlipped() ? 1 : 0)
            if fraction > 0 {
                let move = try XCTUnwrap(fill.animation(forKey: "level"))
                XCTAssertEqual(move.duration, 0.5); XCTAssertEqual(move.repeatCount, 0)
            }
            XCTAssertNil(fill.animation(forKey: "press"))
        }
        value.contextFraction = nil
        view.update(value)
        XCTAssertNil(layer(named: "contextLevel", in: view.layer))
        for symbol in [TaskSymbol.approval, .input] {
            value.face = .solid(symbol, read: false); value.contextFraction = 0.7
            value.compactingSince = Date()
            view.update(value)
            XCTAssertTrue(view.showsDisc)
            XCTAssertNil(layer(named: "contextLevel", in: view.layer))
            XCTAssertNil(layer(named: "compress", in: view.layer))
        }
    }

    func testEndedDiscsKeepTheRingArrivalThenShowBothTones() throws {
        let view = shown()
        var value = input(UUID().uuidString, .reported, .working, 0.4)
        value.face = .working(.tool); value.contextFraction = 0.5
        view.update(value)
        for read in [false, true] {
            value.face = .solid(.completed, read: read); value.mode = .done; value.fraction = 1
            view.update(value)
            let level = try XCTUnwrap(layer(named: "contextLevel", in: view.layer) as? CAGradientLayer)
            let disc = try XCTUnwrap(level.superlayer)
            let paint = try XCTUnwrap(disc.sublayers?.first { $0.mask != nil })
            let clip = try XCTUnwrap(paint.mask as? CAGradientLayer)
            XCTAssertEqual((level.colors as? [CGColor])?.last?.alpha ?? -1, read ? 0.08 : 0.42, accuracy: 0.001)
            let bottom = try XCTUnwrap(paint.sublayers?.first as? CAGradientLayer)
            XCTAssertEqual((bottom.colors as? [CGColor])?.last?.alpha ?? -1, read ? 0.21 : 1, accuracy: 0.001)
            XCTAssertEqual((clip.colors as? [CGColor])?.map(\.alpha), [1, 1, 0, 0])
            XCTAssertEqual(clip.locations, level.locations)
            XCTAssertEqual(clip.locations?[1].doubleValue ?? -1, 0.5, accuracy: 0.00001)
            if !read {
                let arrival = try XCTUnwrap(disc.mask?.animation(forKey: "fill"))
                let reveal = try XCTUnwrap(clip.animation(forKey: "level") as? CABasicAnimation)
                XCTAssertGreaterThanOrEqual(reveal.beginTime + 0.01, arrival.beginTime + arrival.duration)
                XCTAssertEqual((reveal.fromValue as? [NSNumber])?[1], 1)
            }
        }
    }

    func testRenderedHalfFullFacesKeepTheirTopAndBottomTones() throws {
        let view = shown(), id = UUID().uuidString
        let scale = 4, size = Int(Ring.diameter) * scale
        for face in [Ring.Face.working(.tool), .solid(.completed, read: false), .solid(.completed, read: true)] {
            view.update(.init(id: id, state: nil, face: face, contextFraction: 0.5, color: ink, animates: false))
            let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            try XCTUnwrap(view.layer).render(in: context)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            // Both samples are inside the circle, clear of the glyph, surface and ring.
            let top = try XCTUnwrap(bitmap.colorAt(x: size / 2, y: 6 * scale)).alphaComponent
            let bottom = try XCTUnwrap(bitmap.colorAt(x: size / 2, y: 22 * scale)).alphaComponent
            switch face {
            case .working:
                XCTAssertEqual(top, 0.06, accuracy: 0.02); XCTAssertEqual(bottom, 0.25, accuracy: 0.04)
            case .solid(_, let read):
                XCTAssertEqual(top, read ? 0.08 : 0.42, accuracy: 0.02); XCTAssertEqual(bottom, read ? 0.21 : 1, accuracy: 0.02)
            default: XCTFail("Unexpected sample face")
            }
        }
    }

    func testCompactionHoldsTheArcAndOnlyPressesWhileMotionIsVisible() throws {
        let view = shown(), id = UUID().uuidString
        var value = input(id, .reported, .working, 0.43)
        value.face = .working(.thinking); value.contextFraction = 0.9
        view.update(value)
        let since = Date()
        value.compactingSince = since
        view.update(value)
        let glyph = try XCTUnwrap(layer(named: "compress", in: view.layer))
        let parts = try XCTUnwrap(glyph.sublayers as? [CAShapeLayer])
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].path?.boundingBox.width ?? 0, 9.2, accuracy: 0.05)
        XCTAssertNil(parts[0].animation(forKey: "press"))
        XCTAssertEqual(glyph.animation(forKey: "swap")?.duration, 0.3)
        let fill = try XCTUnwrap(layer(named: "contextLevel", in: view.layer))
        for animation in [parts[1].animation(forKey: "press"), parts[2].animation(forKey: "press"),
                          fill.animation(forKey: "press"), fill.animation(forKey: "density")] {
            let press = try XCTUnwrap(animation)
            XCTAssertTrue(press.autoreverses); XCTAssertEqual(press.duration * 2, 2.4)
            XCTAssertEqual(press.preferredFrameRateRange.maximum, 30)
        }
        value.fraction = 0.7
        view.update(value)
        XCTAssertEqual(view.restingFraction, 0.43)
        XCTAssertEqual(running(view), [], "Ring light and ordinary glyph rhythms stop")
        shows = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        XCTAssertTrue(view.animationKeys.isEmpty)
        XCTAssertNotNil(layer(named: "compress", in: view.layer))
        shows = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
        XCTAssertTrue(view.animationKeys.contains("water.press"))
        view.update(.init(id: id, state: .reported, fraction: 0.7, face: .working(.thinking), contextFraction: 0.9,
                          compactingSince: since, color: ink, animates: false))
        XCTAssertTrue(view.animationKeys.isEmpty)
        XCTAssertNotNil(layer(named: "compress", in: view.layer))
        view.update(value)
        value.contextFraction = 0.25; value.compactingSince = nil
        view.update(value)
        XCTAssertEqual(fill.animation(forKey: "level")?.duration, 0.9)
        XCTAssertNil(fill.animation(forKey: "press"))
        XCTAssertTrue(view.animationKeys.contains("flow.travel"))
        value.compactingSince = since
        view.update(value)
        value.compactingSince = nil; value.contextFraction = nil
        view.update(value)
        XCTAssertFalse(view.showsContextLevel, "An end marker can precede the replacement reading")
        value.contextFraction = 0.12
        view.update(value)
        XCTAssertEqual(layer(named: "contextLevel", in: view.layer)?.animation(forKey: "level")?.duration, 0.9)
        view.removeFromSuperview()
        XCTAssertTrue(view.animationKeys.isEmpty)
    }

    func testWorkingGlyphsAreDrawnInsideTheirBox() {
        XCTAssertEqual(TaskGlyphArt.svg("M7.6 10.1l2.6 1.9-2.6 1.9").boundingBoxOfPath.integral, CGRect(x: 7, y: 10, width: 4, height: 4))
        let cloud = TaskGlyphArt.svg("M7.6 18.2h9a4 4 0 0 0 .5-7.97 5.4 5.4 0 0 0-10.3 1.2A3.4 3.4 0 0 0 7.6 18.2z").boundingBoxOfPath
        XCTAssertEqual(cloud.minX, 3.79, accuracy: 0.05, "The left lobe bulges outwards, on the side its flags pick")
        XCTAssertEqual(cloud.maxY, 18.2, accuracy: 0.05); XCTAssertGreaterThan(cloud.minY, 3); XCTAssertLessThan(cloud.maxX, 22)
        for symbol in [TaskSymbol.thinking, .tool, .responding, .starting, .working, .coordinating, .background] {
            let parts = TaskGlyphArt.parts(for: symbol)
            XCTAssertFalse(parts.isEmpty, "\(symbol)")
            for part in parts {
                let box = part.path.boundingBoxOfPath
                XCTAssertGreaterThan(box.width + box.height, 1, "\(symbol)")
                XCTAssertTrue(CGRect(x: 1, y: 1, width: 22, height: 22).contains(box), "\(symbol) \(box)")
            }
            XCTAssertTrue(symbol == .working || parts.contains { $0.rhythm != nil }, "Every working glyph but the cloud's has a part that moves")
        }
        for symbol in [TaskSymbol.approval, .input, .interrupted, .failed] {
            let name = try? XCTUnwrap(TaskGlyphArt.solidSymbol(for: symbol))
            XCTAssertNotNil(name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, "\(symbol)")
        }
    }

    /// Segments fill to each task's estimate; a task without one breathes on
    /// the long-step clock until its estimate arrives.
    func testSegmentsBreatheForTasksWithoutAnEstimate() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let ring = TaskSegmentsView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(ring)
        typealias Segment = TaskSegmentsView.Segment
        ring.update(segments: [Segment(color: .systemTeal, fraction: 0.6, stale: false), Segment(color: .systemOrange, fraction: nil, stale: false),
            Segment(color: .systemOrange, fraction: nil, stale: false)], scale: 1, animates: true)
        XCTAssertEqual(ring.breathingLanes, [1, 2])
        XCTAssertEqual(ring.fillFractions, [0.6, 0, 0])
        ring.update(segments: [Segment(color: .systemTeal, fraction: 0.6, stale: false), Segment(color: .systemOrange, fraction: 0.2, stale: false),
            Segment(color: .systemOrange, fraction: nil, stale: false)], scale: 1, animates: true)
        XCTAssertEqual(ring.breathingLanes, [2], "An estimate replaces the breath")
        XCTAssertEqual(ring.fillFractions, [0.6, 0.2, 0], "and leaves the other arcs as they were")
        ring.update(segments: [Segment(color: .systemTeal, fraction: 0.6, stale: false), Segment(color: .systemOrange, fraction: nil, stale: false)],
            scale: 1, animates: false)
        XCTAssertEqual(ring.breathingLanes, [], "Without motion only the track shows")
        ring.removeFromSuperview()
        ring.update(segments: [Segment(color: .systemOrange, fraction: nil, stale: false), Segment(color: .systemTeal, fraction: nil, stale: false)],
            scale: 1, animates: true)
        XCTAssertEqual(ring.breathingLanes, [], "Out of a window nothing runs")
        window.close()
    }

    /// With one task reporting, the badge's comets give way to its estimate.
    func testTheBadgeDrawsTheOnlyTasksEstimateWithTheRowsMotion() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let orbit = ActivityOrbitView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(orbit)
        orbit.layoutSubtreeIfNeeded()
        let codex = [ActivityOrbit.Segment(color: .systemTeal, weight: 1), .init(color: .systemOrange, weight: 0)]
        orbit.update(segments: codex, animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["orbit.orbit"])
        XCTAssertFalse(orbit.showsEstimate)
        orbit.update(segments: codex, progress: .init(fraction: 0.4, longStep: false, stale: false), animates: true)
        XCTAssertTrue(orbit.showsEstimate)
        XCTAssertEqual(orbit.estimateFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["flow.travel"], "Light runs along the arc in place of the orbit")
        orbit.update(segments: codex, progress: .init(fraction: 0.4, longStep: true, stale: false), animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["step.breath"], "A long step breathes past the head")
        orbit.update(segments: codex, progress: .init(fraction: 0.4, longStep: false, stale: true), animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, [], "A stale estimate keeps still")
        orbit.update(segments: codex, progress: .init(fraction: 0.7, longStep: false, stale: false), animates: false)
        XCTAssertEqual(orbit.estimateAnimationKeys, [])
        XCTAssertEqual(orbit.estimateFraction, 0.7, accuracy: 0.0001)
        orbit.update(segments: codex, progress: nil, animates: true)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["orbit.orbit"], "Without an estimate the comet returns")
        XCTAssertFalse(orbit.showsEstimate)
        window.close()
    }

    /// Codex for Claude runs show as Codex's light travelling the stretch of
    /// the ring an estimate has not reached, in every ring that shows estimates.
    func testCodexForClaudeRunsTravelTheFreeStretch() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let orbit = ActivityOrbitView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(orbit)
        orbit.layoutSubtreeIfNeeded()
        let claude = [ActivityOrbit.Segment(color: .systemOrange, weight: 1)], gap = HelperFlow.gap
        orbit.update(segments: claude, progress: .init(fraction: 0.62, longStep: false, stale: false), animates: true)
        XCTAssertNil(orbit.helperStretch, "No run, no light")
        orbit.update(segments: claude, progress: .init(fraction: 0.62, longStep: false, stale: false), helpers: 1, animates: true)
        let free = try XCTUnwrap(orbit.helperStretch)
        XCTAssertEqual(free.lowerBound, 0.62 + gap, accuracy: 0.0001, "The light keeps clear of the arc's head")
        XCTAssertEqual(free.upperBound, 1 - gap, accuracy: 0.0001, "and of the top, where the arc starts")
        XCTAssertTrue(orbit.helperTravels)
        XCTAssertEqual(orbit.estimateAnimationKeys, ["flow.travel"], "Claude's light keeps running along its arc")
        orbit.update(segments: claude, progress: .init(fraction: 0.62, longStep: true, stale: false), helpers: 1, animates: true)
        XCTAssertEqual(try XCTUnwrap(orbit.helperStretch).lowerBound, 0.62 + TaskStatusIconNSView.stepLengths[0] + gap, accuracy: 0.0001,
                       "and of a long step's breath")
        XCTAssertTrue(orbit.helperTravels, "Codex keeps working while Claude's step is long")
        orbit.update(segments: claude, progress: .init(fraction: 0.95, longStep: false, stale: false), helpers: 1, animates: true)
        XCTAssertNil(orbit.helperStretch, "Too little ring left to show")
        XCTAssertFalse(orbit.helperTravels)
        orbit.update(segments: claude, progress: .init(fraction: 0.3, longStep: false, stale: false), helpers: 2, animates: false)
        XCTAssertTrue(orbit.helperTinted, "Without motion the stretch keeps a still tint")
        XCTAssertFalse(orbit.helperTravels)
        orbit.update(segments: claude, progress: nil, helpers: 0, animates: true)
        XCTAssertNil(orbit.helperStretch, "Without an estimate the runs join the comets instead")
        window.close()

        // A light shows only inside its stretch: it enters at the start, leaves past the end, then rests unseen.
        for downward in [false, true] {
            let light = ArcLight(color: .white, peak: 1)
            light.place(frame: CGRect(x: 0, y: 0, width: 20, height: 20), path: CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 18, height: 18), transform: nil),
                        lineWidth: 2, downward: downward)
            light.refresh((0.5, 0.9), live: true, now: 0)
            XCTAssertTrue(light.travels)
            let frames = try XCTUnwrap(light.windowKeyframes)
            XCTAssertEqual(frames.starts.first, 0.5); XCTAssertEqual(frames.ends.first, 0.5)
            XCTAssertEqual(frames.starts.last, 0.9); XCTAssertEqual(frames.ends.last, 0.9)
            XCTAssertTrue((frames.starts + frames.ends).allSatisfy { (0.5...0.9).contains($0) }, "It never leaves the stretch")
            XCTAssertTrue(zip(frames.starts, frames.ends).allSatisfy { $0 <= $1 })
            light.refresh(nil, live: true)
            XCTAssertFalse(light.travels)
        }

        // Segments: the light travels the free stretch of the task the runs work for.
        let segmentsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: true)
        segmentsWindow.isReleasedWhenClosed = false
        let ring = TaskSegmentsView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        segmentsWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        segmentsWindow.contentView?.addSubview(ring)
        typealias Segment = TaskSegmentsView.Segment
        ring.update(segments: [Segment(color: .systemOrange, fraction: 0.4, stale: false, helpers: 1),
            Segment(color: .systemTeal, fraction: 0.5, stale: false)], scale: 1, animates: true)
        XCTAssertNotNil(ring.helperStretches[0]); XCTAssertNil(ring.helperStretches[1])
        XCTAssertGreaterThan(try XCTUnwrap(ring.helperStretches[0]).lowerBound, 0.4)
        XCTAssertTrue(ring.helpersTravel)
        ring.update(segments: [Segment(color: .systemOrange, fraction: 0.4, stale: false), Segment(color: .systemTeal, fraction: 0.5, stale: false)],
            scale: 1, animates: true)
        XCTAssertEqual(ring.helperStretches.compactMap { $0 }.count, 0)
        XCTAssertFalse(ring.helpersTravel, "The runs ended")
        segmentsWindow.close()
    }
}
