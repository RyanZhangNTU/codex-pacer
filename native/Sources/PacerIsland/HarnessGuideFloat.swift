import AppKit
import PacerCore
import SwiftUI

/// The small floating guide beside a module's app: what to click there now,
/// the same picture the card shows, and what comes next. The card's Open
/// and Restart open it. It waits hidden while the app restarts or opens,
/// for up to two minutes, follows the steps once shown, and closes itself
/// once there is nothing left to click, on Close, or with Settings. It
/// never takes focus and never reads the app's window.
@MainActor final class HarnessGuideFloat {
    private weak var model: IslandModel?
    private(set) var provider: AgentProvider?
    private let panel = FloatPanel()
    private var timer: Timer?
    private var opened = Date()
    private var shown = false
    /// Checks in a row with nothing to click; one alone can be a file caught mid-write.
    private var emptyChecks = 0
    private var screen: NSScreen?
    private var host: NSHostingController<AnyView>?
    static let check: TimeInterval = 1.5
    static let wait: TimeInterval = 120

    init(model: IslandModel) { self.model = model }

    var isShowing: Bool { panel.isVisible }

    func show(_ provider: AgentProvider, on screen: NSScreen?) {
        guard let model else { return }
        close()
        self.provider = provider
        self.screen = screen ?? NSScreen.main
        opened = Date(); shown = false; emptyChecks = 0
        let host = NSHostingController(rootView: AnyView(GuideFloatContent(model: model, provider: provider, close: { [weak self] in self?.close() })
            .pacerAccent(PacerAccent.current)))
        host.sizingOptions = []
        self.host = host
        panel.contentViewController = host
        timer = Timer.scheduledTimer(withTimeInterval: Self.check, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        update()
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
        provider = nil
        panel.contentViewController = nil; host = nil
    }

    /// The steps move on from the app's log, so checking here keeps them
    /// moving while Settings sits behind the app.
    private func tick() {
        guard let provider else { return close() }
        model?.recheckLocalHarnessProgress(provider)
        update()
    }

    private func update() {
        guard let provider, let model else { return close() }
        guard model.progressGuide(provider)?.floatTitle != nil else {
            // Nothing to click yet while the app restarts or opens; nothing left
            // once it was shown, read twice in a row.
            emptyChecks += 1
            if (shown && emptyChecks >= 2) || Date().timeIntervalSince(opened) > Self.wait { close() }
            return
        }
        emptyChecks = 0
        guard let host else { return }
        // The content's own height at the panel's width, measured before the panel takes its size.
        let size = host.sizeThatFits(in: CGSize(width: GuideFloatContent.width, height: 4000))
        if !shown, let frame = screen?.visibleFrame {
            // The bottom-right of the screen Settings is on, 16 points in.
            panel.setFrame(CGRect(x: frame.maxX - size.width - 16, y: frame.minY + 16, width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
            shown = true
        } else if size != panel.frame.size {
            // Grows or shrinks with its content, its bottom-right corner in place.
            let frame = panel.frame
            panel.setFrame(CGRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height), display: true)
        }
    }
}

/// A borderless panel above other windows that never takes focus.
private final class FloatPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .floating
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct GuideFloatContent: View {
    static let width: CGFloat = 400
    @ObservedObject var model: IslandModel
    let provider: AgentProvider
    let close: () -> Void

    var body: some View {
        let guide = model.progressGuide(provider)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                Text("Pacer · " + (guide?.chip ?? "")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("progress_guide.float.close"))
                .help(L10n.text("progress_guide.float.close"))
            }
            if let title = guide?.floatTitle {
                Text(title).font(.system(size: 14.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                switch guide?.picture {
                case .customConnector?: CustomConnectorPicture()
                case .trust?: TrustPicture(provider: provider)
                case nil: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let next = guide?.floatNext {
                Text(next).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(MainPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainPalette.cardBorder))
    }
}
