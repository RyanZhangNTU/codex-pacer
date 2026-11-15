import AppKit
import PacerCore
import PacerMacSupport
import SwiftUI

/// Points at the button the progress ring's setup asks the user to click,
/// right over the module's app: a pulsing ring around it and a bubble that
/// says what to do. It reads the button's place every half second, hides
/// while the app is not in front, and stops once the step is done, after
/// three minutes or when the user says so. It never clicks for the user.
@MainActor final class HarnessPointer {
    private weak var model: IslandModel?
    private(set) var provider: AgentProvider?
    private var timer: Timer?
    private var started = Date()
    /// Looks in a row that found no button while the app was in front.
    private var misses = 0
    static let missLimit = 15
    private var scanning = false
    private let ring = PointerPanel(clickThrough: true)
    private let bubble = PointerPanel(clickThrough: false)
    static let lifetime: TimeInterval = 180
    /// The module's running app and the card's current step; checks replace them.
    var application: (AgentProvider) -> NSRunningApplication? = { MacLocalHarnessApplication.running(provider: $0) }
    var guide: ((AgentProvider) -> HarnessProgressGuide?)?
    var isShowing: Bool { ring.isVisible }

    init(model: IslandModel) { self.model = model }

    private func currentGuide(_ provider: AgentProvider) -> HarnessProgressGuide? {
        guide?(provider) ?? model?.progressGuide(provider)
    }

    func start(_ provider: AgentProvider) {
        stop()
        self.provider = provider
        started = Date(); misses = 0
        model?.setHarnessPointerMissing(provider, false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        hide()
        provider = nil
    }

    private func hide() {
        ring.orderOut(nil); bubble.orderOut(nil)
    }

    private func tick() {
        guard let provider, currentGuide(provider)?.picture != nil, Date().timeIntervalSince(started) < Self.lifetime,
              let app = application(provider) else { return stop() }
        // Only over the app itself; it comes back when the app does.
        guard app.isActive else { return hide() }
        guard !scanning else { return }
        scanning = true
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            let result = MacHarnessPointerScan.scan(pid: pid)
            await MainActor.run { [weak self] in self?.apply(result, provider: provider) }
        }
    }

    private func apply(_ result: MacHarnessPointerScan.Result?, provider: AgentProvider) {
        scanning = false
        guard let model, self.provider == provider else { return }
        // Pacer's entry showing means the custom connectors are open: the ring moves to Trust.
        if let view = result?.view { model.reportHarnessView(provider, view) }
        guard let guide = currentGuide(provider), let picture = guide.picture else { return stop() }
        let target = picture == .trust ? result?.trust : result?.customConnector
        guard application(provider)?.isActive == true else { return hide() }
        guard let target else {
            hide()
            // Fifteen looks in a row with the app in front: the card says it wasn't found, and pointing ends.
            misses += 1
            if misses >= Self.missLimit { model.setHarnessPointerMissing(provider, true); stop() }
            return
        }
        misses = 0
        show(around: Self.cocoaRect(target), text: guide.pointerText ?? "")
    }

    /// Accessibility counts from the top left of the main display; windows from its bottom left.
    static func cocoaRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func show(around target: CGRect, text: String) {
        let pad: CGFloat = 16
        ring.show(PointerRing(), frame: target.insetBy(dx: -pad, dy: -pad))
        let content = PointerBubble(text: text, stop: { [weak self] in self?.stop() })
        let size = NSHostingView(rootView: content).fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(target) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Under the button, its right edge lined up; above it when there is no room below.
        var origin = CGPoint(x: target.maxX - size.width + 12, y: target.minY - 10 - size.height)
        if origin.y < screen.minY { origin.y = target.maxY + 10 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        bubble.show(content, frame: CGRect(origin: origin, size: size))
    }
}

/// A borderless panel over every app that never takes focus; the ring's
/// lets clicks through to the button under it.
private final class PointerPanel: NSPanel {
    init(clickThrough: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .statusBar
        ignoresMouseEvents = clickThrough
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ view: some View, frame: CGRect) {
        if contentView == nil || frame.size != self.frame.size { contentView = NSHostingView(rootView: AnyView(view)) }
        else { (contentView as? NSHostingView<AnyView>)?.rootView = AnyView(view) }
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}

/// A ring that pulses outward, still when Reduce Motion is on.
struct PulsingRing: View {
    var cornerRadius: CGFloat = 9
    var lineWidth: CGFloat = 2.5
    @Environment(\.pacerAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.strokeBorder(accent, lineWidth: lineWidth)
            .background {
                if !reduceMotion {
                    shape.stroke(accent.opacity(pulsing ? 0 : 0.55), lineWidth: pulsing ? 12 : 2)
                        .scaleEffect(pulsing ? 1.08 : 1)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulsing = true }
            }
            .accessibilityHidden(true)
    }
}

private struct PointerRing: View {
    // 10 points outside the button, inside a panel 16 points larger on each side.
    var body: some View { PulsingRing(cornerRadius: 12, lineWidth: 3).padding(6).pacerAccent(PacerAccent.current) }
}

/// What to click, and the way to stop pointing.
private struct PointerBubble: View {
    let text: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            (Text("Pacer  ").fontWeight(.bold).foregroundColor(.white.opacity(0.75)) + Text(text).fontWeight(.semibold).foregroundColor(.white))
                .font(.system(size: 12.5)).fixedSize()
            Button(L10n.text("progress_guide.pointer.stop"), action: stop)
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.18), in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(PacerAccent.current.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .padding(10)
    }
}
