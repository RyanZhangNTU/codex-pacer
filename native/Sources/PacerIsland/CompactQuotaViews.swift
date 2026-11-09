import AppKit
import PacerCore
import SwiftUI

extension EnvironmentValues {
    /// True inside the hidden copy that measures the collapsed row, which must
    /// size like the real row without running its own animations.
    @Entry var islandLayoutProbe = false
}

/// One quota value that takes turns between providers, each a number with its
/// unit. Core Animation slides the values in the render server, so taking
/// turns never wakes the app; text changes only when a provider's value does.
/// The outgoing value leaves upward as the next rises into place, each moving
/// a whole line inside this slot, so two never overlap each other or a
/// neighbor. Every rotation keeps the same clock, so values rebuilt by a new
/// reading take the running frame at once, and the rings dim in step. It
/// pauses while occluded.
struct AlternatingQuotaText: NSViewRepresentable {
    struct Entry: Equatable {
        let text: String
        let color: NSColor
        /// The trailing "%" draws as a smaller unit in the unit color.
        var splitsUnit = true
    }
    static let interval: CFTimeInterval = 4
    static let fade: CFTimeInterval = 0.35
    /// Every rotation shares this start, so all of them, and the rings that
    /// follow them, keep one phase whenever they are rebuilt.
    static let epoch: CFTimeInterval = (CACurrentMediaTime() / 100).rounded(.down) * 100
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    let entries: [Entry]
    let animates: Bool
    var font = Self.font
    var unitSize: CGFloat = 10
    var unitColor = NSColor(PacerPalette.unit)
    /// The strip centers each value in its cell; the bar keeps it at the start of its slot.
    var centered = false
    var maxWidth: CGFloat = .infinity

    func makeNSView(context: Context) -> AlternatingQuotaView { AlternatingQuotaView() }
    func updateNSView(_ view: AlternatingQuotaView, context: Context) {
        view.update(strings: entries.map(attributed), animates: animates, font: font, centered: centered, maxWidth: maxWidth)
    }
    /// The widest value reserves the slot, so taking turns never moves its neighbors.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AlternatingQuotaView, context: Context) -> CGSize? {
        let width = entries.map { attributed($0).size().width }.max() ?? 0
        return CGSize(width: min(maxWidth, ceil(width)), height: ceil(font.ascender - font.descender))
    }
    func attributed(_ entry: Entry) -> NSAttributedString {
        let value = NSMutableAttributedString()
        let percent = entry.splitsUnit && entry.text.count > 1 && entry.text.hasSuffix("%")
        let number = percent ? String(entry.text.dropLast()) : entry.text
        value.append(NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: entry.color,
            .kern: percent ? max(1, font.pointSize * 1.5 / 13) : 0]))
        if percent {
            value.append(NSAttributedString(string: "%", attributes: [
                .font: NSFont.systemFont(ofSize: unitSize, weight: .medium), .foregroundColor: unitColor]))
        }
        return value
    }
}

final class AlternatingQuotaView: NSView {
    private var layers: [CATextLayer] = []
    private var strings: [NSAttributedString] = []
    private var animates = true
    private var font = AlternatingQuotaText.font
    private var centered = false
    private var maxWidth: CGFloat = .infinity
    private var slideHeight: CGFloat = 0
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(entries: [AlternatingQuotaText.Entry], animates: Bool, font: NSFont = AlternatingQuotaText.font) {
        let text = AlternatingQuotaText(entries: entries, animates: animates, font: font)
        update(strings: entries.map(text.attributed), animates: animates, font: font)
    }

