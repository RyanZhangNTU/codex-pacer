import SwiftUI
import PacerCore

/// Both display modes have only left and right content. A real camera needs
/// equal wings; floating headers use each side's natural width, with a
/// hairline halfway between the lanes.
struct CompactRowLayout: Layout {
    var notchWidth: CGFloat = 0
    var laneGap: CGFloat = 16
    private var cameraGap: CGFloat { notchWidth > 0 ? notchWidth + 8 : 0 }
    private func lanes(_ subviews: Subviews) -> (Int, Int)? {
        subviews.count == 3 ? (0, 2) : subviews.count == 2 ? (0, 1) : nil
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let (first, last) = lanes(subviews) else { return .zero }
        let sizes = [subviews[first], subviews[last]].map { $0.sizeThatFits(.unspecified) }
        let left = sizes[0].width, right = sizes[1].width
        let natural = cameraGap > 0 ? cameraGap + 2 * max(left, right) + 16 :
            left + right + (left > 0 && right > 0 ? laneGap : 0)
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let (first, last) = lanes(subviews) else { return }
        let views = [subviews[first], subviews[last]]
        let sizes = views.map { $0.sizeThatFits(.unspecified) }
        let both = sizes[0].width > 0 && sizes[1].width > 0
        let gap = cameraGap > 0 ? cameraGap + 16 : (both ? laneGap : 0)
        let available = max(0, bounds.width - gap)
        let total = max(1, sizes[0].width + sizes[1].width)
        let slots = cameraGap > 0 ? [available / 2, available / 2] :
            [available * sizes[0].width / total, available * sizes[1].width / total]
        var placed: [CGRect] = []
        for index in views.indices {
            let size = views[index].sizeThatFits(ProposedViewSize(width: slots[index], height: bounds.height))
            let x = index == 0 ? bounds.minX : bounds.maxX - size.width
            views[index].place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
            placed.append(CGRect(x: x, y: 0, width: size.width, height: size.height))
        }
        if subviews.count == 3 {
            let divider = subviews[1], size = divider.sizeThatFits(.unspecified)
            let middle = cameraGap > 0 || !both ? bounds.midX : (placed[0].maxX + placed[1].minX) / 2
            divider.place(at: CGPoint(x: middle - size.width / 2, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
        }
    }
}

struct CompactIslandHeader: View {
    @ObservedObject var model: IslandModel
    let layout: CompactIslandLayout
    let baseHeight: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        let metrics = model.barMetrics
        let output = model.compactPresentation()
        rowView(metrics, output: output)
            .padding(.horizontal, metrics.inset)
            .frame(height: baseHeight)
            .background {
                rowView(metrics, output: output).fixedSize().background(GeometryReader { geometry in
                    Color.clear.preference(key: CompactHeaderIdealWidth.self, value: geometry.size.width + 2 * metrics.inset)
                }).environment(\.islandLayoutProbe, true).hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
        .onPreferenceChange(CompactHeaderIdealWidth.self) { width in
            DispatchQueue.main.async { model.updateMeasuredCompactWidth(width) }
        }
        .contentShape(Rectangle())
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.barClicked { model.togglePin() } })
        .contextMenu {
            Button(L10n.text("common.settings")) { model.onSettings?() }
            Button(L10n.text("common.quit")) { model.onQuit?() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("layout.collapsed"))
    }

    private func rowView(_ metrics: CompactBarMetrics, output: CompactBarPresentation.Output) -> some View {
        let leading = layout.leading.filter { output.component($0).visible }
        let trailing = layout.trailing.filter { output.component($0).visible }
        let divided = notchWidth == 0 && !leading.isEmpty && !trailing.isEmpty
        return CompactRowLayout(notchWidth: notchWidth, laneGap: metrics.laneGap) {
            lane(leading, alignment: .leading, gap: metrics.gap, output: output)
            Rectangle().fill(divided ? PacerPalette.overlay(41 / 255) : .clear)
                .frame(width: divided ? 1 : 0, height: divided ? metrics.divider : 0).accessibilityHidden(true)
            lane(trailing, alignment: .trailing, gap: metrics.gap, output: output)
        }
    }
    private func lane(_ components: [CompactIslandLayout.Component], alignment: Alignment, gap: CGFloat,
                      output: CompactBarPresentation.Output) -> some View {
        HStack(spacing: gap) {
            ForEach(components) { component in
                CompactIslandComponent(model: model, component: component, output: output)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment).clipped()
    }
}

/// The collapsed bar on its side for a docked corner: the left lane stacks
/// above the right lane, one component per row, in a column whose height
/// follows them. Both sides keep this order, so a layout reads the same. The
/// lanes hold the column's top and bottom edges, so opening the panel draws
/// them apart with the window and closing brings them back together.
struct CompactIslandStrip: View {
    @ObservedObject var model: IslandModel
    let layout: CompactIslandLayout

    var body: some View {
        let metrics = model.barMetrics
        let output = model.compactPresentation(showsStatus: false)
        column(metrics, output: output)
            .frame(width: model.stripWidth)
            .frame(maxHeight: .infinity)
            .background {
                column(metrics, output: output).fixedSize().background(GeometryReader { geometry in
                    Color.clear.preference(key: CompactStripIdealHeight.self, value: geometry.size.height)
                }).environment(\.islandLayoutProbe, true).hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
            .onPreferenceChange(CompactStripIdealHeight.self) { height in
                DispatchQueue.main.async { model.updateMeasuredStripHeight(height) }
            }
            .contentShape(Rectangle())
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.barClicked { model.togglePin() } })
            .contextMenu {
                Button(L10n.text("common.settings")) { model.onSettings?() }
                Button(L10n.text("common.quit")) { model.onQuit?() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("layout.collapsed"))
    }

    private func column(_ metrics: CompactBarMetrics, output: CompactBarPresentation.Output) -> some View {
        let leading = layout.leading.filter { $0.showsInStrip && output.component($0).visible }
        let trailing = layout.trailing.filter { $0.showsInStrip && output.component($0).visible }
        let divided = !leading.isEmpty && !trailing.isEmpty
        return VStack(spacing: 0) {
            lane(leading, gap: metrics.stripGap, output: output)
            Spacer(minLength: divided ? metrics.laneGap / 2 : 0)
            if divided {
                Rectangle().fill(PacerPalette.overlay(41 / 255)).frame(width: metrics.divider, height: 1)
                    .padding(.bottom, metrics.laneGap / 2).accessibilityHidden(true)
            }
            lane(trailing, gap: metrics.stripGap, output: output)
        }
        .padding(.vertical, metrics.stripInset)
    }

    private func lane(_ components: [CompactIslandLayout.Component], gap: CGFloat, output: CompactBarPresentation.Output) -> some View {
        VStack(spacing: gap) {
            ForEach(components) { component in
                CompactIslandComponent(model: model, component: component, output: output, vertical: true)
            }
        }
    }
}

struct CompactIslandComponent: View {
    @ObservedObject var model: IslandModel
    let component: CompactIslandLayout.Component
    let output: CompactBarPresentation.Output
    /// Stacked for the docked strip: values sit above their units, multiple
    /// providers one above another.
    var vertical = false
    @Environment(\.islandLayoutProbe) private var layoutProbe
    private var providers: [AgentProvider] { model.enabledProviders }
    private var item: CompactBarPresentation.Component { output.component(component) }
    private var metrics: CompactBarMetrics { output.metrics ?? model.barMetrics }
    private var choices: CompactComponentOptions { output.componentOptions ?? CompactComponentOptions() }
    private var scale: CGFloat { CGFloat(metrics.scale) }

    static func isVisible(_ component: CompactIslandLayout.Component, model: IslandModel, showsStatus: Bool = true,
                          output: CompactBarPresentation.Output? = nil) -> Bool {
        if component == .tps {
            return CompactBarPresentation.rateIsVisible(context: model.compactTaskContext, attached: model.isAttached,
                strip: model.sideDock != nil, showsStatus: showsStatus, language: L10n.language)
        }
        return (output ?? model.compactPresentation(showsStatus: showsStatus)).component(component).visible
    }
    /// Alternation skips providers without a value, so an unavailable service
    /// never spends half the time as a dash; with none known, the first shows one.
    static func alternatingProviders(_ model: IslandModel) -> [AgentProvider] {
        model.compactComponent(.quota).entries.map(\.provider)
    }
    /// Enabled warnings whose condition holds now, in display order. DeepSeek
    /// shows only its most urgent alert; an empty wallet shows even when its
    /// reminder is off.
    static func activeWarnings(_ model: IslandModel) -> [CompactIslandLayout.Warning] {
        model.compactWarningItems.reduce(into: []) { result, item in
            let warning: CompactIslandLayout.Warning
            switch item.kind {
            case .fiveHour: warning = .fiveHour
            case .ssh: warning = .ssh
            case .quotaDelay: warning = .quotaDelay
            case .spike: warning = .spendSpike
            case .overBudget, .nearingBudget: warning = .budget
            case .exhausted, .lowBalance: warning = .lowBalance
            }
            if !result.contains(warning) { result.append(warning) }
        }
    }
    static func fiveHourAlerts(_ model: IslandModel) -> [(provider: AgentProvider, alert: FiveHourQuotaAlert)] {
        model.enabledProviders.compactMap { provider in
            model.fiveHourAlert(provider).map { (provider, $0) }
        }
    }
    var body: some View {
        Button(action: action) {
            Group { if vertical { stripContent } else { content } }
                .padding(.vertical, vertical ? 2 : 4).frame(maxWidth: vertical ? .infinity : nil).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .lineLimit(1)
            .accessibilityHint(help)
    }
    private var badgeOptions: ActivityBadgeOptions {
        ActivityBadgeOptions(singlePercent: output.singleTaskPercent == true, multiRing: choices.multiRing,
            multiCore: choices.multiCore, endMark: choices.endMark)
    }
    @ViewBuilder private var content: some View {
        switch component {
        case .activity:
            ActivityBadge(activity: model.headerActivity(), options: badgeOptions, size: metrics.badge)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(activitySummary)
        case .status:
            CompactStatusText(text: item.text ?? model.headerDisplayStatus, tone: item.tone,
                maxWidth: item.maxWidth ?? (108 * scale).rounded(), size: metrics.status)
        case .tps:
            CompactValueText(number: item.text ?? model.headerRateText ?? "—", unit: item.unit, metrics: metrics,
                color: model.rateIsFresh ? PacerPalette.primary : PacerPalette.secondary)
                .accessibilityElement(children: .ignore).accessibilityLabel((item.text ?? "—") + " t/s")
        case .firstOutput:
            CompactValueText(number: item.text ?? "—", unit: item.unit, metrics: metrics, color: PacerPalette.primary, glyph: .stopwatch)
                .accessibilityElement(children: .ignore).accessibilityLabel(item.accessibility)
        case .warnings:
            CompactWarningMarks(items: model.compactWarningItems, style: choices.warningStyle, limit: choices.warningLimit, height: metrics.warning)
                .accessibilityElement(children: .ignore).accessibilityLabel(warningSummary)
        case .quota:
            quotaValues
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibility.isEmpty ? quotaSummary : item.accessibility)
        case .quotaGauge:
            if output.gaugeClock { priceClock } else {
                rings
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibility.isEmpty ? gaugeSummary : item.accessibility)
            }
        case .priceClock:
            priceClock
        case .quotaLabel:
            Text(item.text ?? model.compactMetricLabel)
                .font(.system(size: metrics.unit, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
        case .timeRemaining:
            HStack(spacing: 5 * scale) {
                CompactGlyph(kind: .hourglass, scale: scale)
                ForEach(Array(item.entries.enumerated()), id: \.offset) { _, entry in
                    CompactValueText(number: entry.text, unit: nil, metrics: metrics, color: entry.provider.tint, size: metrics.value - 1,
                        splitsPercent: item.stripUnit == "%")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("provider.compact_time", entry.provider.displayName, entry.text))
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
    }
    private func valueColor(_ entry: CompactBarPresentation.Entry) -> Color {
        (entry.low == true ? PacerPalette.attention : entry.provider.tint).opacity(entry.dimmed ? 0.45 : 1)
    }
    /// The quota values in their services' colors: taking turns, side by side,
    /// or the lowest alone, as Core chose.
    @ViewBuilder private var quotaValues: some View {
        let entries = item.entries
        if entries.count > 1, choices.quotaMultiple == .pair {
            HStack(spacing: (metrics.value * 6 / 13).rounded()) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    CompactValueText(number: entry.text, unit: nil, metrics: metrics, color: valueColor(entry), splitsPercent: true)
                }
            }.fixedSize()
        } else if entries.count > 1 {
            AlternatingQuotaText(entries: entries.map { .init(text: $0.text, color: NSColor(valueColor($0))) },
                animates: !layoutProbe, font: .monospacedDigitSystemFont(ofSize: metrics.value, weight: .semibold),
                unitSize: metrics.unit, unitColor: NSColor(PacerPalette.unit))
        } else if let entry = entries.first {
            CompactValueText(number: entry.text, unit: nil, metrics: metrics, color: valueColor(entry), splitsPercent: true)
        }
    }
    /// The rotating value names one service at a time; the other ring steps
    /// back with it, unless the rings' card turned that off.
    private var ringLink: QuotaRingsGlyph.Link? {
        let shown = Set(output.leading + output.trailing)
        guard choices.ringDim, choices.quotaMultiple == .alternate, output.rings.count > 1,
              output.rings.allSatisfy({ $0.window == nil }),
              shown.contains(CompactIslandLayout.Component.quota.rawValue), shown.contains(CompactIslandLayout.Component.quotaGauge.rawValue)
        else { return nil }
        let order = output.component(.quota).entries.map(\.provider)
        return order.count > 1 ? .init(order: order, animates: !layoutProbe) : nil
    }
    private var rings: some View {
        QuotaRingsGlyph(rings: output.rings.map { ring in
            .init(tint: ring.provider.tint, remaining: ring.remaining, stale: ring.dimmed, time: ring.time, low: ring.low == true,
                exhausted: ring.exhausted == true, window: ring.window, provider: ring.provider)
        }, layout: choices.ringLayout, vertical: vertical, size: metrics.gauge, link: ringLink)
    }
    private var priceClock: some View {
        let wallet = model.deepseekWallet
        return PriceClockGlyph(hourly: wallet.hourly, peaks: wallet.peakToday.map { wallet.angle(of: $0.start)...wallet.angle(of: $0.end) },
            now: wallet.angle(of: model.now), dimmed: [.stale, .disconnected].contains(wallet.state),
            side: metrics.gauge, compact: true, peakNow: wallet.peakNow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("deepseek.clock_accessibility", L10n.text(wallet.peakNow ? "deepseek.now.peak" : "deepseek.now.offpeak"),
                DeepSeekDayDial.amount(wallet.todayTotal)))
    }
    /// The strip's stacked forms: each number sits above its unit, sized for
    /// the strip; a value wider than the strip shrinks to fit.
    @ViewBuilder private var stripContent: some View {
        switch component {
        case .tps:
            CompactStripValue(number: item.stripText ?? "—", unit: item.stripUnit, metrics: metrics, width: model.stripWidth,
                color: model.rateIsFresh ? PacerPalette.primary : PacerPalette.secondary)
        case .firstOutput:
            CompactStripValue(number: item.stripText ?? "—", unit: item.stripUnit, metrics: metrics, width: model.stripWidth,
                color: PacerPalette.primary, glyph: .stopwatch)
                .accessibilityElement(children: .ignore).accessibilityLabel(item.accessibility)
        case .quota:
            let entries = item.entries
            VStack(spacing: 0) {
                if entries.count > 1, choices.quotaMultiple == .pair {
                    VStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in stripNumber(entry.stripText, color: valueColor(entry)) }
                    }
                } else if entries.count > 1 {
                    AlternatingQuotaText(entries: entries.map { .init(text: $0.stripText, color: NSColor(valueColor($0)), splitsUnit: false) },
                        animates: !layoutProbe, font: .monospacedDigitSystemFont(ofSize: metrics.stripValue, weight: .semibold),
                        centered: true, maxWidth: max(16, model.stripWidth - 6))
                } else if let entry = entries.first {
                    stripNumber(entry.stripText, color: valueColor(entry))
                }
                if let unit = item.stripUnit { stripUnit(unit) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibility.isEmpty ? quotaSummary : item.accessibility)
        case .timeRemaining:
            VStack(spacing: 1) {
                CompactGlyph(kind: .hourglass, scale: scale).padding(.bottom, scale)
                ForEach(Array(item.entries.enumerated()), id: \.offset) { _, entry in
                    stripNumber(entry.stripText, color: entry.provider.tint, size: metrics.stripValue - 0.5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("provider.compact_time", entry.provider.displayName, entry.text))
                }
                if let unit = item.stripUnit { stripUnit(unit) }
            }
        case .warnings:
            CompactWarningMarks(items: model.compactWarningItems, style: choices.warningStyle, limit: choices.warningLimit,
                height: metrics.warning, vertical: true)
                .accessibilityElement(children: .ignore).accessibilityLabel(warningSummary)
        default:
            content
        }
    }
    private func stripNumber(_ text: String, color: Color, size: Double? = nil) -> some View {
        Text(text).font(.system(size: size ?? metrics.stripValue, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: max(16, model.stripWidth - 6))
    }
    private func stripUnit(_ text: String) -> some View {
        Text(text).font(.system(size: metrics.stripUnit, weight: .medium)).foregroundStyle(PacerPalette.unit)
    }
    private var warningSummary: String { CompactWarningPresentation.summary(model.compactWarningItems) }
    private var quotaSummary: String {
        providers.map { L10n.text("provider.compact_quota", $0.displayName, model.compactQuotaText($0)) }.joined(separator: ", ")
    }
    private var gaugeSummary: String {
        output.rings.map(\.provider).map { provider in
            if provider == .deepseek {
                let budget = model.deepseekWallet.ringBudget(prefer: model.deepseekRingPeriod)
                return L10n.text("provider.compact_quota", provider.displayName, budget.map { DeepSeekWallet.compactRemaining($0.remaining) } ?? "—")
            }
            let remaining = model.providerSelectedWindow(provider)?.remainingPercent
            return L10n.text("provider.compact_quota", provider.displayName, remaining.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—")
        }.joined(separator: " · ")
    }
    /// The count and the most urgent state, without repeating a count-only status.
    private var activitySummary: String {
        let count = model.running.count + model.waiting.count
        let tasks = count == 0 ? nil : L10n.text(count == 1 ? "activity.task_count_compact_singular" : "activity.task_count_compact",
            count > 99 ? "99+" : String(count))
        return [tasks, model.headerStatus].compactMap { $0 }.reduce(into: [String]()) { parts, part in
            if !parts.contains(part) { parts.append(part) }
        }.joined(separator: " · ")
    }
    private var help: String {
        switch component {
        case .activity, .status:
            return L10n.text(model.pendingInputRequests.isEmpty && model.pendingCompletions.isEmpty ? "activity.header_pin" : "activity.header_open",
                component == .activity ? activitySummary : model.headerStatus)
        case .tps: return item.help.isEmpty ? model.rateHelp : item.help
        case .priceClock: return ""
        case .quotaGauge: return output.gaugeClock ? "" : item.help
        default: return item.help
        }
    }
    private func action() {
        model.barClicked {
            switch component {
            case .activity, .status: model.openCompletionOrPin()
            default: model.togglePin()
            }
        }
    }
}

/// The bar's one typesetting: a value in tabular figures, its unit one step
/// smaller in the unit color on the same baseline, optionally after a glyph.
struct CompactValueText: View {
    let number: String
    let unit: String?
    let metrics: CompactBarMetrics
    let color: Color
    var glyph: CompactGlyph.Kind? = nil
    var size: Double? = nil
    /// A trailing "%" draws as the unit.
    var splitsPercent = false

    var body: some View {
        let scale = CGFloat(metrics.scale)
        let percent = splitsPercent && number.count > 1 && number.hasSuffix("%")
        let shown = percent ? String(number.dropLast()) : number, sign = percent ? "%" : unit
        HStack(spacing: 4 * scale) {
            if let glyph { CompactGlyph(kind: glyph, scale: scale) }
            HStack(alignment: .firstTextBaseline, spacing: 1.5 * scale) {
                Text(shown).font(.system(size: size ?? metrics.value, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                if let sign, !sign.isEmpty {
                    Text(sign).font(.system(size: metrics.unit, weight: .medium)).foregroundStyle(PacerPalette.unit)
                }
            }
        }
        .fixedSize()
    }
}

/// A strip cell: the glyph, the number and its unit stacked.
struct CompactStripValue: View {
    let number: String
    let unit: String?
    let metrics: CompactBarMetrics
    let width: CGFloat
    let color: Color
    var glyph: CompactGlyph.Kind? = nil

    var body: some View {
        let scale = CGFloat(metrics.scale)
        VStack(spacing: 0) {
            if let glyph { CompactGlyph(kind: glyph, scale: scale).padding(.bottom, 2 * scale) }
            Text(number).font(.system(size: metrics.stripValue, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: max(16, width - 6))
            if let unit, !unit.isEmpty {
                Text(unit).font(.system(size: metrics.stripUnit, weight: .medium)).foregroundStyle(PacerPalette.unit)
            }
        }
    }
}

/// Line glyphs in the unit color: a stopwatch for first output and an
/// hourglass for time remaining.
struct CompactGlyph: View {
    enum Kind { case stopwatch, hourglass }
    let kind: Kind
    var scale: CGFloat = 1

    var body: some View {
        let box = kind == .stopwatch ? CGSize(width: 11, height: 12) : CGSize(width: 9, height: 12)
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.stroke(Self.path(kind), with: .color(PacerPalette.unit),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: box.width * scale, height: box.height * scale)
        .accessibilityHidden(true)
    }

    static func path(_ kind: Kind) -> Path {
        var path = Path()
        func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
        switch kind {
        case .stopwatch:
            line(CGPoint(x: 5.5, y: 1.2), CGPoint(x: 5.5, y: 2.6))
            line(CGPoint(x: 4.2, y: 1.2), CGPoint(x: 6.8, y: 1.2))
            line(CGPoint(x: 5.5, y: 7.1), CGPoint(x: 5.5, y: 5))
            line(CGPoint(x: 9, y: 3.7), CGPoint(x: 9.8, y: 2.9))
            path.addEllipse(in: CGRect(x: 5.5 - 4.3, y: 6.9 - 4.3, width: 8.6, height: 8.6))
        case .hourglass:
            line(CGPoint(x: 1, y: 0.8), CGPoint(x: 8, y: 0.8))
            line(CGPoint(x: 1, y: 11.2), CGPoint(x: 8, y: 11.2))
            path.move(to: CGPoint(x: 1.8, y: 0.8))
            path.addCurve(to: CGPoint(x: 6.5, y: 6), control1: CGPoint(x: 1.8, y: 3.7), control2: CGPoint(x: 6.5, y: 4.1))
            path.addCurve(to: CGPoint(x: 1.8, y: 11.2), control1: CGPoint(x: 6.5, y: 7.9), control2: CGPoint(x: 1.8, y: 8.3))
            path.move(to: CGPoint(x: 7.2, y: 0.8))
            path.addCurve(to: CGPoint(x: 2.5, y: 6), control1: CGPoint(x: 7.2, y: 3.7), control2: CGPoint(x: 2.5, y: 4.1))
            path.addCurve(to: CGPoint(x: 7.2, y: 11.2), control1: CGPoint(x: 2.5, y: 7.9), control2: CGPoint(x: 7.2, y: 8.3))
        }
        return path
    }
}

/// Status words that fade at their end instead of being cut, color only what
/// needs the user, and slide in when they change. Changes that follow within
/// 1.5 seconds of the previous one switch in place, so a burst never flickers
/// and nothing is held for later.
struct CompactStatusText: View {
    let text: String
    let tone: String?
    let maxWidth: Double
    let size: Double
    @State private var shown: String?
    @State private var lastChange = Date.distantPast
    @Environment(\.islandLayoutProbe) private var layoutProbe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let settle: TimeInterval = 1.5
    private var ink: Color { tone == "attention" ? PacerPalette.attention : tone == "failed" ? PacerPalette.danger : PacerPalette.primary }
    static func naturalWidth(_ text: String, size: Double) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width)
    }

    var body: some View {
        let current = layoutProbe ? text : shown ?? text
        let natural = Self.naturalWidth(current, size: size), limit = CGFloat(maxWidth)
        let fades = natural > limit + 0.5
        ZStack(alignment: .leading) {
            Text(current).font(.system(size: size, weight: .medium)).foregroundStyle(ink)
                .fixedSize()
                .id(current)
                .transition(.asymmetric(insertion: .offset(y: 6).combined(with: .opacity),
                    removal: .offset(y: -6).combined(with: .opacity)))
        }
        .frame(width: min(natural, limit), alignment: .leading)
        .clipped()
        // Past the widest it may draw, the end fades out instead of being cut.
        .mask {
            LinearGradient(stops: fades ? [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing)
        }
        .onChange(of: text) { previous, next in
            let slide = !layoutProbe && !reduceMotion && !previous.isEmpty && Date().timeIntervalSince(lastChange) >= Self.settle
            lastChange = Date()
            if slide { withAnimation(.easeOut(duration: 0.25)) { shown = next } } else { shown = next }
        }
        .accessibilityLabel(text)
    }
}

struct CompactStripIdealHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CompactHeaderIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Free Move: dragging the collapsed bar moves the island. The drag starts
/// only after the pointer travels a few points, so a click still pins the
/// island or opens a task; the panel follows the pointer from there. The
/// notch island does not move.
struct IslandMoveGesture: ViewModifier {
    @ObservedObject var model: IslandModel
    @State private var size = CGSize.zero
    @State private var started = false

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { size = geometry.size }
                    .onChange(of: geometry.size) { _, value in size = value }
            })
            .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
                    guard !started else { return }
                    started = true
                    let grab = CGPoint(x: size.width > 0 ? min(1, max(0, value.startLocation.x / size.width)) : 0.5,
                        y: size.height > 0 ? min(1, max(0, value.startLocation.y / size.height)) : 0.5)
                    model.onBeginMove?(grab)
                }
                .onEnded { _ in
                    started = false
                    model.onEndMoveGesture?()
                }, including: model.canMoveIsland ? .all : .subviews)
    }
}
