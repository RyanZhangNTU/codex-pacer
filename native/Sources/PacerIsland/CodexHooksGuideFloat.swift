import AppKit
import PacerCore
import SwiftUI

/// The small floating guide beside Codex while the user allows Pacer's hooks:
/// the clicks on Codex's Hooks page, drawn as they look there, and the shorter
/// way from a chat. Settings' Open Codex shows it. It follows the hooks' status,
/// which the model refreshes while they wait; says it's done for eight seconds
/// once they are allowed, and closes then, on Close or after ten minutes. It
/// never takes focus and never reads Codex's window.
@MainActor final class CodexHooksGuideFloat: ObservableObject {
    private weak var model: IslandModel?
    private let panel = FloatPanel()
    private var host: NSHostingController<AnyView>?
    private var timer: Timer?
    private var screen: NSScreen?
    private var started = Date()
    @Published private(set) var doneSince: Date?
    static let check: TimeInterval = 1
    static let doneShown: TimeInterval = 8
    static let lifetime: TimeInterval = 600

    init(model: IslandModel) { self.model = model }

    var isShowing: Bool { panel.isVisible }

    func show(on screen: NSScreen?) {
        guard let model else { return }
        close()
        self.screen = screen ?? NSScreen.main
        started = Date(); doneSince = nil
        let host = NSHostingController(rootView: AnyView(CodexHooksGuideContent(model: model, float: self)
            .pacerAccent(PacerAccent.current)))
        host.sizingOptions = []
        self.host = host
        panel.contentViewController = host
        timer = Timer.scheduledTimer(withTimeInterval: Self.check, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        panel.place(on: self.screen, size: measured())
        panel.orderFrontRegardless()
        update()
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
        panel.contentViewController = nil; host = nil
    }

    private func update() {
        guard let model, Date().timeIntervalSince(started) < Self.lifetime else { return close() }
        switch Self.phase(model.codexHookStatus) {
        case .steps: doneSince = nil
        case .done:
            if doneSince == nil { doneSince = Date() }
            if let doneSince, Date().timeIntervalSince(doneSince) >= Self.doneShown { return close() }
        case .gone: return close()
        }
        panel.resize(to: measured())
    }

    enum Phase: Equatable { case steps, done, gone }

    /// Allowed hooks are done; a status the guide doesn't describe closes it,
    /// and Settings says what to do.
    static func phase(_ status: CodexHookStatus) -> Phase {
        switch status {
        case .needsApproval, .notInstalled: .steps
        case .running, .notRunning: .done
        case .off, .needsCodexUpdate, .installFailed: .gone
        }
    }

    private func measured() -> CGSize { FloatPanel.measure(host, width: CodexHooksGuideContent.width) }
}

private struct CodexHooksGuideContent: View {
    static let width: CGFloat = 400
    @ObservedObject var model: IslandModel
    @ObservedObject var float: CodexHooksGuideFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideFloatHeader(chip: "Codex") { float.close() }
            if float.doneSince != nil {
                Label(L10n.text("codex.hooks.guide.done"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14.5, weight: .semibold)).symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("codex.hooks.guide.title")).font(.system(size: 14.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            NumberBadge(number: index + 1)
                            Text(step).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                CodexHooksPicture(pending: pending, total: model.codexInstalledHookCount)
                Text(L10n.text("codex.hooks.guide.alternative")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .guideFloatCard(width: Self.width)
    }

    static var steps: [String] {
        [L10n.text("codex.hooks.guide.step_hooks"), L10n.text("codex.hooks.guide.step_plugin", CodexHookPlugin.displayName),
         L10n.text("codex.hooks.guide.step_trust")]
    }

    private var pending: Int {
        if case .needsApproval(let count) = model.codexHookStatus { return count }
        return model.codexInstalledHookCount
    }
}

/// A step's number, as the picture marks the place to click.
private struct NumberBadge: View {
    let number: Int
    @Environment(\.pacerAccent) private var accent

    var body: some View {
        Text("\(number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .frame(width: 16, height: 16).background(accent, in: Circle())
            .accessibilityHidden(true)
    }
}

/// A drawing of Codex's Hooks settings: Hooks in its sidebar, Pacer's plugin
/// under From Plugins with the hooks waiting for review, and Trust all with
/// a ring around it. Numbers mark the steps.
private struct CodexHooksPicture: View {
    let pending: Int
    let total: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                placeholder(width: 46)
                placeholder(width: 58)
                HStack(spacing: 5) {
                    Text(L10n.text("codex.hooks.guide.picture.hooks")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    NumberBadge(number: 1)
                }
                .padding(.horizontal, 7).frame(height: 24)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                placeholder(width: 40)
            }
            .padding(10).frame(width: 104, alignment: .leading)
            Rectangle().fill(MainPalette.cardBorder).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("codex.hooks.guide.picture.plugins")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CodexHookPlugin.displayName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text(L10n.text("codex.hooks.guide.picture.count", total))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Label(L10n.text(pending == 1 ? "codex.hooks.guide.picture.review_one" : "codex.hooks.guide.picture.review", pending),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1).fixedSize()
                    NumberBadge(number: 2)
                }
                .padding(.horizontal, 8).frame(height: 38)
                .background(MainPalette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MainPalette.cardBorder))
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    NumberBadge(number: 3)
                    Text(L10n.text("codex.hooks.guide.picture.trust_all")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.25)))
                        .padding(3)
                        .overlay { PulsingRing(cornerRadius: 8) }
                        .fixedSize()
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MainPalette.infoFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MainPalette.cardBorder))
        // A picture of Codex's page; the steps already say what to do.
        .accessibilityHidden(true)
    }

    private func placeholder(width: CGFloat) -> some View {
        Capsule().fill(Color.primary.opacity(0.1)).frame(width: width, height: 7).frame(height: 14)
    }
}
