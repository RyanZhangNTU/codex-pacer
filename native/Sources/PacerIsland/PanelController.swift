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
    private let presentation: IslandPresentation
    private let hosting: NSHostingView<IslandView>
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var displayLink: CADisplayLink?
    private var motion: IslandTransition?
    private var motionRevision = 0

    init(model: IslandModel) {
        self.model = model
        let presentation = IslandPresentation()
        self.presentation = presentation
        hosting = NSHostingView(rootView: IslandView(model: model, presentation: presentation))
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Codex Pacer"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        model.onLayoutChange = { [weak self] in self?.layout() }
        model.onFocusRequested = { [weak self] in
            guard let self, !self.model.interactionSuspended else { return }
            self.panel.makeKey()
        }
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
        guard !model.interactionSuspended else { return }
        model.pinned = true
        model.setExpanded(true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func setUpdatePresentationActive(_ active: Bool) {
        guard active != model.interactionSuspended else { return }
        model.setInteractionSuspended(active)
        panel.ignoresMouseEvents = active
        // A normal-level window is constrained below the menu bar. Restore the
        // status-bar level before laying out the island at the screen's top edge.
        panel.level = active ? .normal : .statusBar
        // Snap closed before runModal; animation timers may not advance there.
        layout(animated: false)
        if active {
            panel.resignKey()
            panel.orderBack(nil)
        } else {
            // Return only the collapsed island without stealing updater focus.
            panel.orderFrontRegardless()
        }
    }

    private func layout(animated: Bool = true) {
        if !model.expanded { panel.resignKey() }
        let selected = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == model.displayID
        }
        guard let screen = selected ?? NSScreen.screens.first else { return }
        let demoNotch = model.isDemo && CommandLine.arguments.contains("--demo-notch")
        let hardwareNotchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hardwareNotchWidth = max(0, right.minX - left.maxX)
        } else { hardwareNotchWidth = 0 }
        let mode: IslandDisplayMode = demoNotch ? .notch : model.displayMode
        let layout = mode.layout(safeAreaTop: demoNotch ? 36 : screen.safeAreaInsets.top,
            hardwareNotchWidth: demoNotch ? 180 : hardwareNotchWidth)
        if model.isAttached != layout.attached { model.isAttached = layout.attached }
        if model.notchWidth != layout.notchWidth { model.notchWidth = layout.notchWidth }
        if model.topHeight != layout.topHeight { model.topHeight = layout.topHeight }
        let widths = model.widthSettings
        let collapsedWidth = widths.desiredWidth(expanded: false, notchWidth: layout.notchWidth,
            leading: model.measuredHeaderLeading, trailing: model.measuredHeaderTrailing)
        let expandedWidth = widths.desiredWidth(expanded: true, notchWidth: layout.notchWidth,
            leading: model.measuredHeaderLeading, trailing: model.measuredHeaderTrailing,
            contentWidth: model.measuredContentWidth)
        let frame = IslandGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, notchWidth: layout.notchWidth,
            topHeight: model.topHeight, expanded: model.expanded, attached: layout.attached,
            contentHeight: model.panelContentHeight, desiredWidth: model.expanded ? expandedWidth : collapsedWidth)
        let expandedFrame = IslandGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, notchWidth: layout.notchWidth,
            topHeight: model.topHeight, expanded: true, attached: layout.attached, contentHeight: model.panelContentHeight,
            desiredWidth: expandedWidth)
        if presentation.canvas != expandedFrame.size { presentation.canvas = expandedFrame.size }
        panel.collectionBehavior = model.showInFullscreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces]
        let current = presentation.sample
        let hasBlackHeader = layout.attached && model.appearance == .liquidGlass
        let target = IslandTransition.Sample.resting(at: frame, expanded: model.expanded, hasBlackHeader: hasBlackHeader)
        let sameAnchor = abs(current.frame.maxY - frame.maxY) < 1 && abs(current.frame.midX - frame.midX) < 1
        if animated && sameAnchor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Quota/settings updates must not restart an unchanged destination.
            if let motion, motion.target.frame == frame, motion.target.expansion == target.expansion,
               motion.hasBlackHeader == hasBlackHeader { return }
            if current.finished, current.frame == frame, current.expansion == target.expansion,
               current.blackOpacity == target.blackOpacity {
                stopMotion(); return
            }
            motion = IslandTransition(from: current, to: frame, opening: model.expanded,
                                      hasBlackHeader: hasBlackHeader, start: CACurrentMediaTime())
            motionRevision += 1
            if displayLink == nil {
                let link = screen.displayLink(target: self, selector: #selector(step(_:)))
                let refreshRate = Float(max(30, screen.maximumFramesPerSecond))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, refreshRate),
                                                                maximum: refreshRate, preferred: refreshRate)
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        } else {
            stopMotion()
            apply(target)
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard var motion else { stopMotion(); return }
        let revision = motionRevision
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply(motion.target)
            if revision == motionRevision { stopMotion() }
            return
        }
        let sample = motion.sample(at: link.targetTimestamp)
        self.motion = motion
        apply(sample)
        if sample.finished, revision == motionRevision { stopMotion() }
    }

    private func apply(_ sample: IslandTransition.Sample) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withTransaction(transaction) {
            presentation.sample = sample
            let frame = IslandGeometry.windowFrame(sample.frame)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            // Resolve SwiftUI geometry in the same frame without forcing a
            // second synchronous window redraw or implicit glass animation.
            hosting.layoutSubtreeIfNeeded()
            // A transparent window caches its silhouette. Update it with the
            // shell, not just at rest, which makes the floating shadow pop.
            panel.invalidateShadow()
        }
        CATransaction.commit()
    }

    private func stopMotion() {
        motionRevision += 1
        displayLink?.invalidate(); displayLink = nil; motion = nil
    }

    func stop() {
        stopMotion()
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        panel.orderOut(nil)
    }
}
