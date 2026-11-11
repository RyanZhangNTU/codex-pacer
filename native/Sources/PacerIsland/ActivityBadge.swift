import AppKit
import PacerCore
import SwiftUI

/// What the badge core shows while exactly one task is active.
typealias ActivityBadgeSingleTask = CompactBarPresentation.SingleTask
extension CompactBarPresentation.SingleTask {
    static let defaultsKey = "compactSingleTask"
    init(defaults: UserDefaults = .standard) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .stage
    }
    var label: String { L10n.text("layout.single_task." + rawValue) }
}

extension HeaderActivity.Ending {
    var symbol: String { StatusSymbols.symbol(kind) }
    var tint: Color {
        switch self {
        case .completed(let provider): provider.tint
        case .interrupted: PacerPalette.paused
        case .failed: PacerPalette.danger
        }
    }
}

/// The badge's component choices: what the core shows for one task and what
/// the ring shows while several run.
struct ActivityBadgeOptions: Equatable {
    var singlePercent = false
    var multiRing: CompactComponentOptions.MultiRing = .service
    var multiCore: CompactComponentOptions.MultiCore = .count
    var endMark = true
}

struct ActivityBadge: View {
    let activity: HeaderActivity
    var options = ActivityBadgeOptions()
    /// The badge's side; its drawing keeps the 20-point geometry and scales.
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandLayoutProbe) private var layoutProbe
    @State private var ripples = 0
    @State private var blooms = 0
    @State private var shakes = 0
    private static let attentionInk = Color(red: 0.26, green: 0.15, blue: 0.02)
    /// Ink on a solid ending, as in the task rows.
    private static let endingInk = Color.black.opacity(0.74)
    private var k: CGFloat { max(0.5, size / 20) }

    /// Several running tasks can show their estimates instead of the services:
    /// the average as one arc, or one arc per task. A request keeps the amber disc.
    private var several: Bool { activity.activeCount > 1 && activity.attention == nil }
    private var multiRing: HeaderActivity.MultiTaskRing? { activity.multiTaskRing(options.multiRing) }
    private var average: Double? { multiRing == .average ? activity.averageProgress : nil }
    private var segmented: Bool { multiRing == .segments }
    private var estimate: ActivityOrbit.Progress? {
        if let average { return .init(fraction: average, longStep: false, stale: activity.averageStale) }
        if segmented { return nil }
        return activity.progress.map { .init(fraction: $0.fraction, longStep: [.longStep, .waiting].contains($0.mode), stale: $0.stale) }
    }
    /// The average of several services is drawn in the neutral ink; one service keeps its color.
    private var estimateInk: NSColor? {
        guard average != nil else { return nil }
        return activity.averageProvider.map { NSColor($0.tint) } ?? PacerPalette.tickInk
    }
    private var percent: String? {
        func text(_ fraction: Double) -> String { String(Int((min(1, max(0, fraction)) * 100).rounded())) }
        // The core's percent is the average's choice; segments that give way to it keep the count.
        if let average, options.multiRing == .average, options.multiCore == .percent { return text(average) }
        if options.singlePercent, activity.activeCount == 1, activity.attention == nil, let progress = activity.progress { return text(progress.fraction) }
        return nil
    }
    private var solid: Bool { activity.attention != nil || activity.endingIsCore }

    var body: some View {
        let core: CGFloat = solid ? 17 : 15, k = k
        // The stack keeps the core's count/symbol switch inside it. In the
        // island's nesting, a switch at the root of this chain recreated the
        // orbit as well, which dropped its easing and restarted its rotation.
        ZStack { coreView }
            .frame(minWidth: core * k, minHeight: core * k)
            .padding(.horizontal, isWide ? 3.5 * k : 0)
            .background { fill }
            .overlay { ripple }
            .padding((20 - core) / 2 * k)
            .frame(minWidth: 20 * k, minHeight: 20 * k)
            .background {
                if segmented {
                    TaskSegmentsRing(tasks: activity.tasks, scale: k, animates: !reduceMotion && !layoutProbe).transition(.opacity)
                } else if !activity.orbit.isEmpty || estimate != nil {
                    ActivityOrbit(segments: AgentProvider.allCases.map { provider in
                        ActivityOrbit.Segment(color: NSColor(provider.tint), weight: activity.orbit[provider] ?? 0)
                    }, progress: estimate, ink: estimateInk, lineWidth: 2 * k, light: PacerPalette.light,
                        animates: !reduceMotion && !layoutProbe)
                    .transition(.opacity)
                }
            }
            .background {
                // A request keeps a faint second ring around the amber disc after its ripples.
                if activity.attention != nil {
                    Circle().stroke(PacerPalette.attention, lineWidth: 1.1 * k).frame(width: 21.8 * k, height: 21.8 * k).opacity(0.4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if options.endMark, activity.showsEndingMark, let ending = activity.ending {
                    Circle().fill(ending.tint).frame(width: 6 * k, height: 6 * k)
                        .overlay(Circle().stroke(Color.black.opacity(0.85), lineWidth: 1.5 * k))
                        .offset(x: k, y: -k)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: blooms) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.18, duration: 0.18, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
                }
            }
            // A failed ending shakes the badge once from side to side.
            .keyframeAnimator(initialValue: 0.0, trigger: shakes) { content, offset in
                content.offset(x: offset * k)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-2, duration: 0.1); LinearKeyframe(2, duration: 0.1); LinearKeyframe(-2, duration: 0.1)
                    LinearKeyframe(2, duration: 0.1); LinearKeyframe(-0.9, duration: 0.1); LinearKeyframe(0, duration: 0.1)
                }
            }
            .fixedSize()
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: activity)
            .onChange(of: activity.attention) { previous, current in
                if previous == nil, current != nil, !reduceMotion { ripples += 1 }
            }
            .onChange(of: activity.ending) { previous, current in
                if previous == nil, current != nil, !reduceMotion { blooms += 1 }
                if case .failed = current, !reduceMotion, !layoutProbe {
                    if case .failed = previous {} else { shakes += 1 }
                }
            }
    }

    private var isWide: Bool {
        if percent == nil, case .count(let count) = activity.core { return count >= 10 }
        return false
    }
    private var ink: Color {
        if activity.attention != nil { return Self.attentionInk }
        if activity.endingIsCore, activity.ending != nil { return Self.endingInk }
        return PacerPalette.primary
    }
    @ViewBuilder private var coreView: some View {
        if let percent {
            Text(percent).font(.system(size: 8 * k, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(ink)
                .contentTransition(.numericText())
        } else {
            switch activity.core {
            case .idle:
                Circle().fill(PacerPalette.tertiary).frame(width: 5 * k, height: 5 * k)
            case .symbol(let name):
                Image(systemName: StatusSymbols.enclosed(name)).font(.system(size: 9 * k, weight: .bold))
                    .foregroundStyle(ink).contentTransition(.symbolEffect(.replace))
            case .count(let count):
                Text(HeaderActivity.countText(count)).font(.system(size: 10 * k, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(ink).contentTransition(.numericText(value: Double(count)))
            }
        }
    }
    @ViewBuilder private var fill: some View {
        if activity.attention != nil {
            Capsule().fill(PacerPalette.attention)
        } else if activity.endingIsCore, let ending = activity.ending {
            // Everything ended: a solid disc in the ending's colour, lit from the top like a row's.
            Capsule().fill(LinearGradient(colors: [Color(nsColor: NSColor(ending.tint).blended(withFraction: 0.28, of: .white) ?? NSColor(ending.tint)), ending.tint], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0)], startPoint: .top, endPoint: .center)))
        } else if several, showsText {
            // Several tasks: the count sits on a faint disc so it reads steadily over the ring.
            Capsule().fill(PacerPalette.overlay(18 / 255))
        }
    }
    private var showsText: Bool {
        if percent != nil { return true }
        if case .count = activity.core { return true }
        return false
    }
    /// Two pings when attention arrives, then a steady solid fill.
    private var ripple: some View {
        Capsule().stroke(PacerPalette.attention, lineWidth: 1.5 * k)
            .keyframeAnimator(initialValue: RippleFrame(), trigger: ripples) { content, frame in
                content.scaleEffect(frame.scale).opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(1); CubicKeyframe(1.9, duration: 0.75)
                    MoveKeyframe(1); CubicKeyframe(1.9, duration: 0.75)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0.8); CubicKeyframe(0, duration: 0.75)
                    MoveKeyframe(0.8); CubicKeyframe(0, duration: 0.75)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct RippleFrame {
    var scale = 1.0
    var opacity = 0.0
}

/// One arc per running task, in the task list's order, each filled to its
/// estimate over a track in its service's colour. An estimate that has not
/// changed for a while fades; a task without one breathes along its whole arc,
/// in step with a long step's breath, and its estimate replaces the breath.
struct TaskSegmentsRing: View {
    let tasks: [HeaderActivity.TaskShare]
    var scale: CGFloat = 1
    let animates: Bool

    var body: some View {
        TaskSegmentsLayer(segments: tasks.map { TaskSegmentsView.Segment(color: NSColor($0.provider.tint), fraction: $0.fraction, stale: $0.stale) },
            scale: scale, animates: animates)
            .frame(width: 20 * scale, height: 20 * scale)
            .accessibilityHidden(true)
    }
}

/// Core Animation runs the breath in the render server, so the island does
/// not redraw SwiftUI every frame; it pauses while the window is occluded and
/// holds still with Reduce Motion, leaving the track.
private struct TaskSegmentsLayer: NSViewRepresentable {
    let segments: [TaskSegmentsView.Segment]
    let scale: CGFloat
    let animates: Bool
    func makeNSView(context: Context) -> TaskSegmentsView { TaskSegmentsView() }
    func updateNSView(_ view: TaskSegmentsView, context: Context) { view.update(segments: segments, scale: scale, animates: animates) }
}

final class TaskSegmentsView: NSView {
    struct Segment: Equatable {
        let color: NSColor
        /// The task's estimate; nil breathes.
        let fraction: Double?
        let stale: Bool
    }
    private struct Lane {
        let track = CAShapeLayer(), fill = CAShapeLayer(), breath = CAShapeLayer()
        var layers: [CAShapeLayer] { [track, fill, breath] }
    }
    static let trackOpacity = 0.26, staleOpacity: Float = 0.45
    /// The gap between two arcs, as a share of the circle.
    static let gap = 18.0 / 360
    private var segments: [Segment] = []
    private var lanes: [Lane] = []
    private var scale: CGFloat = 1
    private var animates = true
    private var occlusionObserver: NSObjectProtocol?
    private var motionVisible: Bool { animates && window.map(TaskStatusIconNSView.windowShows) == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(segments: [Segment], scale: CGFloat, animates: Bool) {
        let previous = self.segments, reshaped = segments.count != lanes.count || scale != self.scale
        self.segments = segments; self.scale = scale; self.animates = animates
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while lanes.count < segments.count {
            let lane = Lane()
            for shape in lane.layers {
                shape.fillColor = nil; shape.lineCap = .butt; shape.strokeStart = 0
                layer?.addSublayer(shape)
            }
            lane.breath.opacity = 0
            lanes.append(lane)
        }
        while lanes.count > segments.count { lanes.removeLast().layers.forEach { $0.removeFromSuperlayer() } }
        for (index, (lane, segment)) in zip(lanes, segments).enumerated() {
            lane.track.strokeColor = segment.color.withAlphaComponent(Self.trackOpacity).cgColor
            lane.fill.strokeColor = segment.color.cgColor
            lane.breath.strokeColor = segment.color.cgColor
            lane.layers.forEach { $0.lineWidth = 1.8 * scale }
            let target = segment.fraction.map { min(1, max(0, $0)) } ?? 0
            let shown = index < previous.count && !reshaped ? Double((lane.fill.presentation() ?? lane.fill).strokeEnd) : target
            lane.fill.strokeEnd = target
            lane.fill.opacity = segment.stale ? Self.staleOpacity : 1
            // A new estimate eases from the value on screen, as the badge's arc does.
            if motionVisible, abs(target - shown) > 0.0005 {
                let sweep = CABasicAnimation(keyPath: "strokeEnd")
                sweep.fromValue = shown; sweep.toValue = target; sweep.duration = 0.3 + 0.3 * abs(target - shown)
                sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
                lane.fill.add(sweep, forKey: "sweep")
            }
        }
        CATransaction.commit()
        if reshaped { needsLayout = true }
        refreshBreath()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let count = lanes.count, span = (1 - Self.gap * Double(count)) / Double(max(1, count))
        let center = CGPoint(x: bounds.midX, y: bounds.midY), radius = 8.6 * scale
        let flipped = layer?.contentsAreFlipped() == true
        for (index, lane) in lanes.enumerated() {
            // Each arc starts at its place from the top and runs clockwise on screen.
            let start = Self.gap / 2 + Double(index) * (span + Self.gap), path = CGMutablePath()
            if flipped {
                path.addArc(center: center, radius: radius, startAngle: -.pi / 2 + start * 2 * .pi,
                    endAngle: -.pi / 2 + (start + span) * 2 * .pi, clockwise: false)
            } else {
                path.addArc(center: center, radius: radius, startAngle: .pi / 2 - start * 2 * .pi,
                    endAngle: .pi / 2 - (start + span) * 2 * .pi, clockwise: true)
            }
            for shape in lane.layers { shape.frame = bounds; shape.path = path }
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshBreath() }
                }
        }
        refreshBreath()
    }

    /// The tasks without an estimate breathe on the shared long-step clock.
    private func refreshBreath() {
        let live = motionVisible
        let now = CACurrentMediaTime()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (lane, segment) in zip(lanes, segments) {
            if live && segment.fraction == nil {
                if lane.breath.animation(forKey: "breath") == nil {
                    lane.breath.add(TaskStatusIconNSView.stepBreath(on: lane.breath, now: now), forKey: "breath")
                }
            } else { lane.breath.removeAnimation(forKey: "breath") }
            if !live { lane.fill.removeAnimation(forKey: "sweep") }
        }
    }
    /// The lanes that breathe now, by index; read by tests.
    var breathingLanes: [Int] { lanes.indices.filter { lanes[$0].breath.animation(forKey: "breath") != nil } }
    var fillFractions: [Double] { lanes.map { Double($0.fill.strokeEnd) } }
}

/// A comet that circles the badge while work runs. Core Animation drives it in
/// the render server, so the island does not re-render SwiftUI every frame; it
/// pauses while the window is occluded and stays a static ring with Reduce Motion.
struct ActivityOrbit: NSViewRepresentable {
    /// One per provider, in a fixed order, so each keeps its own slot.
    struct Segment: Equatable {
        let color: NSColor
        /// Running tasks; zero leaves the slot empty.
        let weight: Int
    }
    struct Stop: Equatable {
        let color: NSColor
        let location: Double
    }
    /// The only task's reported estimate, drawn as an arc in place of the comets.
    struct Progress: Equatable {
        let fraction: Double
        let longStep: Bool
        let stale: Bool
    }
    let segments: [Segment]
    var progress: Progress? = nil
    /// The estimate's color when it is not the first running service's.
    var ink: NSColor? = nil
    var lineWidth: CGFloat = 2
    /// The island's tone, so overlays redraw when it changes.
    var light = PacerPalette.light
    let animates: Bool

    /// The running providers' comets start evenly spaced, in provider order:
    /// one at the top, two opposite, three a third apart; a provider starting
    /// or stopping eases the others to their new places. Comet length follows
    /// the share of running tasks. A conic gradient's location
    /// grows counterclockwise, so each opaque head is a hard edge after a
    /// transparent stop at the same location and leads the clockwise orbit;
    /// without that edge, the gap before a later comet would brighten into
    /// its head. Every slot keeps three stops, so a change can ease. Without
    /// motion the running shares fill the whole ring instead.
    static func stops(for segments: [Segment], animates: Bool) -> [Stop] {
        let running = segments.filter { $0.weight > 0 }
        let total = Double(max(1, running.reduce(0) { $0 + $1.weight }))
        guard animates else {
            var start = 0.0
            return running.flatMap { segment -> [Stop] in
                let color = segment.color.withAlphaComponent(0.75), end = start + Double(segment.weight) / total
                defer { start = end }
                return [Stop(color: color, location: start), Stop(color: color, location: end)]
            }
        }
        let span = running.count > 1 ? 0.5 : 0.34, slot = 1 / Double(max(1, running.count))
        var rank = 0, last = 0.0
        return segments.flatMap { segment -> [Stop] in
            let clear = segment.color.withAlphaComponent(0)
            // An idle provider keeps its three stops, collapsed where the last comet ended.
            guard segment.weight > 0 else { return Array(repeating: Stop(color: clear, location: last), count: 3) }
            let head = Double(rank) * slot, tail = head + min(span * Double(segment.weight) / total, slot * 0.9)
            rank += 1; last = tail
            return [Stop(color: clear, location: head), Stop(color: segment.color, location: head), Stop(color: clear, location: tail)]
        }
    }

    func makeNSView(context: Context) -> ActivityOrbitView { ActivityOrbitView() }
    func updateNSView(_ view: ActivityOrbitView, context: Context) {
        view.update(segments: segments, progress: progress, ink: ink, lineWidth: lineWidth, light: light, animates: animates)
    }
}

/// With one task reporting an estimate, the comets give way to an arc from
/// the top, clockwise, with the task rows' motion: light runs along it while
/// the task works, and the stretch past its head breathes during a long step.
final class ActivityOrbitView: NSView {
    private var lineWidth: CGFloat = 2
    private var ink: NSColor?
    private var light = PacerPalette.light
    private let track = CAShapeLayer()
    private let ring = CALayer()
    private let ringMask = CAShapeLayer()
    private let comet = CAGradientLayer()
    private let estimate = CALayer()
    private let arcGlow = CAShapeLayer(), arc = CAShapeLayer(), step = CAShapeLayer()
    private let flowBands = [CAShapeLayer(), CAShapeLayer()]
    private var segments: [ActivityOrbit.Segment] = []
    private var progress: ActivityOrbit.Progress?
    private var flowFraction: Double?
    private var animates = true
    private var occlusionObserver: NSObjectProtocol?
    private var motionVisible: Bool { animates && window.map(TaskStatusIconNSView.windowShows) == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.fillColor = nil
        track.strokeColor = PacerPalette.overlayInk(0.1).cgColor
        track.lineWidth = lineWidth
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = lineWidth
        ring.mask = ringMask
        comet.type = .conic
        comet.startPoint = CGPoint(x: 0.5, y: 0.5)
        comet.endPoint = CGPoint(x: 0.5, y: 0)
        ring.addSublayer(comet)
        for shape in [arcGlow, arc, step] + flowBands {
            shape.fillColor = nil; shape.lineWidth = lineWidth; shape.strokeStart = 0; shape.strokeEnd = 0
            estimate.addSublayer(shape)
        }
        arc.lineCap = .round; arcGlow.lineCap = .round; arcGlow.lineWidth = 2 * lineWidth; arcGlow.opacity = 0.22
        for (band, alpha) in zip(flowBands, [0.3, 0.45]) { band.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor }
        step.opacity = 0
        estimate.isHidden = true
        layer?.addSublayer(track)
        layer?.addSublayer(ring)
        layer?.addSublayer(estimate)
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(segments: [ActivityOrbit.Segment], progress: ActivityOrbit.Progress? = nil, ink: NSColor? = nil,
                lineWidth: CGFloat = 2, light: Bool = PacerPalette.light, animates: Bool) {
        let restyle = ink != self.ink || lineWidth != self.lineWidth || light != self.light
        guard segments != self.segments || progress != self.progress || animates != self.animates || restyle else { return }
        if restyle {
            self.ink = ink; self.lineWidth = lineWidth; self.light = light
            CATransaction.begin(); CATransaction.setDisableActions(true)
            track.strokeColor = PacerPalette.overlayInk(0.1).cgColor
            for shape in [track, ringMask, arc, step] + flowBands { shape.lineWidth = lineWidth }
            arcGlow.lineWidth = 2 * lineWidth
            CATransaction.commit()
            needsLayout = true
        }
        if segments != self.segments || animates != self.animates {
            let stops = ActivityOrbit.stops(for: segments, animates: animates)
            // A comet grows from or shrinks into its head; switching to or from
            // the static ring changes the stops entirely and snaps.
            let eases = animates && motionVisible && stops.count == comet.locations?.count
            self.segments = segments; self.animates = animates
            apply(stops, easing: eases)
        }
        let previous = self.progress
        self.progress = progress
        applyProgress(from: previous)
        refreshAnimation()
    }

    /// The arc eases from the value on screen to the new estimate; it fades
    /// in over the comet and out when the estimate goes.
    private func applyProgress(from previous: ActivityOrbit.Progress?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let ink = (self.ink ?? segments.first { $0.weight > 0 }?.color ?? PacerPalette.tickInk).cgColor
        let crossfade = motionVisible && (previous == nil) != (progress == nil)
        ring.opacity = progress == nil ? 1 : 0
        estimate.isHidden = progress == nil && !crossfade
        if crossfade {
            fade(ring, to: progress == nil ? 1 : 0)
            fade(estimate, to: progress == nil ? 0 : 1)
        }
        estimate.opacity = progress == nil ? 0 : 1
        guard let progress else { return }
        arc.strokeColor = ink; arcGlow.strokeColor = ink
        step.strokeColor = ink.copy(alpha: 0.38 * ink.alpha) ?? ink
        arc.opacity = progress.stale ? 0.45 : 1; arcGlow.opacity = progress.stale ? 0 : 0.22
        let target = min(1, max(0, progress.fraction))
        let shown = previous == nil ? 0 : Double((arc.presentation() ?? arc).strokeEnd)
        for shape in [arc, arcGlow] { shape.strokeEnd = target }
        step.strokeStart = target; step.strokeEnd = min(1, target + TaskStatusIconNSView.stepLengths[0])
        guard motionVisible, abs(target - shown) > 0.0005 else { return }
        let duration = 0.3 + 0.3 * abs(target - shown), timing = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        func ease(_ shape: CAShapeLayer, _ key: String, from: Double, to: Double) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = to; animation.duration = duration; animation.timingFunction = timing
            shape.add(animation, forKey: "sweep." + key)
        }
        for shape in [arc, arcGlow] { ease(shape, "strokeEnd", from: shown, to: target) }
        ease(step, "strokeStart", from: shown, to: target)
        ease(step, "strokeEnd", from: min(1, shown + TaskStatusIconNSView.stepLengths[0]), to: min(1, target + TaskStatusIconNSView.stepLengths[0]))
    }
    private func fade(_ layer: CALayer, to target: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = (layer.presentation() ?? layer).opacity; animation.toValue = target; animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "fade")
        if target == 0, layer === estimate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, self.progress == nil else { return }
                self.estimate.isHidden = true
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let inset = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = min(inset.width, inset.height) / 2
        let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for shape in [track, ringMask] { shape.frame = bounds; shape.path = path }
        ring.frame = bounds
        estimate.frame = bounds
        // The estimate starts at the top and runs clockwise on screen.
        let center = CGPoint(x: bounds.midX, y: bounds.midY), arcPath = CGMutablePath()
        if layer?.contentsAreFlipped() == true {
            arcPath.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        } else {
            arcPath.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        }
        for shape in [arcGlow, arc, step] + flowBands { shape.frame = bounds; shape.path = arcPath }
        // A square covering the diagonal keeps the rotating gradient under every edge of a wide capsule.
        let side = hypot(bounds.width, bounds.height)
        comet.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        comet.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAnimation() }
                }
        }
        refreshAnimation()
    }

    /// Eases from what is on screen, so a change during an earlier one
    /// continues from there. The orbit's rotation is a separate animation.
    private func apply(_ stops: [ActivityOrbit.Stop], easing: Bool) {
        let shown = comet.presentation() ?? comet
        let from: [String: Any?] = ["colors": shown.colors, "locations": shown.locations]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        comet.colors = stops.map(\.color.cgColor)
        comet.locations = stops.map { NSNumber(value: $0.location) }
        if easing {
            for (key, value) in from {
                let transition = CABasicAnimation(keyPath: key)
                transition.fromValue = value
                transition.duration = 0.35
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                comet.add(transition, forKey: key)
            }
        }
        CATransaction.commit()
    }

    private func refreshAnimation() {
        let live = motionVisible
        refreshEstimateLoops(live: live)
        if !live {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for key in ["colors", "locations"] { comet.removeAnimation(forKey: key) }
            ring.removeAnimation(forKey: "fade")
            estimate.removeAnimation(forKey: "fade")
            estimate.isHidden = progress == nil
            for shape in [arc, arcGlow, step] {
                shape.removeAnimation(forKey: "sweep.strokeStart")
                shape.removeAnimation(forKey: "sweep.strokeEnd")
            }
            CATransaction.commit()
        }
        guard live, progress == nil, segments.contains(where: { $0.weight > 0 }) else {
            comet.removeAnimation(forKey: "orbit")
            return
        }
        guard comet.animation(forKey: "orbit") == nil else { return }
        let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
        orbit.fromValue = 0
        orbit.toValue = -2 * Double.pi
        orbit.duration = 1.8
        orbit.repeatCount = .infinity
        orbit.isRemovedOnCompletion = false
        orbit.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        comet.add(orbit, forKey: "orbit")
    }

    /// Light runs along a working estimate; a long step breathes past its head.
    private func refreshEstimateLoops(live: Bool) {
        let now = CACurrentMediaTime()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let flow = progress.flatMap { live && !$0.longStep && !$0.stale && $0.fraction > 0.04 && $0.fraction < 0.9995 ? $0.fraction : nil }
        if flow != flowFraction {
            flowBands.forEach { $0.removeAnimation(forKey: "travel") }
            flowFraction = flow
            if let flow {
                for (band, length) in zip(flowBands, TaskStatusIconNSView.flowLengths) {
                    band.add(TaskStatusIconNSView.flowAnimation(fraction: flow, length: length, on: band, now: now), forKey: "travel")
                }
            }
        }
        let longStep = progress.map { $0.longStep && $0.fraction < 0.9995 } == true
        step.opacity = longStep ? 0.55 : 0
        if live && longStep {
            if step.animation(forKey: "breath") == nil { step.add(TaskStatusIconNSView.stepBreath(on: step, now: now), forKey: "breath") }
        } else { step.removeAnimation(forKey: "breath") }
    }
    /// The estimate's loops, as `layer.key`; read by tests.
    var estimateAnimationKeys: Set<String> {
        Set([("flow", flowBands[0]), ("step", step), ("orbit", comet)].flatMap { name, layer in
            (layer.animationKeys() ?? []).filter { !$0.hasPrefix("sweep") }.map { name + "." + $0 }
        })
    }
    var showsEstimate: Bool { !estimate.isHidden && progress != nil }
    var estimateFraction: Double { Double(arc.strokeEnd) }
}
