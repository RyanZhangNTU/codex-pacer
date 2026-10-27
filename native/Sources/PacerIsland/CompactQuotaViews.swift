import AppKit
import PacerCore
import SwiftUI

extension EnvironmentValues {
    /// True inside the hidden copy that measures the collapsed row, which must
    /// size like the real row without running its own animations.
    @Entry var islandLayoutProbe = false
}

/// One quota value that alternates between providers. Core Animation crossfades
/// the values in the render server, so alternating never wakes the app; text
/// changes only when a provider's value does. It pauses while occluded.
struct AlternatingQuotaText: NSViewRepresentable {
    struct Entry: Equatable {
        let text: String
        let color: NSColor
    }
    static let interval: CFTimeInterval = 4
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    let entries: [Entry]
    let animates: Bool
    var font = Self.font

    func makeNSView(context: Context) -> AlternatingQuotaView { AlternatingQuotaView() }
    func updateNSView(_ view: AlternatingQuotaView, context: Context) { view.update(entries: entries, animates: animates, font: font) }
    /// The widest value reserves the slot, so alternating never moves its neighbors.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AlternatingQuotaView, context: Context) -> CGSize? {
        let width = entries.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return CGSize(width: ceil(width), height: ceil(font.ascender - font.descender))
    }
}

final class AlternatingQuotaView: NSView {
    private static let fade: CFTimeInterval = 0.35
    private var layers: [CATextLayer] = []
    private var entries: [AlternatingQuotaText.Entry] = []
    private var animates = true
    private var font = AlternatingQuotaText.font
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(entries: [AlternatingQuotaText.Entry], animates: Bool, font: NSFont = AlternatingQuotaText.font) {
        guard entries != self.entries || animates != self.animates || font != self.font else { return }
        let restart = entries.count != layers.count || animates != self.animates
        self.entries = entries; self.animates = animates; self.font = font
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if entries.count != layers.count {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = entries.map { _ in
                let text = CATextLayer()
                text.alignmentMode = .center
                text.truncationMode = .none
                layer?.addSublayer(text)
                return text
            }
        }
        for (text, entry) in zip(layers, entries) {
            text.string = NSAttributedString(string: entry.text,
                attributes: [.font: font, .foregroundColor: entry.color])
        }
        layoutLayers()
        CATransaction.commit()
        if restart { layers.forEach { $0.removeAnimation(forKey: "alternate") } }
        refreshAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layers.forEach { $0.contentsScale = window?.backingScaleFactor ?? 2 }
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
        layers.forEach { $0.contentsScale = window?.backingScaleFactor ?? 2 }
        refreshAnimation()
    }

    private func layoutLayers() {
        let height = ceil(font.ascender - font.descender)
        for text in layers {
            text.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
    }

    /// Each value holds for one interval; the outgoing and incoming values
    /// crossfade over the last moments of a slot, ending on its boundary.
    private func refreshAnimation() {
        let count = layers.count
        for (index, text) in layers.enumerated() { text.opacity = index == 0 ? 1 : 0 }
        guard count > 1, animates, let window, window.occlusionState.contains(.visible) || !window.isVisible else {
            layers.forEach { $0.removeAnimation(forKey: "alternate") }
            return
        }
        guard layers[0].animation(forKey: "alternate") == nil else { return }
        let slot = AlternatingQuotaText.interval, total = slot * Double(count), fade = Self.fade
        for (index, text) in layers.enumerated() {
            let start = slot * Double(index), end = start + slot
            let times: [Double], values: [Double]
            if index == 0 {
                times = [0, end - fade, end, total - fade, total]; values = [1, 1, 0, 0, 1]
            } else if index == count - 1 {
                times = [0, start - fade, start, total - fade, total]; values = [0, 0, 1, 1, 0]
            } else {
                times = [0, start - fade, start, end - fade, end, total]; values = [0, 0, 1, 1, 0, 0]
            }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values
            animation.keyTimes = times.map { NSNumber(value: $0 / total) }
            animation.duration = total
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            text.add(animation, forKey: "alternate")
        }
    }
}

/// Both providers' remaining quota in one glyph: Codex outside, Claude inside,
/// echoing the expanded rings. A single provider gets one heavier ring.
struct QuotaRingsGlyph: View {
    struct Ring: Equatable {
        let tint: Color
        let remaining: Double?
        let stale: Bool
    }
    let rings: [Ring]

