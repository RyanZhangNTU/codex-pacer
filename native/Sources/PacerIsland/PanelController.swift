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
    /// The point the current frame keeps fixed; set before each frame is applied.
    private var anchor = IslandGeometry.Anchor.topCenter
    /// The collapsed bar's two shapes from the last layout, for Free Move.
    private var headerSize = CGSize(width: 300, height: 38)
    private var stripSize = CGSize(width: IslandGeometry.stripWidth, height: 132)
    private struct Move {
        /// The pointer's place on the bar, as fractions from its top left.
        var grab: CGPoint
        var size: CGSize
        var screen: NSScreen
        var edge = IslandPlacement.Edge.free
        var placement: IslandPlacement?
    }
    /// While set, the move owns the panel's frame and layout waits.
    private var move: Move?
    private var snapPreview: SnapPreviewPanel?
    private var decoration: IslandDecorationPanel?
    private var lostMouseUpCheck: DispatchWorkItem?

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
        model.onBeginMove = { [weak self] grab in self?.beginMove(grab: grab) }
        model.onEndMoveGesture = { [weak self] in self?.finishMove() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        })
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.cancelMove()
                self.model.close()
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            // A drag takes Escape before Escape-to-close.
            if event.keyCode == 53, self.move != nil { self.cancelMove(); return nil }
            if event.keyCode == 53, event.window === self.panel { self.model.close(); return nil }
            return event
        }) { monitors.append(monitor) }
        // The panel moves with the pointer, so follow AppKit's events rather
        // than the drag gesture's local coordinates.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            guard let self, self.move != nil else { return event }
            if event.type == .leftMouseUp { self.finishMove() } else { self.updateMove(cursor: NSEvent.mouseLocation) }
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

    private static func number(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
    /// The chosen display, or the main one when none is chosen or it is gone.
    private var selectedScreen: NSScreen? {
        NSScreen.screens.first { Self.number($0) == model.displayID } ?? NSScreen.screens.first
    }

    private static var buttonHeld: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private func layout(animated: Bool = true) {
        if move != nil, !Self.buttonHeld { checkForLostMouseUp() }
        guard move == nil else { return }
        if !model.expanded { panel.resignKey() }
        guard let screen = selectedScreen else { return }
        let demoNotch = model.isDemo && CommandLine.arguments.contains("--demo-notch")
        let hardwareNotchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hardwareNotchWidth = max(0, right.minX - left.maxX)
        } else { hardwareNotchWidth = 0 }
        let screenNotchSize = CGSize(width: demoNotch ? 180 : hardwareNotchWidth,
            height: demoNotch ? 36 : screen.safeAreaInsets.top)
        if model.screenNotchSize != screenNotchSize { model.screenNotchSize = screenNotchSize }
        let mode: IslandDisplayMode = demoNotch ? .notch : model.displayMode
        let layout = mode.layout(safeAreaTop: screenNotchSize.height, hardwareNotchWidth: screenNotchSize.width,
            size: CompactBarSize.load(from: model.defaults))
        if model.isAttached != layout.attached { model.isAttached = layout.attached }
        if model.stripWidth != layout.stripWidth { model.stripWidth = layout.stripWidth }
        // Light glass forces the light appearance on its system material.
        let appearance = NSAppearance(named: model.appearance.isLight ? .aqua : .darkAqua)
        if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
        if model.notchWidth != layout.notchWidth { model.notchWidth = layout.notchWidth }
        if model.baseHeaderHeight != layout.topHeight { model.baseHeaderHeight = layout.topHeight }
        let headerHeight = layout.topHeight
        if model.topHeight != headerHeight { model.topHeight = headerHeight }
        let collapsedWidth = IslandWidth.desired(expanded: false, notchWidth: layout.notchWidth,
            leading: 80, trailing: 65,
            headerWidth: model.measuredCompactWidth)
        let expandedWidth = IslandWidth.desired(expanded: true, notchWidth: layout.notchWidth,
            leading: 80, trailing: 65,
            contentWidth: model.measuredContentWidth, headerWidth: model.measuredCompactWidth)
        headerSize = CGSize(width: max(1, min(screen.frame.width - 24, collapsedWidth)), height: model.topHeight)
        stripSize = CGSize(width: layout.stripWidth, height: model.stripHeight)
        let sidePanelWidth = IslandWidth.sidePanel(contentWidth: model.measuredContentWidth)
        let anchor: IslandGeometry.Anchor, dock: IslandPosition?, opensUp: Bool, edge: IslandPlacement.Edge?
        let islandFrame: (Bool) -> CGRect
        if !layout.attached, let placement = IslandPlacement.load(from: model.defaults) {
            // Free Move: the dragged place, opening toward the room it has.
            let vertical = placement.vertical, visible = screen.visibleFrame, content = model.panelContentHeight
            let barSize = vertical ? stripSize : headerSize
            let width = vertical ? layout.stripWidth + sidePanelWidth : expandedWidth
            let arranged = { (expanded: Bool) in
                IslandGeometry.arrange(placement, visible: visible, barSize: barSize, expandedWidth: width,
                    contentHeight: content, expanded: expanded)
            }
            let open = arranged(true)
            anchor = open.anchor
            dock = vertical ? .corner(side: placement.edge == .left ? .left : .right, bottom: open.opensUp) : nil
            opensUp = !vertical && open.opensUp
            edge = placement.edge == .free ? nil : placement.edge
            islandFrame = { arranged($0).frame }
        } else {
            // The notch, or a saved position from before Free Move.
            let position = layout.attached ? IslandPosition.center : model.islandPosition
            let side = position.side == nil ? nil : position
            anchor = position.anchor; dock = side; opensUp = false
            edge = position.side.map { $0 == .left ? .left : .right }
            islandFrame = { expanded in
                if let side {
                    return IslandGeometry.sideFrame(visible: screen.visibleFrame, position: side, stripHeight: self.model.stripHeight,
                        expanded: expanded, panelWidth: sidePanelWidth, contentHeight: self.model.panelContentHeight,
                        stripWidth: layout.stripWidth)
                }
                return IslandGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, notchWidth: layout.notchWidth,
                    topHeight: self.model.topHeight, expanded: expanded, attached: layout.attached,
                    contentHeight: self.model.panelContentHeight, desiredWidth: expanded ? expandedWidth : collapsedWidth)
            }
        }
        if model.sideDock != dock { model.sideDock = dock }
        if model.opensUp != opensUp { model.opensUp = opensUp }
        if model.dockedEdge != edge { model.dockedEdge = edge }
        let frame = islandFrame(model.expanded), expandedFrame = islandFrame(true)
        if presentation.canvas != expandedFrame.size { presentation.canvas = expandedFrame.size }
        panel.collectionBehavior = model.showInFullscreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces]
        let current = presentation.sample
        let hasBlackHeader = layout.attached && model.appearance == .liquidGlass
        // Only a free capsule casts a shadow; an island against an edge flares into it.
        let floating = !layout.attached && dock == nil && edge == nil
        if panel.hasShadow != floating { panel.hasShadow = floating }
        let target = IslandTransition.Sample.resting(at: frame, expanded: model.expanded, hasBlackHeader: hasBlackHeader)
        let from = anchor.point(in: current.frame), to = anchor.point(in: frame)
        // A tall panel that slides inward to fit moves its anchor between the
        // bar and the open panel; that still springs like any open or close.
        let resting = [islandFrame(false), expandedFrame].map { anchor.point(in: $0).y }
        let onTrack = { (y: CGFloat) in y >= resting.min()! - 1 && y <= resting.max()! + 1 }
        let sameAnchor = anchor == self.anchor && abs(from.x - to.x) < 1
            && (abs(from.y - to.y) < 1 || (onTrack(from.y) && onTrack(to.y)))
        self.anchor = anchor
        if animated && sameAnchor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Quota/settings updates must not restart an unchanged destination.
            if let motion, motion.target.frame == frame, motion.target.expansion == target.expansion,
               motion.hasBlackHeader == hasBlackHeader { return }
            if current.finished, current.frame == frame, current.expansion == target.expansion,
               current.blackOpacity == target.blackOpacity {
                stopMotion(); return
            }
            motion = IslandTransition(from: current, to: frame, opening: model.expanded,
                                      hasBlackHeader: hasBlackHeader, anchor: anchor, start: CACurrentMediaTime())
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
            let frame = IslandGeometry.windowFrame(sample.frame, anchor: anchor)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            // Resolve SwiftUI geometry in the same frame without forcing a
            // second synchronous window redraw or implicit glass animation.
            hosting.layoutSubtreeIfNeeded()
            // A transparent window caches its silhouette. Update it with the
            // shell, not just at rest, which makes the floating shadow pop.
            if panel.hasShadow { panel.invalidateShadow() }
            updateDecoration(frame, sample: sample)
        }
        CATransaction.commit()
    }

    /// Shoulders where an island against the screen edge meets it, drawn in a
    /// child panel that never takes a click. Glass cannot paint outside its
    /// window, so only the opaque materials and the black header of attached
    /// dark glass have them; a glass strip has none.
    private func updateDecoration(_ frame: CGRect, sample: IslandTransition.Sample) {
        let sides = IslandFreeSides(attached: model.isAttached, flatEdge: model.dockedEdge)
        let screenSide = IslandFreeSides.all.subtracting(sides)
        let appearance = model.appearance
        let glass = appearance.isGlass && IslandAppearance.supportsLiquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let radius = CGFloat(model.barMetrics.shoulder)
        let fill: NSColor?
        if glass {
            fill = appearance == .liquidGlass && model.isAttached && sample.blackOpacity > 0.01
                ? NSColor.black.withAlphaComponent(min(1, max(0, sample.blackOpacity))) : nil
        } else {
            fill = NSColor(appearance == .graphite ? IslandAppearance.graphiteFace : appearance.isLight ? IslandAppearance.lightFace : .black)
        }
        guard move == nil, panel.isVisible, !screenSide.isEmpty, radius > 0, let fill, frame.width > 1, frame.height > 1 else {
            decoration?.orderOut(nil); return
        }
        let rim = glass ? nil : appearance.rim(glassVisible: false)
        let shoulders = decoration ?? IslandDecorationPanel()
        if decoration == nil {
            decoration = shoulders
            panel.addChildWindow(shoulders, ordered: .below)
        }
        shoulders.collectionBehavior = panel.collectionBehavior.union(.ignoresCycle)
        shoulders.present(island: frame, side: screenSide, radius: radius, fill: fill,
            rim: rim.map { NSColor($0.ink) }, rimWidth: rim?.width ?? 0)
    }

    private func stopMotion() {
        motionRevision += 1
        displayLink?.invalidate(); displayLink = nil; motion = nil
    }

    // MARK: Free Move

    /// Collapses the island in place and lets the pointer carry the bar until
    /// it is placed or cancelled.
    private func beginMove(grab: CGPoint) {
        guard move == nil, model.canMoveIsland, panel.isVisible, let screen = panel.screen ?? selectedScreen else { return }
        model.setIslandMoving(true)
        if model.expanded { model.setExpanded(false) }
        layout(animated: false)
        let bar = panel.frame
        move = Move(grab: grab, size: bar.size, screen: screen)
        updateMove(cursor: NSEvent.mouseLocation)
    }

    private func updateMove(cursor: CGPoint) {
        guard var move else { return }
        guard model.canMoveIsland else { cancelMove(); return }
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? move.screen
        if screen != move.screen { move.screen = screen; move.edge = .free }
        let visible = screen.visibleFrame
        let raw = CGRect(x: cursor.x - move.grab.x * move.size.width, y: cursor.y - (1 - move.grab.y) * move.size.height,
            width: move.size.width, height: move.size.height)
        move.edge = IslandGeometry.snapEdge(visible: visible, bar: raw, previous: move.edge)
        let placement = IslandGeometry.placement(edge: move.edge, visible: visible, bar: raw)
        move.placement = placement
        self.move = move
        stopMotion()
        apply(.resting(at: IslandGeometry.windowFrame(IslandGeometry.clamp(raw, to: visible), anchor: anchor),
            expanded: false, hasBlackHeader: false))
        if move.edge == .free { snapPreview?.orderOut(nil); return }
        let target = IslandGeometry.windowFrame(IslandGeometry.collapsedFrame(placement, visible: visible,
            size: placement.vertical ? stripSize : headerSize), anchor: anchor)
        let preview = snapPreview ?? SnapPreviewPanel()
        snapPreview = preview
        preview.show(target, edge: move.edge, below: panel)
    }

    /// Saves the place, on the display under the bar, and shows the island there.
    private func finishMove() {
        guard let move else { return }
        guard model.canMoveIsland, let placement = move.placement else { cancelMove(); return }
        endMove()
        let defaults = model.defaults
        placement.save(to: defaults)
        // A drag that stays on the fallback display keeps the chosen one, so
        // the island returns there when it reconnects.
        if selectedScreen != move.screen { defaults.set(Self.number(move.screen), forKey: "displayID") }
        if IslandDisplayMode.load(from: defaults) != .floating { IslandDisplayMode.floating.save(to: defaults) }
        model.islandPlacementSaved()
        if model.pinned { model.setExpanded(true) }
        layout(animated: false)
    }

    private func cancelMove() {
        guard move != nil else { return }
        endMove()
        if model.pinned { model.setExpanded(true) }
        layout(animated: false)
    }

    /// A drag whose mouse-up never arrived would hold layout forever. The
    /// button reads as released before its queued drag events and mouse-up
    /// are handled, so wait briefly before deciding the mouse-up is lost.
    private func checkForLostMouseUp() {
        guard lostMouseUpCheck == nil else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lostMouseUpCheck = nil
            if self.move != nil, !Self.buttonHeld { self.cancelMove() }
        }
        lostMouseUpCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
    }

    private func endMove() {
        lostMouseUpCheck?.cancel(); lostMouseUpCheck = nil
        move = nil
        snapPreview?.orderOut(nil)
        model.setIslandMoving(false)
    }

    func stop() {
        cancelMove()
        snapPreview?.close(); snapPreview = nil
        if let decoration { panel.removeChildWindow(decoration); decoration.close() }
        decoration = nil
        stopMotion()
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        panel.orderOut(nil)
    }
}

