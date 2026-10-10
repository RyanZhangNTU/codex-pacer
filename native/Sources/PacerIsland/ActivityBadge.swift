import AppKit
import PacerCore
import SwiftUI

/// What the badge core shows while exactly one task is active.
enum ActivityBadgeSingleTask: String, CaseIterable {
    case stage, count
    static let defaultsKey = "compactSingleTask"
    init(defaults: UserDefaults = .standard) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .stage
    }
    var label: String { L10n.text("layout.single_task." + rawValue) }
}

/// One collapsed status: the core says what or how many, the orbit says work
/// is running, the solid fill says it needs you, and a corner mark keeps an
/// unread ending visible beside running work.
struct HeaderActivity: Equatable {
    enum Core: Equatable { case idle, symbol(String), count(Int) }
    enum Ending: Equatable {
        case completed(AgentProvider), interrupted, failed
        var symbol: String {
            switch self {
            case .completed: StatusSymbols.complete
            case .interrupted: StatusSymbols.interrupted
            case .failed: StatusSymbols.failed
            }
        }
        var tint: Color {
            switch self {
            case .completed(let provider): provider.tint
            case .interrupted: PacerPalette.paused
            case .failed: PacerPalette.danger
            }
        }
    }
    var core: Core
    var activeCount: Int
    /// Running task counts by provider; empty when nothing is running.
    var orbit: [AgentProvider: Int]
    var attention: PendingAttentionRequest.Kind?
    var ending: Ending?

    /// With nothing active or waiting, the ending itself occupies the core.
    var endingIsCore: Bool { ending != nil && activeCount == 0 && attention == nil }
    var showsEndingMark: Bool { ending != nil && !endingIsCore }
}

struct ActivityBadge: View {
    let activity: HeaderActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripples = 0
    @State private var blooms = 0
    private static let attentionInk = Color(red: 0.26, green: 0.15, blue: 0.02)

    var body: some View {
        coreView
            .frame(minWidth: 15, minHeight: 15)
            .padding(.horizontal, isWide ? 3.5 : 0)
            .background { fill }
            .overlay { ripple }
            .padding(2.5)
            .frame(minWidth: 20, minHeight: 20)
            .background {
                if !activity.orbit.isEmpty {
                    ActivityOrbit(segments: AgentProvider.allCases.compactMap { provider in
                        activity.orbit[provider].map { ActivityOrbit.Segment(color: NSColor(provider.tint), weight: $0) }
                    }, animates: !reduceMotion)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if activity.showsEndingMark, let ending = activity.ending {
                    Circle().fill(ending.tint).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.85), lineWidth: 1.5))
                        .offset(x: 1, y: -1)
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
            .fixedSize()
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: activity)
            .onChange(of: activity.attention) { previous, current in
                if previous == nil, current != nil, !reduceMotion { ripples += 1 }
            }
            .onChange(of: activity.ending) { previous, current in
                if previous == nil, current != nil, !reduceMotion { blooms += 1 }
            }
    }

    private var isWide: Bool {
        if case .count(let count) = activity.core { return count >= 10 }
        return false
    }
    private var ink: Color {
        if activity.attention != nil { return Self.attentionInk }
        if activity.endingIsCore, let ending = activity.ending { return ending.tint }
        return PacerPalette.primary
    }
    @ViewBuilder private var coreView: some View {
        switch activity.core {
        case .idle:
            Circle().fill(PacerPalette.tertiary).frame(width: 5, height: 5)
        case .symbol(let name):
            Image(systemName: StatusTile.tileSymbol(name)).font(.system(size: 9, weight: .bold))
                .foregroundStyle(ink).contentTransition(.symbolEffect(.replace))
        case .count(let count):
            Text(count > 99 ? "99+" : String(count)).font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(ink).contentTransition(.numericText(value: Double(count)))
        }
    }
    @ViewBuilder private var fill: some View {
        if activity.attention != nil {
            Capsule().fill(PacerPalette.attention)
        } else if activity.endingIsCore, let ending = activity.ending {
            Capsule().fill(ending.tint.opacity(0.2)).overlay(Capsule().strokeBorder(ending.tint.opacity(0.45), lineWidth: 0.5))
        }
    }
    /// Two pings when attention arrives, then a steady solid fill.
    private var ripple: some View {
        Capsule().stroke(PacerPalette.attention, lineWidth: 1.5)
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

/// A comet that circles the badge while work runs. Core Animation drives it in
/// the render server, so the island does not re-render SwiftUI every frame; it
/// pauses while the window is occluded and stays a static ring with Reduce Motion.
struct ActivityOrbit: NSViewRepresentable {
    struct Segment: Equatable {
        let color: NSColor
        let weight: Int
    }
    let segments: [Segment]
    let animates: Bool

    func makeNSView(context: Context) -> ActivityOrbitView { ActivityOrbitView() }
    func updateNSView(_ view: ActivityOrbitView, context: Context) { view.update(segments: segments, animates: animates) }
}

final class ActivityOrbitView: NSView {
    private static let lineWidth: CGFloat = 1.5
    private let track = CAShapeLayer()
    private let ring = CALayer()
    private let ringMask = CAShapeLayer()
    private let comet = CAGradientLayer()
    private var segments: [ActivityOrbit.Segment] = []
    private var animates = true
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        track.lineWidth = Self.lineWidth
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = Self.lineWidth
        ring.mask = ringMask
        comet.type = .conic
        comet.startPoint = CGPoint(x: 0.5, y: 0.5)
        comet.endPoint = CGPoint(x: 0.5, y: 0)
        ring.addSublayer(comet)
        layer?.addSublayer(track)
        layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(segments: [ActivityOrbit.Segment], animates: Bool) {
        guard segments != self.segments || animates != self.animates else { return }
        self.segments = segments; self.animates = animates
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyColors()
        CATransaction.commit()
        refreshAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let inset = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let radius = min(inset.width, inset.height) / 2
        let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for shape in [track, ringMask] { shape.frame = bounds; shape.path = path }
        ring.frame = bounds
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
                    Task { @MainActor in self?.refreshAnimation() }
                }
        }
        refreshAnimation()
    }

    /// Each provider gets its own comet, evenly spaced, with length in
    /// proportion to its running tasks. A conic gradient's location grows
    /// counterclockwise, so each opaque head sits at its comet's lowest
    /// location and leads the clockwise orbit. Without motion the shares fill
    /// the whole ring instead.
    private func applyColors() {
        let total = Double(max(1, segments.reduce(0) { $0 + $1.weight }))
        let span = segments.count > 1 ? 0.5 : 0.34
        var colors: [CGColor] = [], locations: [Double] = []
        var start = 0.0
        for (index, segment) in segments.enumerated() {
            let share = Double(segment.weight) / total
            if animates {
                let head = Double(index) / Double(segments.count), tail = head + span * share
                colors += [segment.color.cgColor, segment.color.withAlphaComponent(0).cgColor, NSColor.clear.cgColor]
                locations += [head, tail, tail + 0.001]
            } else {
                colors += [segment.color.withAlphaComponent(0.75).cgColor, segment.color.withAlphaComponent(0.75).cgColor]
                locations += [start, start + share]
                start += share
            }
        }
        comet.colors = colors
        comet.locations = locations.map { NSNumber(value: $0) }
    }

    private func refreshAnimation() {
        // Occlusion pauses the orbit; a window whose state is not computed yet still starts it.
        guard animates, let window, window.occlusionState.contains(.visible) || !window.isVisible, !segments.isEmpty else {
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
}
