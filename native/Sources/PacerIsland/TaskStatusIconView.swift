import AppKit
import PacerCore
import QuartzCore
import SwiftUI

/// A task row's status icon: the provider's self-reported progress ring, and
/// inside it the task's state. A working task shows a soft orb and a glyph
/// whose parts light in turn; a task that needs the user or has ended fills a
/// disc. A measured conversation fills the orb or ended disc from the bottom.
struct TaskStatusIconView: NSViewRepresentable {
    let id: String
    let ring: TaskProgressRing?
    let face: TaskStatusIconNSView.Face?
    var contextFraction: Double? = nil
    var compactingSince: Date? = nil
    let color: Color
    /// Off with reduced motion: final values and no loops.
    let animates: Bool
    var completionPulseOnly = false

    func makeNSView(context: Context) -> TaskStatusIconNSView { TaskStatusIconNSView() }
    func updateNSView(_ view: TaskStatusIconNSView, context: Context) {
        view.update(.init(id: id, ring: ring, face: face, contextFraction: contextFraction, compactingSince: compactingSince,
                          color: NSColor(color).cgColor, animates: animates,
                          completionPulseOnly: completionPulseOnly))
    }
}

/// Task rows are rebuilt when the page changes or the panel opens again, so
/// each icon resumes from what the previous icon for the same task was showing
/// instead of restarting its motion, and a state's arrival plays once. Every
/// animation runs in Core Animation on the shared media clock, and a new value
/// starts from the displayed one. Looping motion runs only while the panel is
/// on screen and not occluded, at no more than 30 frames a second.
///
/// The ring: a comet circles while a request works without an estimate,
/// slower with a shorter tail during a long step. A reported estimate is an
/// arc with a band of light running along it; during a long step the light
/// stops and the stretch just past the arc's head breathes. A request waiting
/// for background work breathes as a whole. All of it shares one circle, so a
/// change of state changes parameters rather than shapes.
final class TaskStatusIconNSView: NSView {
    /// What the middle of the icon shows.
    enum Face: Equatable {
        /// A working stage: an orb and the stage's glyph, its parts lit in turn.
        case working(TaskSymbol)
        /// Needs the user or has ended: a solid disc; `read` greys it.
        case solid(TaskSymbol, read: Bool)
        /// Nothing known: the glyph alone.
        case plain(TaskSymbol)
        case compacting
        var isSolid: Bool { if case .solid = self { true } else { false } }
        var isWorking: Bool { if case .working = self { true } else { self == .compacting } }
        var supportsLevel: Bool {
            switch self {
            case .working, .compacting: true
            case .solid(let symbol, _): [.completed, .interrupted, .failed].contains(symbol)
            case .plain: false
            }
        }
        /// The face of a request waiting for the user.
        var asksUser: Bool { if case .solid(let symbol, false) = self { [.approval, .input].contains(symbol) } else { false } }
    }

    /// One row's icon, as Windows' `Show` takes it: no state means no ring.
    struct Input: Equatable {
        let id: String
        var state: TaskProgressRing.State?
        var mode = TaskProgressRing.Mode.working
        var fraction = 0.0
        var stale = false
        var face: Face?
        var contextFraction: Double?
        var compactingSince: Date?
        var drawingFace: Face? {
            if contextFraction != nil, compactingSince != nil, face?.supportsLevel == true { return .compacting }
            return face
        }
        let color: CGColor
        let animates: Bool
        let completionPulseOnly: Bool
        init(id: String, state: TaskProgressRing.State?, mode: TaskProgressRing.Mode = .working, fraction: Double = 0,
             stale: Bool = false, face: Face? = nil, contextFraction: Double? = nil, compactingSince: Date? = nil,
             color: CGColor, animates: Bool, completionPulseOnly: Bool = false) {
            self.id = id; self.state = state; self.mode = mode; self.fraction = fraction; self.stale = stale
            self.contextFraction = contextFraction; self.compactingSince = compactingSince
            self.face = face; self.color = color; self.animates = animates
            self.completionPulseOnly = completionPulseOnly
        }
        init(id: String, ring: TaskProgressRing?, face: Face? = nil, contextFraction: Double? = nil, compactingSince: Date? = nil,
             color: CGColor, animates: Bool, completionPulseOnly: Bool = false) {
            self.init(id: id, state: ring?.state, mode: ring?.mode ?? .working, fraction: ring?.fraction ?? 0,
                stale: ring?.stale ?? false, face: face, contextFraction: contextFraction, compactingSince: compactingSince,
                color: color, animates: animates, completionPulseOnly: completionPulseOnly)
        }
        /// The same drawing, perhaps with motion switched.
        func sameDrawing(as other: Input) -> Bool {
            sameStatus(as: other) && other.contextFraction == contextFraction
        }
        func sameStatus(as other: Input) -> Bool {
            other.id == id && other.state == state && other.mode == mode && other.fraction == fraction
                && other.stale == stale && other.drawingFace == drawingFace && other.compactingSince == compactingSince
                && other.color == color && other.completionPulseOnly == completionPulseOnly
        }
    }
    /// Whether a window shows its content now; tests replace it.
    static var windowShows: (NSWindow) -> Bool = { $0.isVisible && $0.occlusionState.contains(.visible) }
    static let diameter: CGFloat = 28, stroke: CGFloat = 2, radius: CGFloat = 13
    /// The comet's turn: a working request, and a long step.
    static let workingPeriod = 2.0, longStepPeriod = 3.2
    /// The comet's tail as a share of the circle.
    private static let workingTail = 0.5, longStepTail = 0.26, launchTail = 0.015
    /// The band of light on a reported arc: one run, then a rest.
    static let flowPeriod = 2.6, flowTravel = 2.1, flowLengths = [0.22, 0.08]
    /// The stretch past the head that breathes during a long step.
    static let stepLengths = [0.1, 0.066, 0.033], stepPeriod = 2.6
    /// A waiting ring breathes down to this share of its resting opacity.
    private static let breathPeriod = 4.0, breathLow = 0.3
    /// The comet's resting opacity; the arc's is 1, or 0.45 once stale.
    private static let pendingOpacity: Float = 1, staleOpacity: Float = 0.45
    private static var trackInk: CGColor { PacerPalette.overlayInk(20 / 255).cgColor }
    private static let glyphSide: CGFloat = 14, orbSide: CGFloat = 20, discSide: CGFloat = 26
    /// The disc fills from the ring inwards, then the check is drawn.
    static let fillDuration = 0.42
    private static let darkInk = NSColor.black.withAlphaComponent(0.74).cgColor
    private static var readDisc: CGColor { PacerPalette.overlayInk(0.15).cgColor }
    private static var readInk: CGColor { PacerPalette.overlayInk(0.62).cgColor }
    /// The island's tone the overlays were drawn in.
    private var drawnLight = PacerPalette.light

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
        /// A replaced row cannot settle its successor's clock, and the memory
        /// must not keep a discarded view alive.
        weak var owner: TaskStatusIconNSView?
        var state: TaskProgressRing.State
        var from = 0.0, to = 0.0
        var start: CFTimeInterval = 0, duration: CFTimeInterval = 0
        var ease = Ease.cubicOut
        var stale = false, full = false, done = false
        var compactingSince: Date?
        /// The ring was breathing: a request waiting for its background work.
        var breathing = false
        var color: CGColor
        var seen: CFTimeInterval
        /// The comet's turn: its angle at `spinEpoch` and its period. A long
        /// step changes the period from the angle shown at that moment.
        var spinOrigin = 0.0, spinEpoch: CFTimeInterval = 0, spinPeriod = TaskStatusIconNSView.workingPeriod
        func displayed(at now: CFTimeInterval) -> Double {
            let elapsed = now - start
            if duration <= 0 || elapsed >= duration { return to }
            if elapsed <= 0 { return from }
            return from + (to - from) * ease(elapsed / duration)
        }
        func spinAngle(at time: CFTimeInterval) -> Double {
            (spinOrigin + (time - spinEpoch) / spinPeriod * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        }
    }
    private static var memories: [String: Memory] = [:]
    static func memory(for id: String) -> Memory? { memories[id] }
    /// What each task's face last showed, so a state's arrival plays once.
    private struct FaceMemory {
        weak var owner: TaskStatusIconNSView?
        var face: Face
        var seen: CFTimeInterval
        var level: LevelSweep?
        /// The end signal can invalidate the old sample before the new one arrives.
        var releasedHeight: Double?
    }
    private static var faces: [String: FaceMemory] = [:]