    func update(strings: [NSAttributedString], animates: Bool, font: NSFont, centered: Bool = false, maxWidth: CGFloat = .infinity) {
        guard strings != self.strings || animates != self.animates || font != self.font || centered != self.centered
            || maxWidth != self.maxWidth else { return }
        let restart = strings.count != layers.count || animates != self.animates || font != self.font
        self.strings = strings; self.animates = animates; self.font = font; self.centered = centered; self.maxWidth = maxWidth
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if strings.count != layers.count {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = strings.map { _ in
                let text = CATextLayer()
                text.truncationMode = .none
                // A text layer draws at 1x unless told otherwise; layers made after the
                // view joined its window would otherwise stay blurry on Retina screens.
                text.contentsScale = backingScale
                layer?.addSublayer(text)
                return text
            }
        }
        for (text, string) in zip(layers, strings) {
            text.string = string
            text.alignmentMode = centered ? .center : .left
        }
        layoutLayers()
        CATransaction.commit()
        if restart { layers.forEach { $0.removeAnimation(forKey: "alternate"); $0.removeAnimation(forKey: "slide") } }
        refreshAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
        // The slide covers one line, which the frame sets.
        if bounds.height != slideHeight {
            layers.forEach { $0.removeAnimation(forKey: "slide") }
            refreshAnimation()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layers.forEach { $0.contentsScale = backingScale }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshAnimation() }
                }
        }
        layers.forEach { $0.contentsScale = backingScale }
        refreshAnimation()
    }

    private func layoutLayers() {
        let height = ceil(font.ascender - font.descender)
        for text in layers {
            text.frame = backingAlignedRect(CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height),
                options: .alignAllEdgesNearest)
        }
    }

    /// Each value holds for one interval; the outgoing and incoming values
    /// cross over the last moments of a slot, ending on its boundary.
    private func refreshAnimation() {
        let count = layers.count
        for (index, text) in layers.enumerated() { text.opacity = index == 0 ? 1 : 0 }
        guard count > 1, animates, let window, window.occlusionState.contains(.visible) || !window.isVisible else {
            layers.forEach { $0.removeAnimation(forKey: "alternate"); $0.removeAnimation(forKey: "slide") }
            return
        }
        guard layers[0].animation(forKey: "alternate") == nil || layers[0].animation(forKey: "slide") == nil else { return }
        let slot = AlternatingQuotaText.interval, total = slot * Double(count), fade = AlternatingQuotaText.fade
        slideHeight = bounds.height
        // A line up on screen, whichever way this layer counts.
        let rise = max(1, bounds.height) * (layer?.contentsAreFlipped() == true ? -1 : 1), nudge = 0.001
        for (index, text) in layers.enumerated() {
            let start = slot * Double(index), end = start + slot
            let times: [Double], values: [Double], slideTimes: [Double], offsets: [Double]
            if index == 0 {
                times = [0, end - fade, end, total - fade, total]; values = [1, 1, 0, 0, 1]
                slideTimes = [0, end - fade, end, end + nudge, total - fade, total]; offsets = [0, 0, rise, -rise, -rise, 0]
            } else if index == count - 1 {
                times = [0, start - fade, start, total - fade, total]; values = [0, 0, 1, 1, 0]
                slideTimes = [0, start - fade, start, total - fade, total]; offsets = [-rise, -rise, 0, 0, rise]
            } else {
                times = [0, start - fade, start, end - fade, end, total]; values = [0, 0, 1, 1, 0, 0]
                slideTimes = [0, start - fade, start, end - fade, end, total]; offsets = [-rise, -rise, 0, 0, rise, rise]
            }
            text.removeAnimation(forKey: "alternate"); text.removeAnimation(forKey: "slide")
            text.add(Self.loop("opacity", times: times, values: values, total: total), forKey: "alternate")
            let slide = Self.loop("transform.translation.y", times: slideTimes, values: offsets, total: total)
            slide.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: slideTimes.count - 1)
            text.add(slide, forKey: "slide")
        }
    }

    static func loop(_ key: String, times: [Double], values: [Double], total: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / total) }
        animation.duration = total
        animation.beginTime = AlternatingQuotaText.epoch
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return animation
    }
    /// The shown value's index now, for tests.
    var shownIndex: Int {
        layers.firstIndex { ($0.presentation() ?? $0).opacity >= 0.5 } ?? 0
    }
}

/// Remaining quota as open rings, the gap at the bottom: two services nested
/// or side by side, or one service's 5-hour and weekly windows sharing one
/// ring. The track takes the service's color, the arc turns amber when low
/// and the track red when nothing is left; a white tick marks the share of
/// the window's time still left. An old or missing reading dashes the track
/// and fades. While the quota value takes turns, the ring it is not naming
/// dims in step with it.
struct QuotaRingsGlyph: NSViewRepresentable {
    struct Ring: Equatable {
        let tint: Color
        let remaining: Double?
        let stale: Bool
        var time: Double? = nil
        var low = false
        var exhausted = false
        /// "5h" or "7d" when one service's windows split the ring.
        var window: String? = nil
        var provider: AgentProvider? = nil
    }
    /// The quota value's turns: the providers in order. The ring whose
    /// provider is not showing dims.
    struct Link: Equatable {
        let order: [AgentProvider]
        let animates: Bool
    }
    let rings: [Ring]
    var layout: CompactComponentOptions.RingLayout = .concentric
    var vertical = false
    var size: CGFloat = 20
    var link: Link? = nil

