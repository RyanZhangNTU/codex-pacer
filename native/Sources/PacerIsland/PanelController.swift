import AppKit
import SwiftUI
import PacerCore
import QuartzCore

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject {
    private let model: IslandModel
    private let panel: IslandPanel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var displayLink: CADisplayLink?
    private var motion: IslandMotion?

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Codex Pacer Island"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        model.onLayoutChange = { [weak self] in self?.layout() }
        model.onFocusRequested = { [weak self] in self?.panel.makeKey() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        })
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.model.close()
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, event.window === self?.panel { self?.model.close(); return nil }
            return event
        }) { monitors.append(monitor) }
        layout(animated: false)
        panel.orderFrontRegardless()
        if model.pinned { panel.makeKey() }
    }

    func show() {
        model.pinned = true
        model.setExpanded(true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func layout(animated: Bool = true) {
        if !model.expanded { panel.resignKey() }
        let selected = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == model.displayID
        }
        guard let screen = selected ?? NSScreen.screens.first else { return }
        let hasNotch = screen.safeAreaInsets.top > 0 && !model.prefersFloating
        let notchWidth: CGFloat
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else { notchWidth = 0 }
        model.notchWidth = notchWidth
        model.topHeight = hasNotch ? max(32, screen.safeAreaInsets.top) : 38
        let frame = IslandGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, notchWidth: notchWidth,
            topHeight: model.topHeight, expanded: model.expanded, attached: hasNotch,
            contentHeight: model.panelContentHeight)
        let expandedFrame = IslandGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, notchWidth: notchWidth,
            topHeight: model.topHeight, expanded: true, attached: hasNotch, contentHeight: model.panelContentHeight)
        model.expandedCanvas = expandedFrame.size
        panel.collectionBehavior = model.showInFullscreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces]
        if panel.frame == frame, model.displayedExpansion == (model.expanded ? 1 : 0),
           model.contentVisibility == (model.expanded ? 1 : 0) {
            stopMotion(); return
        }
        let sameAnchor = abs(panel.frame.maxY - frame.maxY) < 1 && abs(panel.frame.midX - frame.midX) < 1
        if animated && sameAnchor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let distance = abs(panel.frame.height - frame.height) / max(1, expandedFrame.height - model.topHeight)
            motion = IslandMotion(from: panel.frame, to: frame, expansion: model.displayedExpansion,
                content: model.contentVisibility, opening: model.expanded, start: CACurrentMediaTime(), distance: distance)
            if displayLink == nil {
                let link = screen.displayLink(target: self, selector: #selector(step(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        } else {
            stopMotion()
            apply(frame: frame, expansion: model.expanded ? 1 : 0, content: model.expanded ? 1 : 0)
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let motion else { stopMotion(); return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let end = motion.sample(at: .greatestFiniteMagnitude)
            apply(frame: end.frame, expansion: end.expansion, content: end.content)
            stopMotion(); return
        }
        let sample = motion.sample(at: link.targetTimestamp)
        apply(frame: sample.frame, expansion: sample.expansion, content: sample.content)
        if sample.finished { stopMotion(); panel.invalidateShadow() }
    }

    private func apply(frame: CGRect, expansion: Double, content: Double) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.displayedExpansion = expansion
            model.contentVisibility = content
            panel.setFrame(frame, display: true)
        }
    }

    private func stopMotion() {
        displayLink?.invalidate(); displayLink = nil; motion = nil
    }

    func stop() {
        stopMotion()
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        panel.orderOut(nil)
    }
}
