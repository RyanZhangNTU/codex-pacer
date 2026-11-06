import AppKit
import PacerCore
import QuartzCore
import SwiftUI

/// Claude's self-reported progress ring around a task row's status icon.
struct TaskProgressRingView: NSViewRepresentable {
    let id: String
    let ring: TaskProgressRing?
    let color: Color
    /// Off with reduced motion: final values and no loops.
    let animates: Bool

    func makeNSView(context: Context) -> TaskProgressRingNSView { TaskProgressRingNSView() }
    func updateNSView(_ view: TaskProgressRingNSView, context: Context) {
        view.update(.init(id: id, ring: ring, color: NSColor(color).cgColor, animates: animates))
    }
}

/// Task rows are rebuilt when the page changes or the panel opens again, so
/// each ring resumes from what the previous ring for the same task was showing
/// instead of restarting its motion. Every animation runs in Core Animation on
/// the shared media clock, and a new value starts from the displayed one.
/// Looping motion runs only while the panel is on screen and not occluded.
final class TaskProgressRingNSView: NSView {
    /// One row's ring, as Windows' `Show` takes it: no state means no ring.
    struct Input: Equatable {
        let id: String
        var state: TaskProgressRing.State?
        var mode = TaskProgressRing.Mode.working
        var fraction = 0.0
        var stale = false
        let color: CGColor
        let animates: Bool
        init(id: String, state: TaskProgressRing.State?, mode: TaskProgressRing.Mode = .working, fraction: Double = 0,
             stale: Bool = false, color: CGColor, animates: Bool) {
            self.id = id; self.state = state; self.mode = mode; self.fraction = fraction; self.stale = stale
            self.color = color; self.animates = animates
        }
        init(id: String, ring: TaskProgressRing?, color: CGColor, animates: Bool) {
            self.init(id: id, state: ring?.state, mode: ring?.mode ?? .working, fraction: ring?.fraction ?? 0,
                stale: ring?.stale ?? false, color: color, animates: animates)
        }
        /// The same ring, perhaps with motion switched.
        func sameRing(as other: Input) -> Bool {
            other.id == id && other.state == state && other.mode == mode && other.fraction == fraction
                && other.stale == stale && other.color == color
        }
    }
    /// Whether a window shows its content now; tests replace it.
    static var windowShows: (NSWindow) -> Bool = { $0.isVisible && $0.occlusionState.contains(.visible) }
    static let diameter: CGFloat = 28, stroke: CGFloat = 2, radius: CGFloat = 13
    private static let rotationPeriod = 6.0, dotTravel = 1.6, dotPeriod = 2.0, breathPeriod = 2.4
    /// A waiting ring breathes down to this share of its resting opacity.
    private static let breathLow = 0.2
    /// The dashes' resting opacity; the arc's is 1, or 0.45 once stale.
    private static let pendingOpacity: Float = 0.6, staleOpacity: Float = 0.45
    private static let trackInk = NSColor.white.withAlphaComponent(20 / 255).cgColor
    private static let dotInk = NSColor.white.withAlphaComponent(235 / 255).cgColor

    enum Ease: Equatable {
        case cubicOut, quadIn, sineInOut
        func callAsFunction(_ t: Double) -> Double {
            switch self {
            case .cubicOut: 1 - pow(1 - t, 3)
            case .quadIn: t * t
            case .sineInOut: (1 - cos(.pi * t)) / 2
            }
        }
    }
    /// What a task's ring last showed, kept across row rebuilds.
    struct Memory {
        var state: TaskProgressRing.State
        var from = 0.0, to = 0.0
        var start: CFTimeInterval = 0, duration: CFTimeInterval = 0
        var ease = Ease.cubicOut
        var stale = false, full = false
        /// The ring was breathing: a request waiting for its background work.
        var breathing = false
        var color: CGColor
        var seen: CFTimeInterval
        func displayed(at now: CFTimeInterval) -> Double {
            let elapsed = now - start
            if duration <= 0 || elapsed >= duration { return to }
            if elapsed <= 0 { return from }
            return from + (to - from) * ease(elapsed / duration)
        }
    }
    private static var memories: [String: Memory] = [:]
    static func memory(for id: String) -> Memory? { memories[id] }