    private var side: Bool { rings.count == 2 && layout == .sideBySide && !split }
    private var split: Bool { rings.count == 2 && rings.allSatisfy { $0.window != nil } }
    var frameSize: CGSize {
        let unit = size / 20
        return CGSize(width: side && !vertical ? 36 * unit : size, height: side && vertical ? 36 * unit : size)
    }

    func makeNSView(context: Context) -> QuotaRingsView { QuotaRingsView() }
    func updateNSView(_ view: QuotaRingsView, context: Context) {
        view.update(QuotaRingsView.Drawing(rings: rings.map { ring in
            .init(tint: NSColor(ring.tint), remaining: ring.remaining, stale: ring.stale, time: ring.time, low: ring.low,
                exhausted: ring.exhausted, provider: ring.provider)
        }, arrangement: split ? .split : rings.count == 1 ? .single : side ? .side : .concentric, vertical: vertical,
            size: frameSize, unit: size / 20, tick: PacerPalette.tickInk, attention: NSColor(PacerPalette.attention),
            danger: NSColor(PacerPalette.danger), link: link))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QuotaRingsView, context: Context) -> CGSize? { frameSize }
}

final class QuotaRingsView: NSView {
    struct Ring: Equatable {
        let tint: NSColor, remaining: Double?, stale: Bool, time: Double?, low: Bool, exhausted: Bool, provider: AgentProvider?
    }
    enum Arrangement: Equatable { case single, concentric, side, split }
    struct Drawing: Equatable {
        let rings: [Ring]
        let arrangement: Arrangement
        let vertical: Bool
        let size: CGSize
        let unit: CGFloat
        let tick: NSColor, attention: NSColor, danger: NSColor
        let link: QuotaRingsGlyph.Link?
    }
    private static let start = 125.0, sweep = 290.0
    private var drawing: Drawing?
    private var drawnBounds = CGRect.zero
    private var groups: [CALayer] = []
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ drawing: Drawing) {
        guard drawing != self.drawing else { return }
        self.drawing = drawing
        rebuild()
    }

    override func layout() {
        super.layout()
        if bounds != drawnBounds { rebuild() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshLink() }
                }
        }
        refreshLink()
    }

    /// The opacity each ring keeps from its own reading.
    var ringOpacities: [Float] { groups.map { $0.sublayers?.first?.opacity ?? 1 } }
    /// The linked dimming now, for tests: each ring's opacity from the rotation.
    var linkOpacities: [Float] { groups.map { ($0.presentation() ?? $0).opacity } }

    private func rebuild() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        groups.forEach { $0.removeFromSuperlayer() }; groups = []
        drawnBounds = bounds
        guard let drawing, let root = layer else { return }
        let k = drawing.unit, flipped = root.contentsAreFlipped()
        // Points are laid out top-down in a 20-point square, as the other host draws them.
        let transform = flipped ? CGAffineTransform(scaleX: k, y: k)
            : CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: 0, ty: bounds.height)
        for (index, ring) in drawing.rings.prefix(2).enumerated() {
            let group = CALayer(), body = CALayer()
            group.frame = bounds; body.frame = bounds
            group.addSublayer(body); root.addSublayer(group); groups.append(group)
            let center: CGPoint, radius: CGFloat, stroke: CGFloat, from: Double, span: Double, tick: (CGFloat, CGFloat)
            switch drawing.arrangement {
            case .split:
                center = CGPoint(x: 10, y: 10); radius = 8; stroke = 2.1
                (from, span) = index == 0 ? (204, 132) : (348, 204); tick = (5.9, 10.1)
            case .side:
                center = drawing.vertical ? CGPoint(x: 10, y: index == 0 ? 8 : 28) : CGPoint(x: index == 0 ? 8 : 28, y: 10)
                radius = 6.3; stroke = 2.1; (from, span) = (Self.start, Self.sweep); tick = (radius - 2, radius + 2)
            case .single:
                center = CGPoint(x: 10, y: 10); radius = 8.5; stroke = 3; (from, span) = (Self.start, Self.sweep); tick = (radius - 2, radius + 2)
            case .concentric:
                center = CGPoint(x: 10, y: 10); radius = index == 0 ? 8.75 : 5.45; stroke = 2.1
                (from, span) = (Self.start, Self.sweep); tick = (radius - 2, radius + 2)
            }
            body.opacity = ring.stale ? 0.5 : 1
            func arc(_ sweep: Double) -> CGPath {
                let path = CGMutablePath()
                path.addArc(center: center, radius: radius, startAngle: from * .pi / 180, endAngle: (from + sweep) * .pi / 180,
                    clockwise: false, transform: transform)
                return path
            }
            // A ring without a reading, or with an old one, has a dashed track and no tick.
            let track = CAShapeLayer()
            track.path = arc(span); track.fillColor = nil; track.lineWidth = stroke * k
            track.strokeColor = (ring.exhausted ? drawing.danger.withAlphaComponent(0.4) : ring.tint.withAlphaComponent(0.26)).cgColor
            track.lineCap = .round
            if ring.stale || ring.remaining == nil { track.lineDashPattern = [NSNumber(value: 2 * k), NSNumber(value: 5 * k)] }
            body.addSublayer(track)
            if let remaining = ring.remaining, remaining > 0.5 {
                let fill = CAShapeLayer()
                fill.path = arc(span * min(1, max(0, remaining / 100))); fill.fillColor = nil; fill.lineWidth = stroke * k
                fill.strokeColor = (ring.low ? drawing.attention : ring.tint).cgColor; fill.lineCap = .round
                body.addSublayer(fill)
            }
            if let time = ring.time, !ring.stale {
                let angle = (from + span * min(1, max(0, time))) * .pi / 180
                let line = CGMutablePath()
                line.move(to: CGPoint(x: center.x + tick.0 * cos(angle), y: center.y + tick.0 * sin(angle)), transform: transform)
                line.addLine(to: CGPoint(x: center.x + tick.1 * cos(angle), y: center.y + tick.1 * sin(angle)), transform: transform)
                let mark = CAShapeLayer()
                mark.path = line; mark.strokeColor = drawing.tick.cgColor; mark.lineWidth = 1.2 * k; mark.lineCap = .round
                body.addSublayer(mark)
            }
        }
        refreshLink()
    }

    /// The ring the rotating value is not naming dims to 42%, crossing over
    /// with the value. Without motion, or while occluded, the first value
    /// stays and so does its ring.
    private func refreshLink() {
        groups.forEach { $0.removeAnimation(forKey: "link") }
        guard let drawing, let link = drawing.link, drawing.arrangement != .split, groups.count > 1, !link.order.isEmpty else {
            groups.forEach { $0.opacity = 1 }; return
        }
        func emphasis(_ ring: Ring, _ shown: AgentProvider) -> Double { ring.provider == shown ? 1 : 0.42 }
        let rings = Array(drawing.rings.prefix(2))
        for (group, ring) in zip(groups, rings) { group.opacity = Float(emphasis(ring, link.order[0])) }
        let live = link.animates && link.order.count > 1 && window.map { $0.occlusionState.contains(.visible) || !$0.isVisible } == true
        guard live else { return }
        let slot = AlternatingQuotaText.interval, fade = AlternatingQuotaText.fade, count = link.order.count, total = slot * Double(count)
        for (group, ring) in zip(groups, rings) {
            var times: [Double] = [0], values: [Double] = [emphasis(ring, link.order[0])]
            for index in 0..<count {
                let end = slot * Double(index + 1), next = link.order[(index + 1) % count]
                times += [end - fade, end]; values += [emphasis(ring, link.order[index]), emphasis(ring, next)]
            }
            group.add(AlternatingQuotaView.loop("opacity", times: times, values: values, total: total), forKey: "link")
        }
    }
}

