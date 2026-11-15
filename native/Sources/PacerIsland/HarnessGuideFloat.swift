import AppKit
import PacerCore
import SwiftUI

/// The small floating guide beside a module's app: what to click there now,
/// the same picture the card shows, and what comes next. The card's Open
/// and Restart open it at once, asking the user to wait while the app
/// restarts or opens (up to two minutes); it then follows the app's steps,
/// says it's done for eight seconds once trusted, and closes itself once
/// there is nothing left to click, on Close or after ten minutes. It outlives Settings,
/// checking the module itself, never takes focus and never reads the app's window.
@MainActor final class HarnessGuideFloat: ObservableObject {
    private weak var model: IslandModel?
    private(set) var provider: AgentProvider?
    private let panel = FloatPanel()
    private var host: NSHostingController<AnyView>?
    private var timer: Timer?
    private var opened = Date()
    private var screen: NSScreen?
    /// What to say before the app shows a step of its own.
    @Published private(set) var pending: (title: String, next: String)?
    /// The app has shown a step of its own; from then on the float follows it.
    @Published private(set) var followsApp = false
    /// Checks in a row with nothing to click; one alone can be a file caught mid-write.
    private var emptyChecks = 0
    private var doneSince: Date?
    static let check: TimeInterval = 1.5
    static let wait: TimeInterval = 120
    static let doneShown: TimeInterval = 8
    /// It never stays longer than this, whatever the app does.
    static let lifetime: TimeInterval = 600
    private var started = Date()

    init(model: IslandModel) { self.model = model }

    var isShowing: Bool { panel.isVisible }

    func show(_ provider: AgentProvider, on screen: NSScreen?, pending: (title: String, next: String)?) {
        guard let model else { return }
        // A restart that goes on to open the app keeps the same float, with the newer words.
        if self.provider == provider, panel.isVisible, !followsApp {
            self.pending = pending ?? self.pending
            opened = Date()
            update()
            return
        }
        close()
        self.provider = provider
        self.screen = screen ?? NSScreen.main
        self.pending = pending
        opened = Date(); started = opened; followsApp = false; emptyChecks = 0; doneSince = nil
        let host = NSHostingController(rootView: AnyView(GuideFloatContent(model: model, float: self, provider: provider)
            .pacerAccent(PacerAccent.current)))
        host.sizingOptions = []
        self.host = host
        panel.contentViewController = host
        timer = Timer.scheduledTimer(withTimeInterval: Self.check, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        place()
        panel.orderFrontRegardless()
        update()
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
        provider = nil
        panel.contentViewController = nil; host = nil
    }

    /// The steps move on from the app's log, so checking here keeps them
    /// moving while Settings is closed or behind the app.
    private func tick() {
        guard let provider else { return close() }
        model?.recheckLocalHarnessProgress(provider)
        update()
    }

    private func update() {
        guard let provider, let model, Date().timeIntervalSince(started) < Self.lifetime else { return close() }
        let guide = model.progressGuide(provider)
        // While Pacer restarts the app, the app's own steps (even "done") wait for it to return.
        if model.harnessRestartInFlight(provider), !followsApp {
            if Date().timeIntervalSince(opened) > Self.wait { return close() }
            return resize()
        }
        if guide?.floatTitle != nil {
            emptyChecks = 0
            if !followsApp { followsApp = true }
            // Done: it says so for a few seconds, then steps aside.
            if guide?.stage == .firstTask {
                if doneSince == nil { doneSince = Date() }
                if let doneSince, Date().timeIntervalSince(doneSince) >= Self.doneShown { return close() }
            }
        } else if followsApp {
            // Nothing left to click once it followed the app, read twice in a row.
            emptyChecks += 1
            if emptyChecks >= 2 { return close() }
        } else if pending == nil || Date().timeIntervalSince(opened) > Self.wait {
            return close()
        }
        resize()
    }

    /// The bottom-right of the screen Settings is on, 16 points in.
    private func place() {
        guard let frame = screen?.visibleFrame else { return }
        let size = measured()
        panel.setFrame(CGRect(x: frame.maxX - size.width - 16, y: frame.minY + 16, width: size.width, height: size.height), display: true)
    }

    /// Grows or shrinks with its content, its bottom-right corner in place.
    private func resize() {
        let size = measured(), frame = panel.frame
        guard size != frame.size else { return }
        panel.setFrame(CGRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height), display: true)
    }

    /// The content's own height at the panel's width.
    private func measured() -> CGSize {
        host?.sizeThatFits(in: CGSize(width: GuideFloatContent.width, height: 4000)) ?? CGSize(width: GuideFloatContent.width, height: 120)
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
    @ObservedObject var float: HarnessGuideFloat
    let provider: AgentProvider

    var body: some View {
        let guide = model.progressGuide(provider)
        // Until the app shows a step of its own, the float says what Pacer is doing.
        let waiting = !float.followsApp && (guide?.floatTitle == nil || model.harnessRestartInFlight(provider))
        let title = waiting ? float.pending?.title : guide?.floatTitle
        let next = waiting ? float.pending?.next : guide?.floatNext
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                Text("Pacer · " + (guide?.chip ?? "")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { float.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("progress_guide.float.close"))
                .help(L10n.text("progress_guide.float.close"))
            }
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if waiting { ProgressView().controlSize(.small) }
                    Text(title).font(.system(size: 14.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !waiting {
                Group {
                    switch guide?.picture {
                    case .customConnector?: CustomConnectorPicture()
                    case .trust?: TrustPicture(provider: provider)
                    case nil: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let next {
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