    private let container = CALayer()
    private let pending = CAShapeLayer(), track = CAShapeLayer(), ghost = CAShapeLayer(), arc = CAShapeLayer(), dot = CAShapeLayer()
    private var input: Input?
    /// An update waiting for the view to reach a window, as a rebuilt row resumes only once it is shown.
    private var waiting: Input?
    private var taskID: String?
    private var mode = TaskProgressRing.Mode.working
    private var targetFraction = 0.0
    private var pendingShown = false, dim = false, fading = false, applying = false
    private var motion = false, windowVisible = false
    private var spinning = false
    private var dotFraction: Double?
    private weak var breathingTarget: CAShapeLayer?
    private var occlusionObserver: NSObjectProtocol?
    /// Whether this layer tree draws y downwards; paths and turns follow it.
    private var drawsDownward = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for shape in [pending, track, ghost, arc] { shape.fillColor = nil; shape.lineWidth = Self.stroke; shape.opacity = 0 }
        // Dash and gap lengths are multiples of the stroke: 2.2 pt on, 4.6 pt off.
        pending.lineDashPattern = [2.2, 4.6]; pending.lineCap = .round
        track.strokeColor = Self.trackInk
        arc.lineCap = .round; arc.strokeEnd = 0; arc.opacity = 1
        ghost.strokeEnd = 0
        dot.fillColor = Self.dotInk; dot.opacity = 0
        [pending, track, ghost, arc, dot].forEach(container.addSublayer)
        container.isHidden = true
        layer?.addSublayer(container)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI may size the view after its first layout pass; the ring stays centred.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        Self.withoutActions { centerContainer() }
        needsLayout = true
    }
    private func centerContainer() {
        let side = Self.diameter
        container.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func layout() {
        super.layout()
        let wasDownward = drawsDownward
        Self.withoutActions {
            let side = Self.diameter, frame = CGRect(x: 0, y: 0, width: side, height: side)
            centerContainer()
            drawsDownward = container.contentsAreFlipped()
            // Bounds and position, not frame: the dashes may already be turned.
            for shape in [pending, track, ghost, arc] { shape.bounds = frame; shape.position = CGPoint(x: side / 2, y: side / 2) }
            let circle = CGPath(ellipseIn: frame.insetBy(dx: side / 2 - Self.radius, dy: side / 2 - Self.radius), transform: nil)
            pending.path = circle; track.path = circle
            let path = arcPath(); arc.path = path; ghost.path = path
            dot.bounds = CGRect(x: 0, y: 0, width: 3.6, height: 3.6)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.position = point(along: 0)
            // Turns and the dot's path follow the drawing direction.
            if drawsDownward != wasDownward {
                pending.removeAnimation(forKey: "spin"); spinning = false
                dot.removeAnimation(forKey: "travel"); dotFraction = nil
            }
        }
        updateLoops()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibility() }
            }
        }
        refreshVisibility()
    }

    func update(_ next: Input) {
        waiting = next
        if window != nil { flush() }
    }

    private func refreshVisibility() {
        windowVisible = window.map(Self.windowShows) ?? false
        if window != nil, waiting != nil { flush() } else { refreshMotion() }
    }

    private func flush() {
        guard let next = waiting else { return }
        waiting = nil
        guard next != input else { refreshMotion(); return }
        let previous = input
        input = next
        if let previous, previous.sameRing(as: next) { refreshMotion(); return }
        motion = next.animates && windowVisible
        show(next)
    }

    /// Motion follows the panel: with reduced motion, or while it is hidden or
    /// occluded, the ring shows final values and never loops.
    private func refreshMotion() {
        let next = (input?.animates ?? false) && windowVisible
        if next != motion {
            motion = next
            if !motion {
                Self.withoutActions { setFraction(targetFraction) }
                // A rebuilt row inherits the settled value.
                if let taskID, var memory = Self.memories[taskID] {
                    memory.from = memory.to; memory.start = CACurrentMediaTime(); memory.duration = 0
                    Self.memories[taskID] = memory
                }
            }
        }
        updateLoops()
    }

    private func show(_ input: Input) {
        let fresh = taskID != input.id
        taskID = input.id
        applying = true
        Self.withoutActions {
            stopBreathing()
            if fresh { pending.transform = rotation(Self.spinAngle(CACurrentMediaTime())) }
            apply(input)
        }
        applying = false
        updateLoops()
    }

    private func apply(_ input: Input) {
        let animate = motion, now = CACurrentMediaTime(), id = input.id, color = input.color
        Self.prune(now)
        let previous = Self.memories[id]
        guard let state = input.state else {
            Self.memories[id] = nil
            mode = .working; pendingShown = false; targetFraction = 0
            guard let previous else { container.isHidden = true; return }
            // The request ended without an estimate, or the switch went off.
            setInk(previous.color, from: nil, animate: false)
            if previous.state == .pending { pending.opacity = Self.pendingOpacity; track.opacity = 0 }
            else { track.opacity = 1; setFraction(previous.displayed(at: now)) }
            container.isHidden = false
            guard animate else { container.isHidden = true; return }
            fading = true
            container.opacity = 0
            fadeOpacity(container, from: 1, to: 0, duration: 0.3, timing: .easeIn, key: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, self.fading, self.input?.state == nil else { return }
                self.container.isHidden = true
            }
            return
        }
        mode = input.mode
        fading = false
        container.removeAnimation(forKey: "fade"); container.opacity = 1; container.isHidden = false
        // Colour follows the icon: provider, attention, failure or read.
        setInk(color, from: previous?.color, animate: animate)
        if animate, previous == nil, state == .pending {
            fadeOpacity(container, from: 0, to: 1, duration: 0.25, timing: .easeOut, key: "appear")
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.85; scale.toValue = 1; scale.duration = 0.25
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.add(scale, forKey: "appearScale")
        }
        // A working request without a new estimate for a while dims.
        let dimmed = state == .reported && input.stale
        // Leaving the wait, the element eases from the breath's current opacity.
        let leftBreath = animate && previous?.breathing == true && mode != .waiting
        var memory = Memory(state: state, stale: dimmed, breathing: mode == .waiting, color: color, seen: now)
        if state == .pending {
            let shown = previous?.state == .reported ? previous!.displayed(at: now) : 0
            pendingShown = true; arc.removeAnimation(forKey: "opacity"); arc.opacity = 1; ghost.opacity = 0
            dim = false; targetFraction = 0
            if animate, shown > 0.0005 {
                // A new request replaces an old estimate: retract it, then dash in.
                track.opacity = 0; pending.opacity = Self.pendingOpacity
                sweep(from: shown, to: 0, duration: 0.3, ease: .quadIn, start: now)
                fadeOpacity(track, from: 1, to: 0, duration: 0.2, delay: 0.3)
                fadeOpacity(pending, from: 0, to: Double(Self.pendingOpacity), duration: 0.2, delay: 0.3)
            } else {
                setFraction(0); track.opacity = 0; pending.opacity = Self.pendingOpacity
                if leftBreath, previous?.state == .pending {
                    easeOutOfBreath(pending, high: Double(Self.pendingOpacity), to: Double(Self.pendingOpacity), now: now)
                }
            }
            Self.memories[id] = memory
            return
        }
        let target = min(1, max(0, input.fraction))
        dim = dimmed; targetFraction = target
        if var kept = previous, kept.state == .reported, abs(kept.to - target) < 0.0005 {
            // The same estimate on a rebuilt row: finish whatever was running.
            let remaining = kept.duration - (now - kept.start)
            track.opacity = 1; pending.opacity = 0; pendingShown = false
            if animate, remaining > 0.02 { sweep(from: kept.from, to: target, duration: kept.duration, ease: kept.ease, start: kept.start) }
            else { setFraction(target) }
            fade(wasStale: kept.stale, stale: dimmed, animate: animate)
            if leftBreath { easeOutOfBreath(arc, high: 1, to: dimmed ? Double(Self.staleOpacity) : 1, now: now) }
            kept.seen = now; kept.color = color; kept.stale = dimmed; kept.breathing = mode == .waiting
            Self.memories[id] = kept
            return
        }
        let from = previous?.state == .reported ? previous!.displayed(at: now) : 0
        var delay = 0.0, duration: Double, ease: Ease
        if previous?.state == .pending, animate {
            // The first estimate, or the ending of a request that never reported
            // (a cloud one): the dashes close into the track, then the arc sweeps.
            let dashes = previous!.breathing ? Self.breathOpacity(now, high: Double(Self.pendingOpacity)) : Double(Self.pendingOpacity)
            pending.opacity = 0; track.opacity = 1
            fadeOpacity(pending, from: dashes, to: 0, duration: 0.2)
            fadeOpacity(track, from: 0, to: 1, duration: 0.2)
            delay = 0.2; duration = 0.3 + 0.3 * target; ease = .cubicOut
        } else {
            pending.removeAnimation(forKey: "opacity"); track.removeAnimation(forKey: "opacity")
            pending.opacity = 0; track.opacity = 1
            let falling = target < from
            duration = falling ? 0.5 : 0.3 + 0.3 * abs(target - from)
            ease = falling ? .sineInOut : .cubicOut
            if falling, animate {
                // A lowered estimate leaves a fading trace of where it was.
                ghost.strokeEnd = from; ghost.opacity = 0
                fadeOpacity(ghost, from: 0.35, to: 0, duration: 0.6)
            }
        }
        pendingShown = false
        memory.from = from; memory.to = target; memory.start = now + delay; memory.ease = ease
        memory.duration = animate && previous != nil ? duration : 0
        if animate, previous != nil, abs(target - from) > 0.0005 {
            sweep(from: from, to: target, duration: duration, ease: ease, start: now + delay)
        } else {
            arc.removeAnimation(forKey: "opacity"); setFraction(target); duration = 0; memory.duration = 0
        }
        fade(wasStale: previous?.stale ?? false, stale: dimmed, animate: animate && previous != nil)
        if leftBreath, previous?.state == .reported { easeOutOfBreath(arc, high: 1, to: dimmed ? Double(Self.staleOpacity) : 1, now: now) }
        let full = target >= 0.9995
        if full, animate, let previous, !previous.full, mode == .working || mode == .done {
            // Reaching 100% settles with one small pulse once the sweep ends.
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.06, 1]; pulse.keyTimes = [0, 0.45, 1]; pulse.duration = 0.4
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            pulse.beginTime = container.convertTime(now + delay + duration + 0.05, from: nil)
            container.add(pulse, forKey: "pulse")
        }
        memory.full = full
        Self.memories[id] = memory
    }

    // MARK: Motion

    /// Looping motion by lifecycle mode. The dashes turn while the request
    /// works without an estimate; a light dot runs along a reported arc while
    /// it works; a waiting request breathes; a long step turns its dashes, and
    /// a request waiting for the user or an ended one keeps still. Loops share
    /// the media clock, so a rebuilt row's motion stays where the old one was.
    private func updateLoops() {
        guard !applying else { return }
        let now = CACurrentMediaTime()
        let live = motion && window != nil && !container.isHidden && !fading
        Self.withoutActions {
            let spin = live && pendingShown && (mode == .working || mode == .longStep)
            if spin != spinning {
                // Stopping keeps the dashes where they are, so closing ones fade in place.
                if spinning { pending.transform = rotation(Self.spinAngle(now)) }
                pending.removeAnimation(forKey: "spin")
                spinning = spin
                if spin {
                    let phase = Self.spinAngle(now), turn = CABasicAnimation(keyPath: "transform.rotation.z")
                    turn.fromValue = spinSign * phase; turn.toValue = spinSign * (phase + 2 * .pi)
                    turn.duration = Self.rotationPeriod; turn.repeatCount = .infinity
                    turn.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                    pending.add(turn, forKey: "spin")
                }
            }
            let travel = live && !pendingShown && !dim && mode == .working && targetFraction > 0.04 && targetFraction < 0.9995
            let wantedDot = travel ? targetFraction : nil
            if wantedDot != dotFraction {
                dot.removeAnimation(forKey: "travel"); dot.opacity = 0
                dotFraction = wantedDot
                if let fraction = wantedDot { dot.add(travelAnimation(fraction: fraction, now: now), forKey: "travel") }
            }
            // The dashes breathe until the first estimate, the arc after it.
            let breath: CAShapeLayer? = !live || mode != .waiting ? nil : pendingShown ? pending : arc
            if breath !== breathingTarget {
                stopBreathing()
                if let breath {
                    let high = breath === pending ? Double(Self.pendingOpacity) : 1, steps = 24
                    let animation = CAKeyframeAnimation(keyPath: "opacity")
                    animation.values = (0...steps).map { Self.breathOpacity(Self.breathPeriod * Double($0) / Double(steps), high: high) }
                    animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
                    animation.duration = Self.breathPeriod; animation.repeatCount = .infinity
                    animation.beginTime = breath.convertTime(now - now.truncatingRemainder(dividingBy: Self.breathPeriod), from: nil)
                    animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                    breath.add(animation, forKey: "breath")
                    breathingTarget = breath
                }
            }
        }
    }
    /// One run of the dot along the arc, eased in and out, then a pause.
    private func travelAnimation(fraction: Double, now: CFTimeInterval) -> CAAnimationGroup {
        let steps = 32
        var positions: [NSValue] = [], opacities: [NSNumber] = [], times: [NSNumber] = []
        for index in 0...steps {
            let seconds = Self.dotTravel * Double(index) / Double(steps)
            let phase = Ease.sineInOut(seconds / Self.dotTravel)
            positions.append(NSValue(point: point(along: phase * fraction)))
            opacities.append(NSNumber(value: 0.9 * sin(.pi * phase)))
            times.append(NSNumber(value: seconds / Self.dotPeriod))
        }
        positions.append(positions[positions.count - 1]); opacities.append(0); times.append(1)
        let position = CAKeyframeAnimation(keyPath: "position"), opacity = CAKeyframeAnimation(keyPath: "opacity")
        position.values = positions; position.keyTimes = times
        opacity.values = opacities; opacity.keyTimes = times
        let group = CAAnimationGroup()
        group.animations = [position, opacity]
        group.duration = Self.dotPeriod; group.repeatCount = .infinity
        group.beginTime = dot.convertTime(now - now.truncatingRemainder(dividingBy: Self.dotPeriod), from: nil)
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return group
    }
    /// Ends the breath and leaves the element at its resting opacity.
    private func stopBreathing() {
        guard let target = breathingTarget else { return }
        target.removeAnimation(forKey: "breath")
        if target === pending { pending.opacity = pendingShown ? Self.pendingOpacity : 0 }
        else { arc.opacity = dim ? Self.staleOpacity : 1 }
        breathingTarget = nil
    }
    private func easeOutOfBreath(_ layer: CAShapeLayer, high: Double, to target: Double, now: CFTimeInterval) {
        layer.opacity = Float(target)
        fadeOpacity(layer, from: Self.breathOpacity(now, high: high), to: target, duration: 0.3, timing: .easeInEaseOut)
    }
    /// The opacity a breathing element shows at `time` on the shared clock: from
    /// `high` to `high * breathLow` and back, so a rebuilt row picks it up
    /// exactly where the old one was.
    static func breathOpacity(_ time: CFTimeInterval, high: Double) -> Double {
        let half = breathPeriod / 2, t = time.truncatingRemainder(dividingBy: breathPeriod) / half
        let eased = (1 - cos(.pi * (t <= 1 ? t : 2 - t))) / 2
        return high - (high - high * breathLow) * eased
    }
    /// The dashes' turn on the shared clock, so every row spins in step.
    static func spinAngle(_ time: CFTimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod * 2 * .pi
    }

    // MARK: Drawing

    private func setFraction(_ value: Double) {
        arc.removeAnimation(forKey: "sweep")
        arc.strokeEnd = value
    }
    /// Sampled from the same curve `Memory.displayed` evaluates, so a rebuilt
    /// row continues a sweep from the exact displayed value.
    private func sweep(from: Double, to: Double, duration: Double, ease: Ease, start: CFTimeInterval) {
        setFraction(to)
        let length = max(0.01, duration)
        guard start + length > CACurrentMediaTime() else { return }
        let steps = 24, animation = CAKeyframeAnimation(keyPath: "strokeEnd")
        animation.values = (0...steps).map { from + (to - from) * ease(Double($0) / Double(steps)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = length
        animation.beginTime = arc.convertTime(start, from: nil)
        animation.fillMode = .backwards
        arc.add(animation, forKey: "sweep")
    }
    private func fade(wasStale: Bool, stale: Bool, animate: Bool) {
        let target = stale ? Self.staleOpacity : 1
        guard animate, wasStale != stale else { arc.removeAnimation(forKey: "opacity"); arc.opacity = target; return }
        arc.opacity = target
        fadeOpacity(arc, from: wasStale ? Double(Self.staleOpacity) : 1, to: Double(target), duration: stale ? 0.6 : 0.2, timing: .easeInEaseOut)
    }
    private func fadeOpacity(_ layer: CALayer, from: Double, to: Double, duration: Double, delay: Double = 0,
                             timing: CAMediaTimingFunctionName = .linear, key: String = "opacity") {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime() + delay, from: nil)
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: key)
    }
    private func setInk(_ color: CGColor, from previous: CGColor?, animate: Bool) {
        for shape in [pending, ghost, arc] {
            if animate, let previous, previous != color {
                let animation = CABasicAnimation(keyPath: "strokeColor")
                animation.fromValue = previous; animation.toValue = color; animation.duration = 0.25
                shape.add(animation, forKey: "ink")
            }
            shape.strokeColor = color
        }
    }
    /// The arc starts at the top and runs clockwise on screen.
    private func arcPath() -> CGPath {
        let center = CGPoint(x: Self.diameter / 2, y: Self.diameter / 2), path = CGMutablePath()
        if drawsDownward { path.addArc(center: center, radius: Self.radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false) }
        else { path.addArc(center: center, radius: Self.radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true) }
        return path
    }
    private func point(along fraction: Double) -> CGPoint {
        let angle = fraction * 2 * .pi, center = Self.diameter / 2
        return CGPoint(x: center + Self.radius * sin(angle), y: center + (drawsDownward ? -1 : 1) * Self.radius * cos(angle))
    }
    /// Clockwise on screen whichever way the layer tree draws.
    private var spinSign: Double { drawsDownward ? 1 : -1 }
    private func rotation(_ angle: Double) -> CATransform3D { CATransform3DMakeRotation(spinSign * angle, 0, 0, 1) }

    /// The animations each layer runs, as `layer.key`; read by tests.
    var animationKeys: Set<String> {
        let layers: [(String, CALayer)] = [("container", container), ("pending", pending), ("track", track), ("ghost", ghost), ("arc", arc), ("dot", dot)]
        return Set(layers.flatMap { name, layer in (layer.animationKeys() ?? []).map { name + "." + $0 } })
    }
    /// The arc's resting value and whether any ring shows; read by tests.
    var restingFraction: Double { Double(arc.strokeEnd) }
    var showsRing: Bool { !container.isHidden && !fading }
    func sweepBegin() -> CFTimeInterval? { arc.animation(forKey: "sweep")?.beginTime }

    private static func withoutActions(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
    /// Rows that have not been rebuilt for ten minutes are gone for good.
    private static func prune(_ now: CFTimeInterval) {
        guard memories.count >= 64 else { return }
        memories = memories.filter { now - $0.value.seen <= 600 }
    }
}
