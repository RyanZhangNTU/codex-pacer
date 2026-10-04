import AppKit
import SwiftUI

/// A small overlay scroller is only needed when the screen itself limits height.
struct CompactScrollbarStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> Configurator { Configurator() }
    func updateNSView(_ view: Configurator, context: Context) { view.scheduleConfiguration() }

    final class Configurator: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let scroll = view as? NSScrollView {
                        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                        if scroll.verticalScroller?.controlSize != .mini {
                            scroll.verticalScroller?.controlSize = .mini
                        }
                        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
                        if scroll.drawsBackground { scroll.drawsBackground = false }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