/// One mark of the collapsed bar's single capsule family: an outline asks to
/// be noticed, a solid fill asks to act; the color says where it comes from.
struct WarningMark: View {
    let label: String?
    let symbol: String?
    let tint: Color
    let solid: Bool
    var height: CGFloat = 15
    var dot = false

    var body: some View {
        let scale = height / 15
        Group {
            if dot {
                let side = (7 * scale * 2).rounded() / 2
                Group {
                    if solid { Circle().fill(tint) } else { Circle().strokeBorder(tint, lineWidth: 1.2 * scale) }
                }.frame(width: side, height: side)
            } else {
                Group {
                    if let label {
                        Text(label).font(.system(size: (label == "¥" ? 9.5 : 9) * scale, weight: .bold))
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 7.5 * scale, weight: .bold))
                    }
                }
                .foregroundStyle(solid ? Color.black.opacity(209 / 255) : tint)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, (solid ? 4 : 2.8) * scale)
                .frame(minWidth: height).frame(height: height)
                .background {
                    if solid { Capsule().fill(tint) } else { Capsule().strokeBorder(tint, lineWidth: 1.2 * scale) }
                }
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// The mark that stands for the warnings past the limit.
    static func more(_ count: Int, height: CGFloat, dot: Bool) -> some View {
        let scale = height / 15
        return Text("+\(count)").font(.system(size: 8.5 * scale, weight: .bold)).foregroundStyle(PacerPalette.unit)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, dot ? 0 : 3 * scale)
            .frame(minWidth: dot ? 0 : height).frame(height: dot ? (7 * scale * 2).rounded() / 2 : height)
            .background { if !dot { Capsule().strokeBorder(PacerPalette.unit, lineWidth: 1.2 * scale) } }
            .fixedSize().accessibilityHidden(true)
    }
}