/// The outline of the edge a released drag docks to. It never takes input or focus.
private final class SnapPreviewPanel: NSPanel {
    private let outline = SnapOutline()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true
        level = .statusBar; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = outline
    }

    override var canBecomeKey: Bool { false }

    func show(_ frame: CGRect, edge: IslandPlacement.Edge, below window: NSWindow) {
        if outline.edge != edge { outline.edge = edge; outline.needsDisplay = true }
        if self.frame != frame { setFrame(frame, display: true) }
        order(.below, relativeTo: window.windowNumber)
    }
}

private final class SnapOutline: NSView {
    var edge = IslandPlacement.Edge.free

    override func draw(_ dirtyRect: NSRect) {
        let line: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 3 : 2
        let rect = bounds.insetBy(dx: line / 2, dy: line / 2)
        let radius = min(19, rect.width / 2, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = line; path.stroke()
    }
}

/// The island's shoulders: concave fillets where an island against the screen
/// edge flares into it, with a sliver reaching under the island so no seam
/// shows. A child panel that passes every click through.
private final class IslandDecorationPanel: NSPanel {
    private let shoulders = IslandShoulderView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true
        level = .statusBar; hidesOnDeactivate = false; isReleasedWhenClosed = false
        contentView = shoulders
    }

    override var canBecomeKey: Bool { false }