    var body: some View {
        ZStack {
            ForEach(Array(rings.prefix(2).enumerated()), id: \.offset) { index, ring in
                let paired = rings.count > 1
                arc(ring, lineWidth: paired ? 2.2 : 2.6)
                    .frame(width: paired ? (index == 0 ? 15.4 : 7.6) : 14.8, height: paired ? (index == 0 ? 15.4 : 7.6) : 14.8)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    private func arc(_ ring: Ring, lineWidth: CGFloat) -> some View {
        let fraction = ring.remaining.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil }
        return ZStack {
            Circle().stroke(Color.white.opacity(0.14),
                style: StrokeStyle(lineWidth: lineWidth, dash: fraction == nil ? [1.5, 2] : []))
            if let fraction, fraction > 0 {
                Circle().trim(from: 0, to: fraction)
                    .stroke(ring.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .opacity(ring.stale ? 0.45 : 1)
    }
}

/// The 5h warning pair: an outlined capsule when below 20% and a solid one
/// when exhausted, tinted by provider. Solid means more urgent, as on the
/// activity badge; the label names the window the weekly value does not show.
struct FiveHourAlertGlyph: View {
    let alert: FiveHourQuotaAlert
    let tint: Color

    var body: some View {
        let exhausted = alert == .exhausted
        Text("5h")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(exhausted ? Color.black.opacity(0.82) : tint)
            .padding(.horizontal, 3.5).frame(height: 13)
            .background {
                if exhausted { Capsule().fill(tint) } else { Capsule().strokeBorder(tint, lineWidth: 1) }
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The wallet when DeepSeek is the only module: the balance, then today's
/// estimated spend, amber when it runs ahead of a usual day.
struct DeepSeekCompactWallet: View {
    let wallet: DeepSeekWallet

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(wallet.balance.map { DeepSeekWallet.compactAmount($0.total) } ?? "¥—")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(balanceColor)
            Text(L10n.text("deepseek.today_short", DeepSeekWallet.compactSpend(wallet.today)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(wallet.spendingFast ? PacerPalette.attention : PacerPalette.secondary)
        }
        .monospacedDigit().fixedSize(horizontal: true, vertical: false)
    }
    private var balanceColor: Color { DeepSeekWalletColors.balance(wallet.state) }
}

enum DeepSeekWalletColors {
    static func balance(_ state: DeepSeekWallet.State) -> Color {
        switch state {
        case .normal: AgentProvider.deepseek.tint
        case .low: PacerPalette.attention
        case .exhausted: PacerPalette.danger
        case .stale, .disconnected: PacerPalette.secondary
        }
    }
}

/// The low-balance pair, matching the 5h capsule: outlined when low, solid
/// when the wallet can no longer pay.
struct WalletAlertGlyph: View {
    let exhausted: Bool
    private let tint = AgentProvider.deepseek.tint

    var body: some View {
        Text("¥")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(exhausted ? Color.black.opacity(0.82) : tint)
            .padding(.horizontal, 4).frame(height: 13)
            .background {
                if exhausted { Capsule().fill(tint) } else { Capsule().strokeBorder(tint, lineWidth: 1) }
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Doubled peak prices while a DeepSeek task runs; off unless chosen.
struct PeakPriceGlyph: View {
    var body: some View {
        Text("×2")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(AgentProvider.deepseek.tint)
            .padding(.horizontal, 3.5).frame(height: 13)
            .background(Capsule().fill(AgentProvider.deepseek.tint.opacity(0.18)))
            .fixedSize()
            .accessibilityHidden(true)
    }
}
