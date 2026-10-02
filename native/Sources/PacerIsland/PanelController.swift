import AppKit
import SwiftUI
import PacerCore

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let model: IslandModel
    private let panel: IslandPanel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        panel.collectionBehavior = model.showInFullscreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces]
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        panel.orderOut(nil)
    }
}