/// The bar's warnings: marks that need the user lead; past the limit the rest
/// fold into one "+N" mark, and a limit of zero shows them all. A new mark
/// pops in, and one turning solid bounces once.
struct CompactWarningMarks: View {
    let items: [CompactWarningPresentation.Item]
    var style: CompactComponentOptions.WarningStyle = .capsule
    var limit = 0
    var height: CGFloat = 15
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandLayoutProbe) private var layoutProbe

    var body: some View {
        let visible = CompactWarningPresentation.visible(items, limit: limit), dot = style == .dot
        let gap = (dot ? 3 : 4) * height / 15
        let layout = vertical ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))
        layout {
            ForEach(Array(visible.shown.enumerated()), id: \.offset) { _, item in
                WarningMark(label: item.label, symbol: item.symbol, tint: Self.tint(item), solid: item.solid, height: height, dot: dot)
                    .id(item.kind.rawValue + (item.provider ?? "") + (item.solid ? ".solid" : ""))
                    .transition(reduceMotion || layoutProbe ? .identity : .scale(scale: 0.6).combined(with: .opacity))
            }
            if visible.hidden > 0 { WarningMark.more(visible.hidden, height: height, dot: dot) }
        }
        .animation(reduceMotion || layoutProbe ? nil : .spring(duration: 0.3, bounce: 0.35), value: visible.shown.map { "\($0.kind)\($0.solid)" })
    }

    static func tint(_ item: CompactWarningPresentation.Item) -> Color {
        item.provider.flatMap(AgentProvider.init(rawValue:))?.tint ?? PacerPalette.attention
    }
}

/// The 5h warning pair in the collapsed bar's capsule family: outlined below
/// 20% and solid when exhausted, tinted by provider.
struct FiveHourAlertGlyph: View {
    let alert: FiveHourQuotaAlert
    let tint: Color
    var height: CGFloat = 15

    var body: some View {
        WarningMark(label: "5h", symbol: nil, tint: tint, solid: alert == .exhausted, height: height)
    }
}

/// DeepSeek's one alert in the same family, always in DeepSeek's blue: ¥ for
/// the balance, ↑¥ for a spend spike, 日/周 for a budget.
struct DeepSeekAlertGlyph: View {
    let alert: DeepSeekAlert
    var height: CGFloat = 15

    var body: some View {
        let label: String = switch alert {
        case .spike: L10n.text("warning.label.spike")
        case .overBudget(let kind), .nearingBudget(let kind): L10n.text("deepseek.alert." + kind.rawValue)
        case .exhausted, .lowBalance: "¥"
        }
        WarningMark(label: label, symbol: nil, tint: AgentProvider.deepseek.tint, solid: alert.solid, height: height)
    }
}