    /// The whole icon: it pulses, bounces and shakes.
    private let icon = CALayer()
    /// The ring, hidden under a solid face.
    private let ringHost = CALayer()
    private let container = CALayer()
    private let track = CAShapeLayer(), ghost = CAShapeLayer()
    /// The comet and its own track, or a still circle: it turns and breathes.
    private let pending = CALayer()
    private let cometTrack = CAShapeLayer(), comet = CAGradientLayer(), cometGlow = CAGradientLayer(), cometHead = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let arcGroup = CALayer(), arcGlow = CAShapeLayer(), arc = CAShapeLayer()
    private let flowLight = ArcLight(color: .white, peak: 0.6)
    private let step = CALayer(), stepBands = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let orb = CAGradientLayer()
    private let disc = CALayer(), discFill = CAGradientLayer(), discSheen = CAGradientLayer(), discMask = CAShapeLayer()
    private let discPaint = CALayer()
    private var water: ContextWater?
    private let ripples = [CAShapeLayer(), CAShapeLayer()]
    private let glyphHost = CALayer()
    private var glyph = CALayer()
    private var glyphParts: [(layer: CALayer, rhythm: TaskGlyphArt.Rhythm?)] = []
    /// What the glyph was drawn for; a change redraws it.
    private struct GlyphKey: Equatable { let face: Face; let ink: CGColor; let downward: Bool }
    private var glyphKey: GlyphKey?
    private var leavingGlyphs: [CALayer] = []