    func present(island: CGRect, side: IslandFreeSides, radius: CGFloat, fill: NSColor, rim: NSColor?, rimWidth: CGFloat) {
        let margin = radius + 2
        let frame = island.insetBy(dx: -margin, dy: -margin)
        let shell = CGRect(x: margin, y: margin, width: island.width, height: island.height)
        let next = IslandShoulderView.Drawing(shell: shell, side: side, radius: radius, fill: fill, rim: rim, rimWidth: rimWidth)
        if shoulders.drawing != next { shoulders.drawing = next; shoulders.needsDisplay = true }
        if self.frame != frame { setFrame(frame, display: false) }
        if !isVisible { orderFront(nil) }
    }
}

private final class IslandShoulderView: NSView {
    struct Drawing: Equatable {
        var shell: CGRect
        var side: IslandFreeSides
        var radius: CGFloat
        var fill: NSColor
        var rim: NSColor?
        var rimWidth: CGFloat
    }
    var drawing: Drawing?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawing, let context = NSGraphicsContext.current?.cgContext else { return }
        let (fills, curves) = Self.shoulders(drawing.shell, side: drawing.side, radius: drawing.radius)
        context.addPath(fills); context.setFillColor(drawing.fill.cgColor); context.fillPath()
        if let rim = drawing.rim, drawing.rimWidth > 0 {
            context.addPath(curves); context.setStrokeColor(rim.cgColor); context.setLineWidth(drawing.rimWidth); context.strokePath()
        }
    }

    /// Two quarter circles of `radius` at the island's ends against `side`,
    /// in this flipped view: the screen edge runs along the island's outer side.
    static func shoulders(_ shell: CGRect, side: IslandFreeSides, radius r: CGFloat) -> (CGPath, CGPath) {
        let fills = CGMutablePath(), curves = CGMutablePath(), seam: CGFloat = 1.5
        func fillet(corner: CGPoint, outer: CGPoint, inner: CGPoint, center: CGPoint, from: CGFloat, to: CGFloat, clockwise: Bool, overlap: CGRect) {
            fills.move(to: corner); fills.addLine(to: outer)
            fills.addArc(center: center, radius: r, startAngle: from, endAngle: to, clockwise: clockwise)
            fills.closeSubpath(); fills.addRect(overlap)
            curves.move(to: outer); curves.addArc(center: center, radius: r, startAngle: from, endAngle: to, clockwise: clockwise)
        }
        let half = CGFloat.pi / 2
        let left = shell.minX, right = shell.maxX, top = shell.minY, bottom = shell.maxY
        if side.contains(.top) {
            fillet(corner: CGPoint(x: left, y: top), outer: CGPoint(x: left - r, y: top), inner: CGPoint(x: left, y: top + r),
                center: CGPoint(x: left - r, y: top + r), from: -half, to: 0, clockwise: false, overlap: CGRect(x: left, y: top, width: seam, height: r))
            fillet(corner: CGPoint(x: right, y: top), outer: CGPoint(x: right + r, y: top), inner: CGPoint(x: right, y: top + r),
                center: CGPoint(x: right + r, y: top + r), from: -half, to: -.pi, clockwise: true, overlap: CGRect(x: right - seam, y: top, width: seam, height: r))
        } else if side.contains(.bottom) {
            fillet(corner: CGPoint(x: left, y: bottom), outer: CGPoint(x: left - r, y: bottom), inner: CGPoint(x: left, y: bottom - r),
                center: CGPoint(x: left - r, y: bottom - r), from: half, to: 0, clockwise: true, overlap: CGRect(x: left, y: bottom - r, width: seam, height: r))
            fillet(corner: CGPoint(x: right, y: bottom), outer: CGPoint(x: right + r, y: bottom), inner: CGPoint(x: right, y: bottom - r),
                center: CGPoint(x: right + r, y: bottom - r), from: half, to: .pi, clockwise: false, overlap: CGRect(x: right - seam, y: bottom - r, width: seam, height: r))
        } else if side.contains(.left) {
            fillet(corner: CGPoint(x: left, y: top), outer: CGPoint(x: left, y: top - r), inner: CGPoint(x: left + r, y: top),
                center: CGPoint(x: left + r, y: top - r), from: .pi, to: half, clockwise: true, overlap: CGRect(x: left, y: top, width: r, height: seam))
            fillet(corner: CGPoint(x: left, y: bottom), outer: CGPoint(x: left, y: bottom + r), inner: CGPoint(x: left + r, y: bottom),
                center: CGPoint(x: left + r, y: bottom + r), from: .pi, to: 3 * half, clockwise: false, overlap: CGRect(x: left, y: bottom - seam, width: r, height: seam))
        } else if side.contains(.right) {
            fillet(corner: CGPoint(x: right, y: top), outer: CGPoint(x: right, y: top - r), inner: CGPoint(x: right - r, y: top),
                center: CGPoint(x: right - r, y: top - r), from: 0, to: half, clockwise: false, overlap: CGRect(x: right - r, y: top, width: r, height: seam))
            fillet(corner: CGPoint(x: right, y: bottom), outer: CGPoint(x: right, y: bottom + r), inner: CGPoint(x: right - r, y: bottom),
                center: CGPoint(x: right - r, y: bottom + r), from: 0, to: -half, clockwise: true, overlap: CGRect(x: right - r, y: bottom - seam, width: r, height: seam))
        }
        return (fills, curves)
    }
}