/// DeepSeek's price clock. Today sits on a 24-hour face with midnight at the
/// top. At the bar's size it takes the quota rings' drawing: peak hours in
/// amber outside, today's spend per hour in blue inside, and a hand that
/// turns amber during a peak. Larger, the dial keeps its original geometry.
struct PriceClockGlyph: View {
    let hourly: [Double]
    /// Today's doubled-price spans in degrees clockwise from midnight.
    let peaks: [ClosedRange<Double>]
    let now: Double
    var dimmed = false
    var side: CGFloat = 18
    var compact = false
    var peakNow = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            if compact { drawCompact(in: &context, side: side) } else { draw(in: &context, side: side) }
        }
        .frame(width: side, height: side)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    private func drawCompact(in context: inout GraphicsContext, side: CGFloat) {
        let k = side / 20, centre = CGPoint(x: 10 * k, y: 10 * k)
        let faint = PacerPalette.overlay(28 / 255)
        for radius in [8.75, 5.45] {
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius * k, y: centre.y - radius * k, width: 2 * radius * k, height: 2 * radius * k)),
                with: .color(faint), lineWidth: 2.2 * k)
        }
        for span in peaks where span.upperBound - span.lowerBound > 4 {
            context.stroke(arc(centre, 8.75 * k, span.lowerBound + 2, span.upperBound - 2), with: .color(PacerPalette.attention),
                style: StrokeStyle(lineWidth: 2.2 * k, lineCap: .round))
        }
        let currentHour = Int(now / 15)
        for hour in 0..<min(24, hourly.count) where hourly[hour] >= 0.0005 && hour <= currentHour {
            let start = Double(hour) * 15, end = hour == currentHour ? max(start + 4, now) : start + 15
            context.stroke(arc(centre, 5.45 * k, start, end), with: .color(AgentProvider.deepseek.tint), style: StrokeStyle(lineWidth: 2.2 * k))
        }
        let radians = (now - 90) * .pi / 180
        var hand = Path()
        hand.move(to: CGPoint(x: centre.x + 2.4 * k * cos(radians), y: centre.y + 2.4 * k * sin(radians)))
        hand.addLine(to: CGPoint(x: centre.x + 9.6 * k * cos(radians), y: centre.y + 9.6 * k * sin(radians)))
        context.stroke(hand, with: .color(peakNow ? PacerPalette.attention : PacerPalette.tick), style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round))
    }

    private func draw(in context: inout GraphicsContext, side: CGFloat) {
        let k = side / 108, centre = CGPoint(x: side / 2, y: side / 2)
        context.stroke(Path(ellipseIn: CGRect(x: centre.x - 38 * k, y: centre.y - 38 * k, width: 76 * k, height: 76 * k)),
            with: .color(PacerPalette.overlay(0.16)), lineWidth: 11 * k)
        let currentHour = Int(now / 15)
        for hour in 0..<min(24, hourly.count) where hourly[hour] >= 0.0005 && hour <= currentHour {
            let start = Double(hour) * 15, end = hour == currentHour ? max(start + 4, now) : start + 15
            context.stroke(arc(centre, 38 * k, start, end), with: .color(AgentProvider.deepseek.tint), style: StrokeStyle(lineWidth: 11 * k))
        }
        for span in peaks where span.upperBound - span.lowerBound > 1 {
            context.stroke(arc(centre, 50 * k, span.lowerBound + 2, span.upperBound - 2), with: .color(PacerPalette.attention),
                style: StrokeStyle(lineWidth: 6 * k, lineCap: .round))
        }
        let radians = (now - 90) * .pi / 180
        var hand = Path()
        hand.move(to: CGPoint(x: centre.x + 26 * k * cos(radians), y: centre.y + 26 * k * sin(radians)))
        hand.addLine(to: CGPoint(x: centre.x + 51 * k * cos(radians), y: centre.y + 51 * k * sin(radians)))
        context.stroke(hand, with: .color((PacerPalette.light ? Color.white : Color.black).opacity(0.8)), style: StrokeStyle(lineWidth: 13 * k, lineCap: .round))
        context.stroke(hand, with: .color(PacerPalette.tick), style: StrokeStyle(lineWidth: 7 * k, lineCap: .round))
    }
    private func arc(_ centre: CGPoint, _ radius: CGFloat, _ start: Double, _ end: Double) -> Path {
        Path { $0.addArc(center: centre, radius: radius, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false) }
    }
}