    private var input: Input?
    /// An update waiting for the view to reach a window, as a rebuilt row resumes only once it is shown.
    private var waiting: Input?
    private var taskID: String?
    private var mode = TaskProgressRing.Mode.working
    private var targetFraction = 0.0
    private var pendingShown = false, dim = false, fading = false, applying = false
    private var motion = false, windowVisible = false
    private var spinningPeriod: Double?
    private var flowFraction: Double?
    private var rhythmsRunning = false
    private weak var breathingTarget: CALayer?
    private var ink = NSColor.white.cgColor
    private var pulseAt: CFTimeInterval?
    private var occlusionObserver: NSObjectProtocol?
    /// Whether this layer tree draws y downwards; paths and turns follow it.
    private var drawsDownward = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for shape in [track, ghost, arc, arcGlow, cometTrack, halo] + stepBands {
            shape.fillColor = nil; shape.lineWidth = Self.stroke
        }
        track.strokeColor = Self.trackInk; cometTrack.strokeColor = Self.trackInk
        track.opacity = 0; ghost.opacity = 0; pending.opacity = 0
        arc.lineCap = .round; arc.strokeEnd = 0
        arcGlow.lineCap = .round; arcGlow.strokeEnd = 0; arcGlow.lineWidth = 4.5; arcGlow.opacity = 0.22
        ghost.strokeEnd = 0
        for band in stepBands { band.strokeStart = 0; band.strokeEnd = 0 }
        step.opacity = 0
        for gradient in [comet, cometGlow] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5); gradient.endPoint = CGPoint(x: 0.5, y: 0)
            let mask = CAShapeLayer()
            mask.fillColor = nil; mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = gradient === comet ? Self.stroke : 4.5
            gradient.mask = mask
        }
        cometGlow.opacity = 0.3
        halo.opacity = 0
        [cometTrack, cometGlow, comet, cometHead, halo].forEach(pending.addSublayer)
        [arcGlow, arc].forEach(arcGroup.addSublayer)
        stepBands.forEach(step.addSublayer)
        [track, pending, ghost, arcGroup].forEach(container.addSublayer)
        container.addSublayer(flowLight.layer)
        container.addSublayer(step)
        container.isHidden = true
        ringHost.addSublayer(container)
        orb.type = .radial; orb.opacity = 0; orb.masksToBounds = true
        discFill.type = .axial; discSheen.type = .axial
        disc.masksToBounds = true; disc.isHidden = true
        disc.addSublayer(discPaint)
        [discFill, discSheen].forEach(discPaint.addSublayer)
        discMask.fillRule = .evenOdd; disc.mask = discMask
        for ripple in ripples { ripple.fillColor = nil; ripple.lineWidth = 1.6; ripple.opacity = 0 }
        glyphHost.addSublayer(glyph)
        [ringHost, orb, disc].forEach(icon.addSublayer)
        ripples.forEach(icon.addSublayer)
        icon.addSublayer(glyphHost)
        layer?.addSublayer(icon)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI may size the view after its first layout pass; the icon stays centred.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        Self.withoutActions { centerIcon() }
        needsLayout = true
    }
    private func centerIcon() {
        let side = Self.diameter
        icon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        icon.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func layout() {
        super.layout()
        let wasDownward = drawsDownward
        Self.withoutActions {
            let side = Self.diameter, frame = CGRect(x: 0, y: 0, width: side, height: side)
            centerIcon()
            drawsDownward = icon.contentsAreFlipped()
            for host in [ringHost, container] { host.frame = frame }
            // Bounds and position, not frame: the comet may already be turned.
            for layer in [pending, arcGroup, step] as [CALayer] { layer.bounds = frame; layer.position = CGPoint(x: side / 2, y: side / 2) }
            for shape in [track, ghost, arc, arcGlow, cometTrack, halo] + stepBands + ripples {
                shape.bounds = frame; shape.position = CGPoint(x: side / 2, y: side / 2)
            }
            for gradient in [comet, cometGlow] {
                gradient.frame = frame
                (gradient.mask as? CAShapeLayer)?.frame = frame
                (gradient.mask as? CAShapeLayer)?.path = circle(radius: Self.radius)
            }
            let ring = circle(radius: Self.radius)
            track.path = ring; cometTrack.path = ring; halo.path = ring
            for ripple in ripples { ripple.path = ring }
            let path = arcPath()
            for shape in [arc, arcGlow, ghost] + stepBands { shape.path = path }
            flowLight.place(frame: frame, path: path, lineWidth: Self.stroke, downward: drawsDownward)
            // The comet's head sits on its gradient's seam, a hard edge it leads with.
            cometHead.frame = frame
            cometHead.path = CGPath(ellipseIn: CGRect(x: side / 2 - Self.stroke / 2, y: side / 2 - Self.radius - Self.stroke / 2,
                                                      width: Self.stroke, height: Self.stroke), transform: nil)
            orb.frame = frame.insetBy(dx: (side - Self.orbSide) / 2, dy: (side - Self.orbSide) / 2)
            orb.cornerRadius = Self.orbSide / 2
            orb.startPoint = CGPoint(x: 0.5, y: drawsDownward ? 0.28 : 0.72)
            orb.endPoint = CGPoint(x: 1.25, y: drawsDownward ? 1.03 : -0.03)
            disc.frame = frame.insetBy(dx: (side - Self.discSide) / 2, dy: (side - Self.discSide) / 2)
            disc.cornerRadius = Self.discSide / 2
            discPaint.frame = disc.bounds
            for gradient in [discFill, discSheen] {
                gradient.frame = disc.bounds
                gradient.startPoint = CGPoint(x: 0.5, y: drawsDownward ? 0 : 1); gradient.endPoint = CGPoint(x: 0.5, y: drawsDownward ? 1 : 0)
            }
            discSheen.colors = [NSColor.white.withAlphaComponent(0.26).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            discSheen.locations = [0, 0.62]
            discMask.frame = disc.bounds
            if discMask.path == nil { discMask.path = annulus(hole: Self.discSide / 2) }
            glyphHost.frame = frame.insetBy(dx: (side - Self.glyphSide) / 2, dy: (side - Self.glyphSide) / 2)
            // Turns and glyph paths follow the drawing direction.
            if drawsDownward != wasDownward {
                pending.removeAnimation(forKey: "spin"); spinningPeriod = nil
                flowLight.refresh(nil, live: false); flowFraction = nil
                applyCometStops(tail: cometTail)
                water?.place(downward: drawsDownward)
                glyphKey = nil
                if let input, input.drawingFace != nil { rebuildGlyph(for: input, animate: false) }
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
        if let scale = window?.backingScaleFactor { icon.contentsScale = scale; glyphHost.contentsScale = scale }
        refreshVisibility()
    }

    func update(_ next: Input) {
        // Light glass turns the overlays dark; a read disc and its mark follow.
        if drawnLight != PacerPalette.light {
            drawnLight = PacerPalette.light
            CATransaction.begin(); CATransaction.setDisableActions(true)
            track.strokeColor = Self.trackInk; cometTrack.strokeColor = Self.trackInk
            if let input, let face = input.drawingFace {
                setDiscColors(for: face, color: input.color, animate: false)
                rebuildGlyph(for: input, animate: false)
                water?.setColors(input.color, face: face)
            }
            CATransaction.commit()
        }
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
        if let previous, previous.sameDrawing(as: next) { refreshMotion(); return }
        motion = next.animates && windowVisible
        if let previous, previous.sameStatus(as: next), previous.animates == next.animates, let face = next.drawingFace {
            // A new measurement must not cancel an arrival or restart the outer ring.
            Self.withoutActions { applyLevel(next, face: face) }
            updateLoops()
        } else { show(next) }
    }

    /// Motion follows the panel: with reduced motion, or while it is hidden or
    /// occluded, the icon shows final values and never loops.
    private func refreshMotion() {
        let next = (input?.animates ?? false) && windowVisible
        if next != motion {
            motion = next
            if motion, let input { show(input); return }
            Self.withoutActions { settleMotion() }
        }
        updateLoops()
    }

    /// Cancel finite animations as well as loops, including delayed pulses and
    /// crossfades. The model layers already hold their final drawing values.
    private func settleMotion() {
        if spinningPeriod != nil { pending.transform = rotation(currentSpinAngle(CACurrentMediaTime())) }
        for layer in animatedLayers.map({ $0.1 }) { layer.removeAllAnimations() }
        leavingGlyphs.forEach { $0.removeFromSuperlayer() }; leavingGlyphs = []
        flowLight.refresh(nil, live: false)
        spinningPeriod = nil; flowFraction = nil; breathingTarget = nil; fading = false; rhythmsRunning = false; pulseAt = nil
        container.opacity = 1; container.isHidden = input?.state == nil
        pending.opacity = pendingShown ? Self.pendingOpacity : 0
        track.opacity = input?.state != nil && !pendingShown ? 1 : 0
        arcGroup.opacity = dim ? Self.staleOpacity : 1
        ghost.opacity = 0
        setFraction(targetFraction)
        applyCometStops(tail: cometTail)
        showComet(false)
        showStep(stepWanted, breathing: false)
        settleFace()
        // A row leaving the tree stops its own animations but keeps the shared
        // sweep available to its replacement, whichever row is removed first.
        if window != nil, let taskID, var memory = Self.memories[taskID], memory.owner === self {
            memory.from = memory.to; memory.start = CACurrentMediaTime(); memory.duration = 0
            Self.memories[taskID] = memory
        }
        if window != nil, let taskID, var face = Self.faces[taskID], face.owner === self, var level = face.level {
            level.from = level.to; level.duration = 0
            face.level = level; Self.faces[taskID] = face
        }
    }

    private func show(_ input: Input) {
        let fresh = taskID != input.id
        taskID = input.id
        applying = true
        Self.withoutActions {
            stopBreathing()
            pulseAt = nil
            apply(input)
            if fresh { pending.transform = rotation(currentSpinAngle(CACurrentMediaTime())) }
            let fillEnd = applyFace(input)
            if motion, let at = pulseAt { pulse(at: max(at, fillEnd ?? 0)) }
            pulseAt = nil
            if !motion { settleMotion() }
        }
        applying = false
        updateLoops()
    }

    // MARK: Ring

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
        if input.drawingFace == .compacting, let since = input.compactingSince {
            var held = previous ?? Memory(state: state, color: color, seen: now)
            // The first estimate can arrive in the same update as the press.
            // Capture that ring once, including across row rebuilds.
            if held.compactingSince != since {
                held.compactingSince = since
                held.state = state; held.to = state == .reported ? input.fraction : 0
                held.stale = input.stale; held.full = held.to >= 0.9995; held.done = input.mode == .done
            }
            mode = input.mode; dim = held.stale; pendingShown = held.state == .pending
            targetFraction = held.to
            for layer in [container, pending, arcGroup, ghost, track, comet, cometGlow] as [CALayer] { layer.removeAllAnimations() }
            if spinningPeriod != nil { pending.transform = rotation(currentSpinAngle(now)); spinningPeriod = nil }
            container.isHidden = false; container.opacity = 1; fading = false
            track.opacity = pendingShown ? 0 : 1; pending.opacity = pendingShown ? Self.pendingOpacity : 0
            arcGroup.opacity = dim ? Self.staleOpacity : 1; ghost.opacity = 0
            setInk(color, from: nil, animate: false); setFraction(targetFraction)
            held.owner = self; held.from = held.to; held.duration = 0; held.breathing = false
            held.color = color; held.seen = now
            Self.memories[id] = held
            return
        }
        let previousMode = mode
        mode = input.mode
        fading = false
        container.removeAnimation(forKey: "fade"); container.opacity = 1; container.isHidden = false
        // Colour follows the icon: provider, attention, failure or read.
        setInk(color, from: previous?.color, animate: animate)
        // A long step slows the comet and shortens its tail from where it is.
        // A ring first seen under a solid face is hidden, so it simply appears.
        let tail = cometTail, launches = animate && previous == nil && state == .pending && !(input.drawingFace?.isSolid ?? false)
        if animate, previous?.state == .pending, previousMode != mode, [previousMode, mode].allSatisfy({ [.working, .longStep].contains($0) }) {
            animateCometStops(to: tail, duration: 0.4, timing: CAMediaTimingFunction(name: .easeInEaseOut), key: "tail")
        } else if !launches {
            applyCometStops(tail: tail)
        }
        if launches {
            // A new request: the comet appears as a point and grows its tail.
            fadeOpacity(container, from: 0, to: 1, duration: 0.25, timing: .easeOut, key: "appear")
            applyCometStops(tail: Self.launchTail)
            animateCometStops(to: tail, duration: 0.9, timing: CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1), key: "launch")
        }
        // A working request without a new estimate for a while dims.
        let dimmed = state == .reported && input.stale
        // Leaving the wait, the element eases from the breath's current opacity.
        let leftBreath = animate && previous?.breathing == true && mode != .waiting
        let justCompleted = input.completionPulseOnly && mode == .done && previous?.done == false
        var memory = Memory(owner: self, state: state, stale: dimmed, done: mode == .done, breathing: mode == .waiting, color: color, seen: now)
        if let previous { memory.spinOrigin = previous.spinOrigin; memory.spinEpoch = previous.spinEpoch; memory.spinPeriod = previous.spinPeriod }
        let period = mode == .longStep ? Self.longStepPeriod : Self.workingPeriod
        if state == .pending, memory.spinPeriod != period {
            memory.spinOrigin = memory.spinAngle(at: now); memory.spinEpoch = now; memory.spinPeriod = period
        }
        if input.completionPulseOnly, previous?.done == true, mode != .done { icon.removeAnimation(forKey: "pulse") }
        if state == .pending {
            let shown = previous?.state == .reported ? previous!.displayed(at: now) : 0
            pendingShown = true; arcGroup.removeAnimation(forKey: "opacity"); arcGroup.opacity = 1; ghost.opacity = 0
            dim = false; targetFraction = 0
            if animate, shown > 0.0005 {
                // A new request replaces an old estimate: retract it, then the comet appears.
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
            if leftBreath { easeOutOfBreath(arcGroup, high: 1, to: dimmed ? Double(Self.staleOpacity) : 1, now: now) }
            if animate, justCompleted { schedulePulse(at: now + max(0, remaining)) }
            kept.owner = self; kept.seen = now; kept.color = color; kept.stale = dimmed; kept.breathing = mode == .waiting
            kept.done = memory.done
            kept.compactingSince = nil
            Self.memories[id] = kept
            return
        }
        let from = previous?.state == .reported ? previous!.displayed(at: now) : 0
        var delay = 0.0, duration: Double, ease: Ease
        if previous?.state == .pending, animate {
            // The first estimate, or the ending of a request that never reported
            // (a cloud one): the comet closes into the track, then the arc sweeps.
            let comet = previous!.breathing ? Self.breathOpacity(now, high: Double(Self.pendingOpacity)) : Double(Self.pendingOpacity)
            pending.opacity = 0; track.opacity = 1
            fadeOpacity(pending, from: comet, to: 0, duration: 0.2)
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
            arcGroup.removeAnimation(forKey: "opacity"); setFraction(target); duration = 0; memory.duration = 0
        }
        fade(wasStale: previous?.stale ?? false, stale: dimmed, animate: animate && previous != nil)
        if leftBreath, previous?.state == .reported { easeOutOfBreath(arcGroup, high: 1, to: dimmed ? Double(Self.staleOpacity) : 1, now: now) }
        let full = target >= 0.9995
        if full, animate, justCompleted || !input.completionPulseOnly && previous?.full == false && (mode == .working || mode == .done) {
            schedulePulse(at: now + delay + duration)
        }
        memory.full = full
        Self.memories[id] = memory
    }

    private func schedulePulse(at time: CFTimeInterval) { pulseAt = max(pulseAt ?? 0, time) }
    private func pulse(at time: CFTimeInterval) {
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, 1.06, 1]; pulse.keyTimes = [0, 0.45, 1]; pulse.duration = 0.4
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        pulse.beginTime = icon.convertTime(time + 0.05, from: nil)
        pulse.fillMode = .backwards
        icon.add(pulse, forKey: "pulse")
    }

    // MARK: Face

    /// Draws the middle of the icon and plays a new state's arrival once.
    /// Returns when a disc that fills now will be full.
    private func applyFace(_ input: Input) -> CFTimeInterval? {
        let now = CACurrentMediaTime(), next = input.drawingFace
        let previous = Self.faces[input.id]?.face
        guard let next else {
            Self.faces[input.id] = nil; removeWater()
            orb.opacity = 0; disc.isHidden = true; glyph.isHidden = true; ringHost.opacity = 1
            return nil
        }
        glyph.isHidden = false
        // A task seen for the first time draws its state without replaying its arrival.
        let arriving = motion && previous != nil && previous != next
        // A request that ends with an estimate closes its arc before the disc fills.
        var fillDelay = 0.0
        if case .solid(.completed, _) = next, let memory = Self.memories[input.id], memory.state == .reported {
            fillDelay = max(0, memory.start + memory.duration - now)
        }
        var fillEnd: CFTimeInterval?

        // The orb sits under a working glyph only.
        let orbShown = next.isWorking
        orb.colors = [input.color.copy(alpha: 0.32) ?? input.color, input.color.copy(alpha: 0.1) ?? input.color]
        orb.locations = [0, 0.72]
        if arriving, (orb.opacity > 0) != orbShown {
            fadeOpacity(orb, from: orbShown ? 0 : 1, to: orbShown ? 1 : 0, duration: 0.3, timing: .easeInEaseOut,
                        delay: orbShown ? 0 : fillDelay)
        }
        orb.opacity = orbShown ? 1 : 0

        // The disc fills from the ring inwards, and empties back out.
        if next.isSolid {
            setDiscColors(for: next, color: input.color, animate: arriving && previous?.isSolid == true)
            disc.isHidden = false
            let full = annulus(hole: 0)
            if arriving, previous?.isSolid != true {
                discMask.path = full
                animatePath(discMask, from: annulus(hole: Self.discSide / 2), to: full, duration: Self.fillDuration, delay: fillDelay, key: "fill")
                fillEnd = now + fillDelay + Self.fillDuration
            } else { discMask.removeAnimation(forKey: "fill"); discMask.path = full }
        } else if !disc.isHidden {
            let empty = annulus(hole: Self.discSide / 2)
            if arriving, previous?.isSolid == true {
                discMask.path = empty
                animatePath(discMask, from: annulus(hole: 0), to: empty, duration: 0.32, delay: 0, key: "fill")
            } else { discMask.path = empty; disc.isHidden = true }
        }

        // The ring hides under a solid face once it is full, and returns with work.
        let ringShown = !next.isSolid
        if arriving, (ringHost.opacity > 0) != ringShown {
            fadeOpacity(ringHost, from: ringShown ? 0 : 1, to: ringShown ? 1 : 0, duration: 0.25, timing: .easeInEaseOut,
                        delay: ringShown ? 0.12 : fillDelay + Self.fillDuration * 0.8)
        }
        ringHost.opacity = ringShown ? 1 : 0

        // Filling, the old glyph stays until the disc reaches it, and the new one is drawn on the full disc.
        let fills = next.isSolid && previous?.isSolid != true
        rebuildGlyph(for: input, animate: arriving, exitDelay: fills ? fillDelay + Self.fillDuration * 0.3 : 0,
                     drawDelay: fills ? fillDelay + Self.fillDuration * 0.55 : 0)

        // An ending pops once it is filled.
        if arriving, next == .solid(.completed, read: false), previous?.isSolid != true, let fillEnd { schedulePulse(at: fillEnd) }
        // Arrivals: a request for the user bounces and rings twice; a failure shakes.
        if arriving, next.asksUser, previous?.asksUser != true {
            bounce()
            ripple(color: input.color)
        }
        if arriving, next == .solid(.failed, read: false) { shake() }
        applyLevel(input, face: next, fillEnd: fillEnd)
        return fillEnd
    }

    private func setDiscColors(for face: Face, color: CGColor, animate: Bool) {
        let colors: [CGColor]
        if case .solid(_, true) = face {
            let gray = face.supportsLevel && input?.contextFraction != nil ? PacerPalette.overlayInk(0.21).cgColor : Self.readDisc
            colors = [gray, gray]
        }
        else { colors = [Self.lighten(color, by: 0.28), color] }
        if animate, let shown = (discFill.presentation() ?? discFill).colors {
            let transition = CABasicAnimation(keyPath: "colors")
            transition.fromValue = shown; transition.toValue = colors; transition.duration = 0.3
            discFill.add(transition, forKey: "colors")
        }
        discFill.colors = colors
        if case .solid(_, true) = face { discSheen.opacity = 0 } else { discSheen.opacity = 1 }
    }

    /// Replaces the glyph when the state or its ink changes: the old one
    /// shrinks and fades as the new one grows in, and a check is drawn.
    private func rebuildGlyph(for input: Input, animate: Bool, exitDelay: Double = 0, drawDelay: Double = 0) {
        guard let face = input.drawingFace else { return }
        let ink: CGColor
        switch face {
        case .working, .plain, .compacting: ink = input.color
        case .solid(_, let read): ink = read ? Self.readInk : Self.darkInk
        }
        let key = GlyphKey(face: face, ink: ink, downward: drawsDownward)
        guard key != glyphKey else { return }
        let crossfade = face == .compacting || glyphKey?.face == .compacting
        let wasDrawn = glyphKey != nil
        for part in glyphParts { part.layer.removeAnimation(forKey: "press") }
        glyphKey = key
        let old = glyph
        let (next, parts) = makeGlyph(face, ink: ink)
        glyph = next; glyphParts = parts; rhythmsRunning = false
        glyphHost.addSublayer(next)
        let check = face == .solid(.completed, read: false) ? parts.first?.layer as? CAShapeLayer : nil
        guard animate, wasDrawn else { old.removeFromSuperlayer(); return }
        // The old glyph leaves; the new one arrives, or a check draws itself.
        leavingGlyphs.append(old)
        let now = CACurrentMediaTime(), out = CAAnimationGroup()
        let fadeOut = CABasicAnimation(keyPath: "opacity"); fadeOut.fromValue = 1; fadeOut.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = 1; shrink.toValue = 0.6
        out.animations = crossfade ? [fadeOut] : [fadeOut, shrink]; out.duration = crossfade ? 0.3 : (exitDelay > 0 ? 0.2 : 0.32)
        out.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        out.beginTime = old.convertTime(now + exitDelay, from: nil); out.fillMode = .backwards
        old.opacity = 0
        old.add(out, forKey: "swap")
        DispatchQueue.main.asyncAfter(deadline: .now() + exitDelay + 0.34) { [weak self, weak old] in
            guard let self, let old else { return }
            old.removeFromSuperlayer(); self.leavingGlyphs.removeAll { $0 === old }
        }
        if let check {
            check.strokeEnd = 1
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.34
            draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            draw.beginTime = check.convertTime(now + drawDelay, from: nil); draw.fillMode = .backwards
            check.add(draw, forKey: "draw")
        } else {
            let arrive = CAAnimationGroup()
            let fadeIn = CABasicAnimation(keyPath: "opacity"); fadeIn.fromValue = 0; fadeIn.toValue = 1
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.6; grow.toValue = 1
            arrive.animations = crossfade ? [fadeIn] : [fadeIn, grow]; arrive.duration = crossfade ? 0.3 : 0.32
            arrive.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            arrive.beginTime = next.convertTime(now + drawDelay, from: nil); arrive.fillMode = .backwards
            next.add(arrive, forKey: "swap")
        }
    }

    private func makeGlyph(_ face: Face, ink: CGColor) -> (CALayer, [(layer: CALayer, rhythm: TaskGlyphArt.Rhythm?)]) {
        let side = Self.glyphSide, host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: side, height: side)
        host.contentsScale = glyphHost.contentsScale
        let scale = side / 24
        var transform = drawsDownward ? CGAffineTransform(scaleX: scale, y: scale)
            : CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: side)
        func shape(_ path: CGPath, filled: Bool, width: CGFloat) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.frame = host.bounds
            layer.path = path.copy(using: &transform)
            layer.strokeColor = ink; layer.lineWidth = width * scale
            layer.fillColor = filled ? ink : nil
            layer.lineCap = .round; layer.lineJoin = .round
            host.addSublayer(layer)
            return layer
        }
        var parts: [(layer: CALayer, rhythm: TaskGlyphArt.Rhythm?)] = []
        switch face {
        case .compacting:
            host.name = "compress"
            for path in Self.compressPaths {
                parts.append((shape(path, filled: false, width: 2), nil))
            }
        case .working(let symbol):
            for part in TaskGlyphArt.parts(for: symbol) {
                parts.append((shape(part.path, filled: part.filled, width: part.filled ? 0.6 : 2.1), part.rhythm))
            }
            if parts.isEmpty { parts.append((symbolLayer(StatusSymbols.symbol(symbol), ink: ink, size: 12, in: host), nil)) }
        case .solid(let symbol, _):
            if symbol == .completed { parts.append((shape(TaskGlyphArt.check, filled: false, width: 2.9), nil)) }
            else if let name = TaskGlyphArt.solidSymbol(for: symbol) {
                parts.append((symbolLayer(name, ink: ink, size: symbol == .failed ? 11 : 11.5, weight: symbol == .failed ? .bold : .semibold, in: host), nil))
            }
        case .plain(let symbol):
            parts.append((symbolLayer(StatusSymbols.symbol(symbol), ink: ink, size: 13, weight: .regular, in: host), nil))
        }
        return (host, parts)
    }

    /// An SF Symbol tinted by a mask, centred in the glyph box.
    private func symbolLayer(_ name: String, ink: CGColor, size: CGFloat, weight: NSFont.Weight = .medium, in host: CALayer) -> CALayer {
        let layer = CALayer()
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return layer }
        let scale = max(2, glyphHost.contentsScale), points = image.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(points.width * scale)), pixelsHigh: Int(ceil(points.height * scale)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        if let rep {
            rep.size = points
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: CGRect(origin: .zero, size: points))
            NSGraphicsContext.restoreGraphicsState()
        }
        let side = Self.glyphSide
        layer.frame = CGRect(x: (side - points.width) / 2, y: (side - points.height) / 2, width: points.width, height: points.height)
        layer.backgroundColor = ink
        let mask = CALayer()
        mask.frame = layer.bounds; mask.contents = rep?.cgImage; mask.contentsScale = scale
        mask.contentsGravity = .resizeAspect
        // Image contents follow the layer's geometry; keep the symbol upright.
        if drawsDownward { mask.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1)) }
        layer.mask = mask
        host.addSublayer(layer)
        return layer
    }

    private func bounce() {
        let lift = drawsDownward ? -1.0 : 1.0
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, 3.4 * lift, 0, 1.1 * lift, 0]; bounce.keyTimes = [0, 0.35, 0.7, 0.85, 1]
        bounce.duration = 0.55; bounce.beginTime = icon.convertTime(CACurrentMediaTime() + 0.15, from: nil); bounce.fillMode = .backwards
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        icon.add(bounce, forKey: "bounce")
    }
    private func ripple(color: CGColor) {
        for (index, ripple) in ripples.enumerated() {
            ripple.strokeColor = color
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 1.75
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.75; fade.toValue = 0
            let ping = CAAnimationGroup(); ping.animations = [grow, fade]; ping.duration = 0.8
            ping.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.4, 1)
            ping.beginTime = ripple.convertTime(CACurrentMediaTime() + 0.8 * Double(index), from: nil); ping.fillMode = .backwards
            ripple.opacity = 0
            ripple.add(ping, forKey: "ping")
        }
    }
    private func shake() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -2.5, 2.2, -1.4, 0.8, 0]; shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]; shake.duration = 0.5
        shake.beginTime = icon.convertTime(CACurrentMediaTime() + Self.fillDuration * 0.7, from: nil); shake.fillMode = .backwards
        icon.add(shake, forKey: "shake")
    }

    /// The final drawing of the face, with nothing in motion.
    private func settleFace() {
        guard let face = input?.drawingFace else { orb.opacity = 0; disc.isHidden = true; glyph.isHidden = true; ringHost.opacity = 1; return }
        orb.opacity = face.isWorking ? 1 : 0
        disc.isHidden = !face.isSolid
        discMask.path = annulus(hole: face.isSolid ? 0 : Self.discSide / 2)
        ringHost.opacity = face.isSolid ? 0 : 1
        for ripple in ripples { ripple.opacity = 0 }
        for part in glyphParts { part.layer.opacity = 1; (part.layer as? CAShapeLayer)?.strokeEnd = 1 }
        glyph.opacity = 1
    }

    // MARK: Conversation context

    /// Height as a share of the diameter. The circular segment below a chord at
    /// distance x from the centre has area r²(acos(x/r) − (x/r)√(1 − (x/r)²)).
    private static func levelHeight(_ fraction: Double) -> Double {
        if fraction <= 0 { return 0 }
        if fraction >= 1 { return 1 }
        var low = -1.0, high = 1.0
        for _ in 0..<24 {
            let x = (low + high) / 2
            if acos(x) - x * sqrt(1 - x * x) > .pi * fraction { low = x } else { high = x }
        }
        return (1 - (low + high) / 2) / 2
    }

    /// A rebuilt icon resumes the same transition on the media clock. The
    /// Bézier used on the layers has linear x and y = 3t² − 2t³.
    private struct LevelSweep {
        var from: Double, to: Double
        var start: CFTimeInterval, duration: Double
        func displayed(at now: CFTimeInterval) -> Double {
            guard duration > 0 else { return to }
            let t = min(1, max(0, (now - start) / duration))
            return from + (to - from) * t * t * (3 - 2 * t)
        }
    }

    /// A bottom-to-top gradient with coincident stops at the waterline. The
    /// orb/disc's rounded clip cuts that horizontal edge to the exact chord.
    /// On an ended disc the complementary mask exposes its original artwork below.
    @MainActor private final class ContextWater {
        let gradient = CAGradientLayer(), mask = CAGradientLayer()
        let isDisc: Bool
        let side: CGFloat
        var pressStart: Date?
        init(disc: Bool, downward: Bool) {
            isDisc = disc
            gradient.name = "contextLevel"
            side = disc ? TaskStatusIconNSView.discSide : TaskStatusIconNSView.orbSide
            mask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            place(downward: downward)
        }

        func place(downward: Bool) {
            // Extra air above the orb keeps it covered as the press scales the
            // gradient about the bottom. The disc never presses.
            for layer in isDisc ? [gradient, mask] : [gradient] {
                layer.bounds = CGRect(x: 0, y: 0, width: side, height: side * (isDisc ? 1 : 2))
                layer.anchorPoint = CGPoint(x: 0.5, y: downward ? 1 : 0)
                layer.position = CGPoint(x: side / 2, y: downward ? side : 0)
                layer.startPoint = layer.anchorPoint
                layer.endPoint = CGPoint(x: 0.5, y: downward ? 0 : 1)
            }
        }

        func setColors(_ color: CGColor, face: Face) {
            func ink(_ alpha: CGFloat) -> CGColor { color.copy(alpha: alpha) ?? color }
            if case .solid(_, let read) = face {
                let air = read ? PacerPalette.overlayInk(0.08).cgColor : ink(0.42)
                gradient.colors = [ink(0), ink(0), air, air]
            } else {
                gradient.colors = [ink(0.22), ink(0.4), ink(0.85), ink(0.85), ink(0.06), ink(0.06)]
            }
        }

        func stops(at height: Double) -> [NSNumber] {
            if isDisc { return [0, NSNumber(value: height), NSNumber(value: height), 1] }
            let edge = height / 2
            // The chord disappears at an empty orb and from 99% area onwards.
            let width = height > 0 && height < TaskStatusIconNSView.lineCutoff ? 0.7 / (2 * side) : 0
            let start = NSNumber(value: edge), end = NSNumber(value: edge + width)
            return [0, start, start, end, end, 1]
        }

        func draw(_ sweep: LevelSweep, at now: CFTimeInterval) {
            let target = stops(at: sweep.to)
            for layer in isDisc ? [gradient, mask] : [gradient] {
                layer.locations = target
                guard sweep.start + sweep.duration > now, sweep.duration > 0 else {
                    layer.removeAnimation(forKey: "level")
                    continue
                }
                let move = CABasicAnimation(keyPath: "locations")
                move.fromValue = stops(at: sweep.from); move.toValue = target
                move.duration = sweep.duration; move.beginTime = layer.convertTime(sweep.start, from: nil)
                move.timingFunction = CAMediaTimingFunction(controlPoints: 1/3, 0, 2/3, 1)
                move.fillMode = .backwards
                layer.add(move, forKey: "level")
            }
        }
    }

    private static let lineCutoff = levelHeight(0.99)
    private static let compressPaths = ["M4.1 12h15.8", "M7 3l5 4 5-4", "M7 21l5-4 5 4"].map(TaskGlyphArt.svg)

    private func removeWater() {
        water?.gradient.removeFromSuperlayer()
        discPaint.mask = nil
        water = nil
    }

    private func applyLevel(_ input: Input, face: Face, fillEnd: CFTimeInterval? = nil) {
        let previous = Self.faces[input.id], now = CACurrentMediaTime()
        var memory = FaceMemory(owner: self, face: face, seen: now)
        var released = previous?.releasedHeight
        if previous?.face == .compacting, face != .compacting, let level = previous?.level {
            let scale = water?.gradient.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? 1
            released = level.displayed(at: now) * scale
        }
        defer { Self.faces[input.id] = memory }
        guard face.supportsLevel, let fraction = input.contextFraction else {
            if face.isWorking, input.compactingSince == nil { memory.releasedHeight = released }
            if water != nil {
                removeWater()
                orb.colors = [input.color.copy(alpha: 0.32) ?? input.color, input.color.copy(alpha: 0.1) ?? input.color]
                if face.isSolid { setDiscColors(for: face, color: input.color, animate: false) }
            }
            return
        }

        let target = Self.levelHeight(fraction)
        var sweep = LevelSweep(from: target, to: target, start: now, duration: 0)
        if motion, let fillEnd {
            // The normal disc finishes filling from the ring before its waterline appears.
            sweep = LevelSweep(from: 1, to: target, start: fillEnd, duration: 0.5)
        } else if motion, face.isWorking, let released {
            sweep = LevelSweep(from: released, to: target, start: now, duration: 0.9)
        } else if motion, let previous, previous.face.isSolid == face.isSolid, let last = previous.level {
            sweep = last.to == target ? last : LevelSweep(from: last.displayed(at: now), to: target, start: now, duration: 0.5)
        }
        memory.level = sweep
        if water?.isDisc != face.isSolid {
            removeWater()
            let next = ContextWater(disc: face.isSolid, downward: drawsDownward)
            if face.isSolid {
                disc.insertSublayer(next.gradient, below: discPaint)
                discPaint.mask = next.mask
                setDiscColors(for: face, color: input.color, animate: false)
            } else { orb.addSublayer(next.gradient) }
            water = next
        }
        if !face.isSolid { orb.colors = nil }
        water?.setColors(input.color, face: face)
        water?.draw(sweep, at: now)
    }

    /// All four parts share the start signal's phase, including a row rebuilt
    /// mid-press. Only Core Animation evaluates the repeating motion.
    private func refreshPress(live: Bool, now: CFTimeInterval) {
        guard let water, !water.isDisc else { return }
        let layer = water.gradient
        guard live, let since = input?.compactingSince, glyphParts.count == 3 else {
            if water.pressStart != nil {
                layer.removeAnimation(forKey: "press"); layer.removeAnimation(forKey: "density")
                for part in glyphParts { part.layer.removeAnimation(forKey: "press") }
                water.pressStart = nil
            }
            return
        }
        guard water.pressStart != since || layer.animation(forKey: "press") == nil || glyphParts[1].layer.animation(forKey: "press") == nil else { return }
        water.pressStart = since
        let period = 2.4
        let start = now - max(0, -since.timeIntervalSinceNow).truncatingRemainder(dividingBy: period)
        func press(_ target: CALayer, _ path: String, from: Any, to: Any, key: String = "press") {
            let animation = CABasicAnimation(keyPath: path)
            animation.fromValue = from; animation.toValue = to
            animation.duration = period / 2; animation.autoreverses = true; animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.445, 0.05, 0.55, 0.95)
            animation.beginTime = target.convertTime(start, from: nil)
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            target.add(animation, forKey: key)
        }
        let down = drawsDownward ? 1.3 : -1.3
        press(glyphParts[1].layer, "transform.translation.y", from: 0, to: down)
        press(glyphParts[2].layer, "transform.translation.y", from: 0, to: -down)
        press(layer, "transform.scale.y", from: 1, to: 0.95)
        if let colors = layer.colors as? [CGColor] {
            var dense = colors
            dense[1] = colors[1].copy(alpha: 0.52) ?? colors[1]
            press(layer, "colors", from: colors, to: dense, key: "density")
        }
    }

    // MARK: Motion

    /// Looping motion by lifecycle mode and face. The comet turns while the
    /// request works without an estimate; light runs along a reported arc
    /// while it works; during a long step the stretch past its head breathes;
    /// a waiting request breathes; a request waiting for the user or an ended
    /// one keeps still. A working glyph lights its parts in turn. Loops share
    /// the media clock, so a rebuilt row's motion stays where the old one was.
    private func updateLoops() {
        guard !applying else { return }
        let now = CACurrentMediaTime()
        let live = motion && window != nil && !fading
        let compacting = input?.drawingFace == .compacting
        let ringLive = live && !compacting && !container.isHidden && !(input?.drawingFace?.isSolid ?? false)
        Self.withoutActions {
            // The comet shows while it can turn; otherwise a still circle stands in.
            showComet(ringLive && pendingShown && (mode == .working || mode == .longStep))
            let period: Double? = ringLive && pendingShown && (mode == .working || mode == .longStep)
                ? (mode == .longStep ? Self.longStepPeriod : Self.workingPeriod) : nil
            if period != spinningPeriod {
                // Stopping keeps the comet where it is, so a closing one fades in place.
                if spinningPeriod != nil { pending.transform = rotation(currentSpinAngle(now)) }
                pending.removeAnimation(forKey: "spin")
                spinningPeriod = period
                if let period {
                    let phase = currentSpinAngle(now), turn = CABasicAnimation(keyPath: "transform.rotation.z")
                    turn.fromValue = spinSign * phase; turn.toValue = spinSign * (phase + 2 * .pi)
                    turn.duration = period; turn.repeatCount = .infinity
                    turn.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
                    pending.add(turn, forKey: "spin")
                }
            }
            let travel = ringLive && !pendingShown && !dim && mode == .working && targetFraction > 0.04 && targetFraction < 0.9995
            let wantedFlow = travel ? targetFraction : nil
            if wantedFlow != flowFraction {
                flowFraction = wantedFlow
                flowLight.refresh(wantedFlow.map { (0, $0) }, live: wantedFlow != nil, now: now)
            }
            showStep(stepWanted, breathing: ringLive)
            // The comet's circle breathes until the first estimate, the arc after it.
            let breath: CALayer? = !ringLive || mode != .waiting ? nil : pendingShown ? pending : arcGroup
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
            // A working glyph lights its parts in turn.
            refreshPress(live: live && compacting, now: now)
            let rhythms = live && !compacting && (input?.drawingFace?.isWorking ?? false)
            if rhythms != rhythmsRunning {
                rhythmsRunning = rhythms
                for part in glyphParts where part.rhythm != nil {
                    part.layer.removeAnimation(forKey: "rhythm"); part.layer.opacity = 1
                    if rhythms, let rhythm = part.rhythm { part.layer.add(rhythmAnimation(rhythm, now: now), forKey: "rhythm") }
                }
            }
        }
    }

    /// The comet while it turns; a still circle while waiting or without motion.
    private func showComet(_ shown: Bool) {
        for layer in [cometTrack, cometGlow, comet, cometHead] as [CALayer] { layer.isHidden = !shown }
        halo.opacity = shown ? 0 : 1
    }
    /// The stretch past the head during a long step with an estimate.
    private var stepWanted: Bool {
        input?.drawingFace != .compacting && input?.state == .reported && !pendingShown && mode == .longStep && targetFraction < 0.9995 && !(input?.drawingFace?.isSolid ?? false)
    }
    private func showStep(_ shown: Bool, breathing: Bool) {
        let live = shown && breathing
        if live != (step.animation(forKey: "breath") != nil) {
            step.removeAnimation(forKey: "breath")
            if live { step.add(Self.stepBreath(on: step, now: CACurrentMediaTime()), forKey: "breath") }
        }
        step.opacity = shown ? 0.55 : 0
    }
    /// The stretch past the head breathes on the shared clock during a long step.
    static func stepBreath(on layer: CALayer, now: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.2, 0.85, 0.2]; animation.keyTimes = [0, 0.5, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = stepPeriod; animation.repeatCount = .infinity
        animation.beginTime = layer.convertTime(now - now.truncatingRemainder(dividingBy: stepPeriod), from: nil)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return animation
    }
    /// One run of light from the arc's start out through its head, then a
    /// rest, on the shared clock; the band never passes the head.
    private func rhythmAnimation(_ rhythm: TaskGlyphArt.Rhythm, now: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = rhythm.values; animation.keyTimes = rhythm.times.map { NSNumber(value: $0) }
        if rhythm != .blink { animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: rhythm.values.count - 1) }
        animation.duration = rhythm.period; animation.repeatCount = .infinity
        var begin = now - now.truncatingRemainder(dividingBy: rhythm.period) + rhythm.offset
        if begin > now { begin -= rhythm.period }
        animation.beginTime = glyphHost.convertTime(begin, from: nil)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return animation
    }
    /// Ends the breath and leaves the element at its resting opacity.
    private func stopBreathing() {
        guard let target = breathingTarget else { return }
        target.removeAnimation(forKey: "breath")
        if target === pending { pending.opacity = pendingShown ? Self.pendingOpacity : 0 }
        else { arcGroup.opacity = dim ? Self.staleOpacity : 1 }
        breathingTarget = nil
    }
    private func easeOutOfBreath(_ layer: CALayer, high: Double, to target: Double, now: CFTimeInterval) {
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
    /// The comet's turn: the task's own clock, or the shared one before it has one.
    private func currentSpinAngle(_ time: CFTimeInterval) -> Double {
        if let taskID, let memory = Self.memories[taskID] { return memory.spinAngle(at: time) }
        return Memory(state: .pending, color: ink, seen: time).spinAngle(at: time)
    }

    // MARK: Drawing

    private var cometTail: Double { mode == .longStep ? Self.longStepTail : Self.workingTail }
    /// The comet fades from its head back along its tail. A conic gradient's
    /// location grows counterclockwise in a y-up tree, so the head is its first
    /// stop there and its last when the tree draws downwards; either way the
    /// opaque head is a hard edge that leads the clockwise turn.
    private func cometStops(tail: Double, alpha: CGFloat) -> (colors: [CGColor], locations: [NSNumber]) {
        let head = ink.copy(alpha: alpha * (ink.alpha)) ?? ink, clear = ink.copy(alpha: 0) ?? ink
        if drawsDownward { return ([clear, clear, head], [0, NSNumber(value: 1 - tail), 1]) }
        return ([head, clear, clear], [0, NSNumber(value: tail), 1])
    }
    private func applyCometStops(tail: Double) {
        for (gradient, alpha) in [(comet, 1.0), (cometGlow, 1.0)] {
            gradient.removeAnimation(forKey: "launch"); gradient.removeAnimation(forKey: "tail")
            let stops = cometStops(tail: tail, alpha: alpha)
            gradient.colors = stops.colors; gradient.locations = stops.locations
        }
    }
    private func animateCometStops(to tail: Double, duration: Double, timing: CAMediaTimingFunction, key: String) {
        for gradient in [comet, cometGlow] {
            let shown = (gradient.presentation() ?? gradient).locations
            let stops = cometStops(tail: tail, alpha: 1)
            gradient.colors = stops.colors; gradient.locations = stops.locations
            let animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = shown; animation.toValue = stops.locations; animation.duration = duration
            animation.timingFunction = timing
            gradient.add(animation, forKey: key)
        }
    }

    private func setFraction(_ value: Double) {
        for shape in [arc, arcGlow] { shape.removeAnimation(forKey: "sweep"); shape.strokeEnd = value }
        for (band, length) in zip(stepBands, Self.stepLengths) {
            band.removeAnimation(forKey: "sweep"); band.strokeStart = value; band.strokeEnd = min(1, value + length)
        }
    }
    /// Sampled from the same curve `Memory.displayed` evaluates, so a rebuilt
    /// row continues a sweep from the exact displayed value.
    private func sweep(from: Double, to: Double, duration: Double, ease: Ease, start: CFTimeInterval) {
        setFraction(to)
        let length = max(0.01, duration)
        guard start + length > CACurrentMediaTime() else { return }
        let steps = 24, samples = (0...steps).map { from + (to - from) * ease(Double($0) / Double(steps)) }
        let times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        func keyframes(_ path: String, _ values: [Double]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: path)
            animation.values = values; animation.keyTimes = times; animation.duration = length
            animation.beginTime = arc.convertTime(start, from: nil); animation.fillMode = .backwards
            return animation
        }
        for shape in [arc, arcGlow] { shape.add(keyframes("strokeEnd", samples), forKey: "sweep") }
        for (band, bandLength) in zip(stepBands, Self.stepLengths) {
            let group = CAAnimationGroup()
            group.animations = [keyframes("strokeStart", samples), keyframes("strokeEnd", samples.map { min(1, $0 + bandLength) })]
            group.duration = length; group.beginTime = arc.convertTime(start, from: nil); group.fillMode = .backwards
            group.animations?.forEach { $0.beginTime = 0 }
            band.add(group, forKey: "sweep")
        }
    }
    private func fade(wasStale: Bool, stale: Bool, animate: Bool) {
        let target = stale ? Self.staleOpacity : 1
        guard animate, wasStale != stale else { arcGroup.removeAnimation(forKey: "opacity"); arcGroup.opacity = target; return }
        arcGroup.opacity = target
        fadeOpacity(arcGroup, from: wasStale ? Double(Self.staleOpacity) : 1, to: Double(target), duration: stale ? 0.6 : 0.2, timing: .easeInEaseOut)
    }
    private func fadeOpacity(_ layer: CALayer, from: Double, to: Double, duration: Double, timing: CAMediaTimingFunctionName = .linear,
                             delay: Double = 0, key: String = "opacity") {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        animation.beginTime = layer.convertTime(CACurrentMediaTime() + delay, from: nil)
        animation.fillMode = .backwards
        layer.add(animation, forKey: key)
    }
    private func animatePath(_ shape: CAShapeLayer, from: CGPath, to: CGPath, duration: Double, delay: Double, key: String) {
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        animation.beginTime = shape.convertTime(CACurrentMediaTime() + delay, from: nil); animation.fillMode = .backwards
        shape.add(animation, forKey: key)
    }
    private func setInk(_ color: CGColor, from previous: CGColor?, animate: Bool) {
        ink = color
        // The stretch past the head is a faint share of the ink.
        func faint(_ ink: CGColor) -> CGColor { ink.copy(alpha: 0.38 * ink.alpha) ?? ink }
        for shape in [ghost, arc, arcGlow] + stepBands {
            let isStep = stepBands.contains(shape)
            if animate, let previous, previous != color {
                let animation = CABasicAnimation(keyPath: "strokeColor")
                animation.fromValue = isStep ? faint(previous) : previous; animation.toValue = isStep ? faint(color) : color
                animation.duration = 0.25
                shape.add(animation, forKey: "ink")
            }
            shape.strokeColor = isStep ? faint(color) : color
        }
        halo.strokeColor = color.copy(alpha: 0.5 * color.alpha) ?? color
        cometHead.fillColor = color
        let stops = cometStops(tail: cometTail, alpha: 1)
        for gradient in [comet, cometGlow] where gradient.animation(forKey: "launch") == nil && gradient.animation(forKey: "tail") == nil {
            gradient.colors = stops.colors
        }
    }
    private func circle(radius: CGFloat) -> CGPath {
        let side = Self.diameter
        return CGPath(ellipseIn: CGRect(x: side / 2 - radius, y: side / 2 - radius, width: 2 * radius, height: 2 * radius), transform: nil)
    }
    /// The disc's mask: its outline with a hole of the given radius.
    private func annulus(hole: CGFloat) -> CGPath {
        let side = Self.discSide, path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        path.addEllipse(in: CGRect(x: side / 2 - hole, y: side / 2 - hole, width: 2 * hole, height: 2 * hole))
        return path
    }
    /// The arc starts at the top and runs clockwise on screen.
    private func arcPath() -> CGPath {
        let center = CGPoint(x: Self.diameter / 2, y: Self.diameter / 2), path = CGMutablePath()
        if drawsDownward { path.addArc(center: center, radius: Self.radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false) }
        else { path.addArc(center: center, radius: Self.radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true) }
        return path
    }
    /// Clockwise on screen whichever way the layer tree draws.
    private var spinSign: Double { drawsDownward ? 1 : -1 }
    private func rotation(_ angle: Double) -> CATransform3D { CATransform3DMakeRotation(spinSign * angle, 0, 0, 1) }
    private static func lighten(_ color: CGColor, by amount: CGFloat) -> CGColor {
        guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return color }
        return NSColor(srgbRed: rgb.redComponent + (1 - rgb.redComponent) * amount, green: rgb.greenComponent + (1 - rgb.greenComponent) * amount,
                       blue: rgb.blueComponent + (1 - rgb.blueComponent) * amount, alpha: rgb.alphaComponent).cgColor
    }

    private var animatedLayers: [(String, CALayer)] {
        var layers: [(String, CALayer)] = [("icon", icon), ("ring", ringHost), ("container", container), ("pending", pending), ("comet", comet),
            ("comet", cometGlow), ("track", track), ("ghost", ghost), ("arc", arcGroup), ("arc", arc), ("arc", arcGlow), ("step", step),
            ("orb", orb), ("disc", disc), ("disc", discFill), ("disc", discMask)]
        layers += [("flow", flowLight.gradient as CALayer)] + stepBands.map { ("step", $0 as CALayer) } + ripples.map { ("ripple", $0 as CALayer) }
        layers += [("glyph", glyph)] + glyphParts.map { ("glyph", $0.layer) } + leavingGlyphs.map { ("glyph", $0) }
        if let water {
            layers.append(("water", water.gradient))
            if water.isDisc { layers.append(("waterMask", water.mask)) }
        }
        return layers
    }
    /// The animations each layer runs, as `layer.key`; read by tests.
    var animationKeys: Set<String> {
        Set(animatedLayers.flatMap { name, layer in (layer.animationKeys() ?? []).map { name + "." + $0 } })
    }
    /// The arc's resting value and whether any ring shows; read by tests.
    var restingFraction: Double { Double(arc.strokeEnd) }
    var showsRing: Bool { !container.isHidden && !fading }
    /// Whether the face shows a filled disc, and whether a working orb shows; read by tests.
    var showsDisc: Bool { !disc.isHidden && input?.drawingFace?.isSolid == true }
    var showsContextLevel: Bool { water?.gradient.superlayer != nil }
    var showsOrb: Bool { orb.opacity > 0 }
    func sweepBegin() -> CFTimeInterval? { arc.animation(forKey: "sweep")?.beginTime }

    private static func withoutActions(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
    /// Rows that have not been rebuilt for ten minutes are gone for good.
    private static func prune(_ now: CFTimeInterval) {
        if memories.count >= 64 { memories = memories.filter { now - $0.value.seen <= 600 } }
        if faces.count >= 64 { faces = faces.filter { now - $0.value.seen <= 600 } }
    }
}

/// Light travelling a stretch of a ring: a bright head with a soft front,
/// leading a tail that fades away, painted by a conic gradient that turns about
/// the ring's center and seen only through a stroke that moves with it, so it
/// never shows outside the stretch. The head enters at the stretch's start and
/// leaves past its end within `flowTravel`; the light then rests until
/// `flowPeriod` ends, the clock every light in Pacer keeps.
@MainActor final class ArcLight {
    let layer = CALayer()
    /// The light itself; it turns. Read by the animation listings.
    let gradient = CAGradientLayer()
    private let window = CAShapeLayer()
    private let color: NSColor, peak: CGFloat
    /// The tail and the soft front, as shares of the circle.
    static let tail = TaskStatusIconNSView.flowLengths[0], front = 0.025
    private var downward = false
    private var pathTerms: (Double) -> Double = { $0 }
    private var stretch: (start: Double, end: Double)?
    private var running: [Double]?

    init(color: NSColor, peak: CGFloat) {
        self.color = color; self.peak = peak
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        window.fillColor = nil; window.strokeColor = NSColor.black.cgColor; window.lineCap = .butt
        window.strokeStart = 0; window.strokeEnd = 0
        layer.addSublayer(gradient)
        layer.mask = window
        layer.isHidden = true
        restyle()
    }

    /// The seam sits at the top on screen with the head on it; the tail fades
    /// counterclockwise behind it and the front clockwise ahead, whichever way
    /// the layer tree draws (a conic gradient's locations grow with its angle).
    private func restyle() {
        gradient.endPoint = CGPoint(x: 0.5, y: downward ? 0 : 1)
        let tail = Self.tail, front = Self.front
        let fade: [(share: Double, alpha: CGFloat)] = [(0, 1), (0.2, 0.62), (0.5, 0.28), (0.8, 0.08), (1, 0)]
        func ink(_ alpha: CGFloat) -> CGColor { color.withAlphaComponent(peak * alpha).cgColor }
        if downward {
            gradient.colors = [ink(1), ink(0)] + fade.reversed().map { ink($0.alpha) }
            gradient.locations = ([0, front] + fade.reversed().map { 1 - $0.share * tail }).map { NSNumber(value: $0) }
        } else {
            gradient.colors = fade.map { ink($0.alpha) } + [ink(0), ink(1)]
            gradient.locations = (fade.map { $0.share * tail } + [1 - front, 1]).map { NSNumber(value: $0) }
        }
    }

    /// `pathTerms` turns circle shares (clockwise from the top) into the path's
    /// own, for a path that covers only part of the circle.
    func place(frame: CGRect, path: CGPath, lineWidth: CGFloat, downward: Bool, pathTerms: @escaping (Double) -> Double = { $0 }) {
        layer.frame = frame
        window.frame = CGRect(origin: .zero, size: frame.size); window.path = path; window.lineWidth = lineWidth
        // A square covering the diagonal keeps the turning gradient under the whole ring.
        let side = hypot(frame.width, frame.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        self.pathTerms = pathTerms
        guard downward != self.downward else { return }
        self.downward = downward
        restyle()
        if let stretch, running != nil { running = nil; refresh(stretch, live: true) }
    }

    /// Travels `stretch`, in circle shares clockwise from the top; nil, or a
    /// view that is not live, stops it.
    func refresh(_ stretch: (start: Double, end: Double)?, live: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        self.stretch = stretch
        guard live, let stretch, stretch.end > stretch.start else {
            gradient.removeAnimation(forKey: "travel"); window.removeAnimation(forKey: "travel")
            layer.isHidden = true; running = nil
            return
        }
        let key = [stretch.start, stretch.end, downward ? 1 : 0]
        guard running != key || gradient.animation(forKey: "travel") == nil else { return }
        running = key
        layer.isHidden = false
        let period = TaskStatusIconNSView.flowPeriod, travel = TaskStatusIconNSView.flowTravel / period, steps = 36
        let first = stretch.start - Self.front, reach = stretch.end + Self.tail - first
        let sign = downward ? 1.0 : -1.0
        var starts: [NSNumber] = [], ends: [NSNumber] = [], angles: [NSNumber] = [], times: [NSNumber] = []
        for index in 0...steps {
            let head = first + reach * Double(index) / Double(steps)
            starts.append(NSNumber(value: pathTerms(min(stretch.end, max(stretch.start, head - Self.tail)))))
            ends.append(NSNumber(value: pathTerms(min(stretch.end, max(stretch.start, head + Self.front)))))
            angles.append(NSNumber(value: sign * 2 * .pi * head))
            times.append(NSNumber(value: travel * Double(index) / Double(steps)))
        }
        let rest = NSNumber(value: pathTerms(stretch.end))
        starts.append(rest); ends.append(rest); angles.append(angles[steps]); times.append(1)
        let begin = now - now.truncatingRemainder(dividingBy: period)
        func loop(_ animations: [CAAnimation], on target: CALayer) {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = period; group.repeatCount = .infinity
            group.beginTime = target.convertTime(begin, from: nil)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            target.add(group, forKey: "travel")
        }
        let start = CAKeyframeAnimation(keyPath: "strokeStart"), end = CAKeyframeAnimation(keyPath: "strokeEnd")
        start.values = starts; end.values = ends; start.keyTimes = times; end.keyTimes = times
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = angles; turn.keyTimes = times
        // At rest nothing shows.
        window.strokeStart = CGFloat(rest.doubleValue); window.strokeEnd = CGFloat(rest.doubleValue)
        loop([start, end], on: window)
        loop([turn], on: gradient)
    }
    var travels: Bool { gradient.animation(forKey: "travel") != nil }
    /// The window's keyframes, as path shares; read by tests.
    var windowKeyframes: (starts: [Double], ends: [Double])? {
        guard let group = window.animation(forKey: "travel") as? CAAnimationGroup,
              let start = group.animations?.first as? CAKeyframeAnimation, let end = group.animations?.last as? CAKeyframeAnimation else { return nil }
        return ((start.values as? [NSNumber] ?? []).map(\.doubleValue), (end.values as? [NSNumber] ?? []).map(\.doubleValue))
    }
}
