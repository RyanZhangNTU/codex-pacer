import PacerCore
import SwiftUI

extension DeepSeekWallet {
    /// Degrees clockwise from midnight at the top, through the local day.
    func angle(of date: Date) -> Double {
        guard day.duration > 0 else { return 0 }
        return min(360, max(0, date.timeIntervalSince(day.start) / day.duration * 360))
    }
}

/// DeepSeek's time dial is a day on a 24-hour face rather than a share of a
/// quota window: one segment per local hour, thicker for the hours that cost
/// more, an amber bezel over the doubled-price hours and the white tick for
/// now. The balance sits in the middle with how long it lasts under it.
struct DeepSeekDayDial: View {
    @ObservedObject var model: IslandModel
    let wallet: DeepSeekWallet
    let size: CGFloat

    private var scale: CGFloat { size / 108 }
    private var presentation: DeepSeekDialPresentation {
        .init(wallet: wallet, at: model.now, refreshing: model.deepseekRefreshing,
            needsConnection: model.deepseekConnectionNeeded || model.deepseekBalanceMode == nil,
            apiKey: model.deepseekBalanceMode == .apiKey)
    }
    private var connectTitle: String? { presentation.connectTitle }

    var body: some View {
        ZStack {
            DeepSeekDialFace(hourly: wallet.hourly, peak: wallet.peakToday.map { wallet.angle(of: $0.start)...wallet.angle(of: $0.end) },
                now: wallet.angle(of: model.now), color: segmentColor)
                .opacity(presentation.dimmedFace ? 0.55 : 1)
            centre
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(help)
    }

    @ViewBuilder private var centre: some View {
        if wallet.balance != nil {
            VStack(spacing: 2 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("¥").font(.system(size: 10 * scale, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                    Text(presentation.balanceWhole).font(.system(size: 21 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(presentation.balanceTone.color)
                    Text(presentation.balanceCents).font(.system(size: 9 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(PacerPalette.secondary)
                }
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(subtitle).font(.system(size: max(9, 8.6 * scale), weight: .medium)).monospacedDigit()
                    .foregroundStyle(subtitleColor).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: size * 0.68)
        } else {
            VStack(spacing: 5 * scale) {
                Text("—").font(.system(size: 18 * scale, weight: .semibold, design: .rounded)).foregroundStyle(PacerPalette.tertiary)
                if let connectTitle {
                    QuotaLinkButton(title: connectTitle, prominent: true) { model.connectDeepSeek() }
                } else {
                    Text(model.deepseekRefreshing ? L10n.text("deepseek.reading") : todayText)
                        .font(.system(size: max(9, 8.6 * scale), weight: .medium)).monospacedDigit()
                        .foregroundStyle(PacerPalette.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: size * 0.72)
        }
    }

    private var todayText: String { presentation.todayText }
    private var subtitle: String { presentation.subtitle }
    private var subtitleColor: Color { presentation.subtitleTone.color }
    private var segmentColor: Color { presentation.segmentTone.color }
    private var help: String { presentation.help }
    private var accessibilityLabel: String { presentation.accessibilityLabel }
    static func amount(_ value: Double) -> String { DeepSeekDialPresentation.amount(value) }
}

extension DeepSeekDialPresentation.Tone {
    var color: Color {
        switch self {
        case .primary: PacerPalette.primary
        case .secondary: PacerPalette.secondary
        case .tertiary: PacerPalette.tertiary
        case .attention: PacerPalette.attention
        case .danger: PacerPalette.danger
        case .provider: AgentProvider.deepseek.tint
        case .staleSegment: PacerPalette.light ? Color(white: 0.72) : Color(white: 0.36)
        }
    }

}

/// The face alone, also drawn small in Help. Angles run clockwise from
/// midnight at the top; `peak` holds the doubled-price spans of today.
struct DeepSeekDialFace: View {
    let hourly: [Double]
    let peak: [ClosedRange<Double>]
    let now: Double
    var color: Color = AgentProvider.deepseek.tint

    var body: some View {
        Canvas { context, canvas in draw(in: &context, side: min(canvas.width, canvas.height)) }
            .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, side: CGFloat) {
        let k = side / 108, centre = CGPoint(x: side / 2, y: side / 2), radius = side / 2 - 9 * k
        let largest = max(0.01, hourly.max() ?? 0), currentHour = Int(now / 15)
        for hour in 0..<24 {
            let start = Double(hour) * 15 + 1.6, end = Double(hour) * 15 + 13.4
            context.stroke(arc(centre, radius, start, end), with: .color(PacerPalette.track),
                style: StrokeStyle(lineWidth: 2.2 * k, lineCap: .round))
            let spent = hour < hourly.count ? hourly[hour] : 0
            guard spent >= 0.0005, hour <= currentHour else { continue }
            let stop = hour == currentHour ? min(end, max(start + 1, now)) : end
            context.stroke(arc(centre, radius, start, stop), with: .color(color),
                style: StrokeStyle(lineWidth: (2.4 + 4.2 * CGFloat(spent / largest)) * k, lineCap: .butt))
        }
        for span in peak where span.upperBound - span.lowerBound > 1.6 {
            context.stroke(arc(centre, radius + 6.2 * k, span.lowerBound + 0.8, span.upperBound - 0.8),
                with: .color(PacerPalette.attention.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round))
        }
        let radians = (now - 90) * .pi / 180
        var tick = Path()
        tick.move(to: CGPoint(x: centre.x + (radius - 5 * k) * cos(radians), y: centre.y + (radius - 5 * k) * sin(radians)))
        tick.addLine(to: CGPoint(x: centre.x + (radius + 5 * k) * cos(radians), y: centre.y + (radius + 5 * k) * sin(radians)))
        context.stroke(tick, with: .color(PacerPalette.tickEdge), style: StrokeStyle(lineWidth: max(1.2, 2.4 * k), lineCap: .round))
        context.stroke(tick, with: .color(PacerPalette.tick), style: StrokeStyle(lineWidth: max(1, 1.7 * k), lineCap: .round))
    }
    private func arc(_ centre: CGPoint, _ radius: CGFloat, _ start: Double, _ end: Double) -> Path {
        Path { $0.addArc(center: centre, radius: radius, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false) }
    }
}

/// "×2 until 18:00" while prices are doubled.
struct DeepSeekPeakChip: View {
    let wallet: DeepSeekWallet
    let now: Date
    var compact = false

    var body: some View {
        if wallet.peakNow {
            HStack(spacing: 4) {
                Text("×2").fontWeight(.bold)
                if !compact, let change = wallet.nextPriceChange {
                    Text(L10n.text("deepseek.peak_until", L10n.moment(change, relativeTo: now))).fontWeight(.medium)
                }
            }
            .font(.system(size: compact ? 10 : 11)).monospacedDigit()
            .foregroundStyle(PacerPalette.attention)
            .padding(.horizontal, compact ? 5 : 8).frame(height: compact ? 15 : 20)
            .background(PacerPalette.attention.opacity(0.14), in: Capsule())
            .accessibilityHint(L10n.text("deepseek.peak_hours_help"))
        }
    }
}

/// A budget period read like a quota ring: what is left, the time left as a
/// white tick, pace and where the spend so far leads.
struct DeepSeekBudgetReading {
    let period: DeepSeekBudgetPeriod
    let now: Date
    private var presentation: DeepSeekSoloPresentation.Budget { DeepSeekSoloPresentation.budget(period, at: now) }
    var fraction: Double { presentation.fraction }
    var timeFraction: Double? { presentation.timeFraction }
    var verdict: QuotaPaceVerdict? { presentation.verdict }
    var pressing: Bool { presentation.pressing }
    var tint: Color { presentation.exceeded ? PacerPalette.danger : period.kind == .day && pressing ? PacerPalette.attention : AgentProvider.deepseek.tint }
    var valueColor: Color { presentation.exceeded ? PacerPalette.danger : pressing ? PacerPalette.attention : PacerPalette.primary }
    var paceText: String { presentation.paceText }
    var countdown: String { presentation.countdown }
    var resetText: String { presentation.resetText }
    var projection: (text: String, warns: Bool)? { presentation.projectionText.map { ($0, presentation.projectionWarns) } }
    var label: String { presentation.label }
    var amount: (whole: String, cents: String) { (presentation.whole, presentation.cents) }
}

/// Budgets as a ring: today on the upper arc and the week on the lower one,
/// like Codex's 5h and week; one budget alone is a gauge named in its opening.
struct DeepSeekBudgetDial: View {
    let wallet: DeepSeekWallet
    let now: Date
    let size: CGFloat

    private var scale: CGFloat { size / 104 }
    private var lineWidth: CGFloat { 6 * scale }

    var body: some View {
        ZStack {
            if let daily = wallet.daily, let weekly = wallet.weekly {
                let today = DeepSeekBudgetReading(period: daily, now: now), week = DeepSeekBudgetReading(period: weekly, now: now)
                arc(today, .fiveHour)
                arc(week, .weekly)
                VStack(spacing: 6 * scale) {
                    value(today, size: 17 * scale, period: L10n.text("deepseek.ring.day"))
                    value(week, size: 21 * scale, period: L10n.text("deepseek.ring.week"))
                }.frame(maxWidth: size * 0.74)
            } else if let period = wallet.daily ?? wallet.weekly {
                let reading = DeepSeekBudgetReading(period: period, now: now)
                arc(reading, .gauge)
                value(reading, size: 23 * scale, period: nil).frame(maxWidth: size * 0.74).offset(y: -4 * scale)
                Text(reading.label).font(.system(size: 10 * max(1, scale * 0.9), weight: .semibold))
                    .foregroundStyle(reading.period.exceeded ? PacerPalette.danger : reading.pressing ? PacerPalette.attention : PacerPalette.secondary)
                    .position(x: size / 2, y: size * 0.91)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }

    private func arc(_ reading: DeepSeekBudgetReading, _ geometry: QuotaRingGeometry) -> some View {
        DeepSeekBudgetRing(reading: reading, geometry: geometry, lineWidth: lineWidth).frame(width: size, height: size)
    }

    private func value(_ reading: DeepSeekBudgetReading, size: CGFloat, period: String?) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let period {
                    Text(period).font(.system(size: max(8, 9 * scale), weight: .medium))
                        .foregroundStyle(reading.pressing ? PacerPalette.attention : PacerPalette.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(reading.amount.whole).font(.system(size: size, weight: .semibold, design: .rounded)).foregroundStyle(reading.valueColor)
                    Text(reading.amount.cents).font(.system(size: size * 0.45, weight: .semibold, design: .rounded)).foregroundStyle(PacerPalette.secondary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
            Text(reading.countdown).font(.system(size: max(8.5, 9 * scale), weight: .medium)).monospacedDigit()
                .foregroundStyle(PacerPalette.tertiary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityHint([reading.label, L10n.text("deepseek.resets_in", reading.countdown), reading.projection?.text].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// One budget arc on its ring, drawn at the dial's full size.
private struct DeepSeekBudgetRing: View {
    let reading: DeepSeekBudgetReading
    let geometry: QuotaRingGeometry
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let path = Path { path in
                path.addArc(center: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2), radius: (side - lineWidth) / 2,
                    startAngle: .degrees(geometry.startDegrees), endAngle: .degrees(geometry.angle(at: 1)), clockwise: false)
            }
            ZStack {
                path.stroke(reading.period.exceeded ? PacerPalette.danger.opacity(0.3) : PacerPalette.track,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if reading.fraction > 0 {
                    path.trim(from: 0, to: reading.fraction).stroke(reading.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
                if let time = reading.timeFraction {
                    Capsule().fill(PacerPalette.tick)
                        .overlay(Capsule().stroke(PacerPalette.tickEdge, lineWidth: 0.5))
                        .frame(width: 2.5, height: lineWidth + 6)
                        .offset(y: -(side - lineWidth) / 2)
                        .rotationEffect(.degrees(geometry.angle(at: time) + 90))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The dial in a row of providers, named like the other rings.
struct DeepSeekDialCell: View {
    @ObservedObject var model: IslandModel
    let size: CGFloat
    /// Overview's card already names the service above the dial.
    var showsName = true

    var body: some View {
        let wallet = model.deepseekWallet
        let budget = model.deepseekShowsBudgetDial
        VStack(spacing: 6) {
            VStack(spacing: 8) {
                if budget { DeepSeekBudgetDial(wallet: wallet, now: model.now, size: size) }
                else { DeepSeekDayDial(model: model, wallet: wallet, size: size) }
                HStack(spacing: 5) {
                    if showsName {
                        Text(AgentProvider.deepseek.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.primary)
                    }
                    if budget {
                        let reading = (wallet.daily ?? wallet.weekly).map { DeepSeekBudgetReading(period: $0, now: model.now) }
                        if let verdict = reading?.verdict, verdict == .fast { QuotaVerdictChip(verdict: verdict) }
                    } else if wallet.state == .stale, wallet.balance != nil {
                        Image(systemName: StatusSymbols.freshness).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PacerPalette.attention).accessibilityLabel(L10n.text("common.not_updated"))
                    } else {
                        DeepSeekPeakChip(wallet: wallet, now: model.now, compact: true)
                    }
                }.frame(height: 15)
            }
            DeepSeekBalanceStatusView(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Recovery under the dial. A missing sign-in or key is offered in the dial.
struct DeepSeekBalanceStatusView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let presentation = DeepSeekBalanceStatusPresentation(error: model.deepseekBalanceError, refreshing: model.deepseekRefreshing) {
            VStack(spacing: 6) {
                Text(presentation.message).font(.system(size: 11))
                    .foregroundStyle(presentation.tone == .secondary ? PacerPalette.secondary : PacerPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                if !presentation.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(presentation.actions, id: \.kind) { action in
                            QuotaLinkButton(title: action.title) {
                                if action.kind == .retry { model.refreshDeepSeekBalance(force: true) }
                                else { model.openSettings(for: .deepseek) }
                            }.disabled(!action.enabled)
                        }
                    }
                }
            }.multilineTextAlignment(.center)
        }
    }
}

/// DeepSeek alone: the time or budget dial with today or the budgets and speed
/// beside it. Detailed adds where today's money went and the week; each block
/// shows only with something to say, so a quiet day makes a short panel.
struct DeepSeekSoloDashboard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wallet = model.deepseekWallet
        let budget = model.deepseekShowsBudgetDial
        let detailed = model.deepseekPanelStyle == .detailed
        let presentation = model.deepseekSoloPresentation
        let moving = presentation.speed != nil, spent = presentation.distribution != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 20) {
                VStack(spacing: 8) {
                    if budget { DeepSeekBudgetDial(wallet: wallet, now: model.now, size: 132) }
                    else { DeepSeekDayDial(model: model, wallet: wallet, size: 132) }
                    DeepSeekPeakChip(wallet: wallet, now: model.now)
                }
                // The time dial's column is short, so where the money went joins it.
                VStack(alignment: .leading, spacing: 12) {
                    if budget { DeepSeekBudgetDetails(wallet: wallet, now: model.now) } else { todayRow(wallet) }
                    if moving { DeepSeekSpeedRow(wallet: wallet) }
                    if detailed, !budget, spent { DeepSeekWhereItWent(model: model, wallet: wallet) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if detailed {
                if budget, spent { DeepSeekWhereItWent(model: model, wallet: wallet) }
                if DeepSeekWeekChart.hasHistory(wallet) { DeepSeekWeekChart(wallet: wallet, now: model.now) }
            }
            DeepSeekBalanceStatusView(model: model).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.bottom, 4)
    }

    private func todayRow(_ wallet: DeepSeekWallet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.deepseekSoloPresentation.todayLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
            Text(model.deepseekSoloPresentation.todayText).font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(PacerPalette.primary).monospacedDigit()
                .accessibilityHint(model.deepseekSoloPresentation.todayHelp)
        }
    }
}

/// The left column's labels share one width in the current language.
enum DeepSeekColumn {
    static let labelWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        return ["deepseek.speed", "deepseek.group.today"]
            .map { ceil((L10n.text($0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 30
    }()
    static func label(_ key: String) -> some View {
        Text(L10n.text(key)).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
            .frame(width: labelWidth, alignment: .leading).lineLimit(1)
    }
}

/// Spend in each 10-minute span of the last two hours, the newest brightest,
/// with the spend-spike line dashed in red.
struct DeepSeekSpeedRow: View {
    let wallet: DeepSeekWallet
    var body: some View {
        if let value = DeepSeekSoloPresentation.speed(wallet) {
            HStack(spacing: 10) {
                DeepSeekColumn.label("deepseek.speed")
                Canvas { context, size in draw(value, in: &context, size: size) }.frame(height: 22)
                Text(value.rateText).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(value.spiking ? PacerPalette.danger : PacerPalette.secondary).fixedSize()
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(value.accessibilityLabel).accessibilityHint(value.help)
        }
    }
    private func draw(_ value: DeepSeekSoloPresentation.Speed, in context: inout GraphicsContext, size: CGSize) {
        let step = size.width / CGFloat(max(1, value.fractions.count)), width = step * 0.68
        for (index, fraction) in value.fractions.enumerated() {
            let height = max(1, CGFloat(fraction) * size.height)
            context.fill(Path(CGRect(x: CGFloat(index) * step + (step - width) / 2, y: size.height - height, width: width, height: height)),
                with: .color(AgentProvider.deepseek.tint.opacity(index == value.fractions.count - 1 ? 1 : 0.5)))
        }
        guard let fraction = value.lineFraction else { return }
        let y = size.height - CGFloat(fraction) * size.height
        var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(line, with: .color(PacerPalette.danger.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}

/// Both budgets beside the split ring, facing their arcs; one budget gets rows.
struct DeepSeekBudgetDetails: View {
    let wallet: DeepSeekWallet
    let now: Date

    var body: some View {
        if let daily = wallet.daily, let weekly = wallet.weekly {
            VStack(alignment: .leading, spacing: 9) {
                period(DeepSeekBudgetReading(period: daily, now: now))
                Rectangle().fill(PacerPalette.hairline).frame(height: 1)
                period(DeepSeekBudgetReading(period: weekly, now: now))
            }
        } else if let only = wallet.daily ?? wallet.weekly {
            let reading = DeepSeekBudgetReading(period: only, now: now)
            VStack(spacing: 0) {
                if only.exceeded {
                    row(reading.label) {
                        chip(L10n.text("deepseek.over"), PacerPalette.danger)
                        Text(DeepSeekDayDial.amount(only.spent) + " / " + DeepSeekWallet.compactSpend(only.limit))
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(PacerPalette.danger)
                    }
                } else {
                    row(L10n.text("dashboard.pace")) {
                        if let verdict = reading.verdict { QuotaVerdictChip(verdict: verdict) }
                        Text(reading.paceText).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(reading.verdict == .fast ? PacerPalette.attention : PacerPalette.primary)
                    }
                }
                Rectangle().fill(PacerPalette.hairline).frame(height: 1)
                row(L10n.text("dashboard.reset")) {
                    Text(reading.resetText).font(.system(size: 11, weight: .medium)).foregroundStyle(PacerPalette.primary)
                }
                Rectangle().fill(PacerPalette.hairline).frame(height: 1)
                if only.exceeded {
                    row(L10n.text("deepseek.reminder_row")) {
                        Text(L10n.text("deepseek.remind_only")).font(.system(size: 11)).foregroundStyle(PacerPalette.secondary)
                    }
                } else {
                    row(L10n.text("dashboard.projection")) {
                        Text(reading.projection?.text ?? "—").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(reading.projection?.warns == true ? PacerPalette.attention : PacerPalette.primary)
                    }
                }
            }
        }
    }

    private func period(_ reading: DeepSeekBudgetReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(reading.label).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(reading.period.exceeded ? PacerPalette.danger : reading.pressing ? PacerPalette.attention : PacerPalette.secondary)
                if reading.period.exceeded { chip(L10n.text("deepseek.over"), PacerPalette.danger) }
                else if let verdict = reading.verdict { QuotaVerdictChip(verdict: verdict) }
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(L10n.text("dashboard.pace")).font(.system(size: 10)).foregroundStyle(PacerPalette.secondary)
                    Text(reading.paceText).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(reading.verdict == .fast ? PacerPalette.attention : PacerPalette.primary)
                }
            }.frame(height: 16)
            HStack(spacing: 6) {
                Text(reading.resetText)
                Spacer(minLength: 6)
                if let projection = reading.projection {
                    Text(projection.text).foregroundStyle(projection.warns ? PacerPalette.attention : PacerPalette.tertiary)
                }
            }
            .font(.system(size: 10)).foregroundStyle(PacerPalette.tertiary)
        }
        .monospacedDigit().lineLimit(1)
        .accessibilityElement(children: .combine)
    }
    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 5).frame(height: 15).background(color, in: Capsule())
    }
    private func row<Value: View>(_ key: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 11)).foregroundStyle(PacerPalette.secondary)
            Spacer(minLength: 6)
            value()
        }.frame(height: 26).monospacedDigit().lineLimit(1)
    }
}

/// Where today's money went: the largest tasks, the rest, and what the
/// account was charged with no task on this Mac, hatched.
struct DeepSeekWhereItWent: View {
    @ObservedObject var model: IslandModel
    let wallet: DeepSeekWallet

    private typealias Part = DeepSeekSoloPresentation.Part
    private var distribution: DeepSeekSoloPresentation.Distribution? {
        DeepSeekSoloPresentation.distribution(wallet, hideProjects: model.hideProjects, taskTitle: model.deepseekTaskTitle)
    }
    private var parts: [Part] { distribution?.parts ?? [] }

    var body: some View {
        let parts = self.parts
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("deepseek.where")).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
            GeometryReader { proxy in
                let available = proxy.size.width - CGFloat(max(0, parts.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        segment(part).frame(width: max(4, available * CGFloat(part.fraction)))
                            .accessibilityHint(part.help)
                    }
                }
            }.frame(height: 10)
            legend(parts)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func segment(_ part: Part) -> some View {
        if part.elsewhere {
            RoundedRectangle(cornerRadius: 3).fill(PacerPalette.overlay(0.12))
                .overlay(Canvas { context, size in
                    var x: CGFloat = -size.height
                    while x < size.width {
                        var line = Path(); line.move(to: CGPoint(x: x, y: size.height)); line.addLine(to: CGPoint(x: x + size.height, y: 0))
                        context.stroke(line, with: .color(PacerPalette.overlay(0.45)), lineWidth: 1.4)
                        x += 4.5
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 3)))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(AgentProvider.deepseek.tint.opacity(part.opacity))
        }
    }

    private func legend(_ parts: [Part]) -> some View {
        FlowRow(spacing: 12, lineSpacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(part.elsewhere ? PacerPalette.overlay(0.4) : AgentProvider.deepseek.tint.opacity(max(0.32, part.opacity)))
                        .frame(width: 7, height: 7)
                    Text(part.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140, alignment: .leading).fixedSize()
                    Text(part.amountText).foregroundStyle(PacerPalette.primary)
                    if part.elsewhere {
                        // A popover would leave the panel and collapse it, so the
                        // mark opens the usage page; the user guide explains what
                        // "not on this Mac" covers.
                        Button { NSWorkspace.shared.open(IslandModel.deepseekUsageURL) } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).foregroundStyle(PacerPalette.tertiary)
                            .accessibilityHint(L10n.text("deepseek.elsewhere_help"))
                            .accessibilityLabel(L10n.text("deepseek.usage_link"))
                    }
                }
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(PacerPalette.secondary).monospacedDigit()
    }
}

/// Lays out views left to right and wraps them onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// One bar a day for the last week in DeepSeek's blue, against the daily
/// budget's dashed line with the part over it in red; without a budget the
/// line is the daily average.
struct DeepSeekWeekChart: View {
    let wallet: DeepSeekWallet
    let now: Date
    private static let height: CGFloat = 44
    static func hasHistory(_ wallet: DeepSeekWallet) -> Bool { DeepSeekSoloPresentation.week(wallet) != nil }
    var body: some View {
        if let value = DeepSeekSoloPresentation.week(wallet) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(value.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
                    Spacer(minLength: 8)
                    if let text = value.lineText {
                        Text(text).font(.system(size: 9)).foregroundStyle(PacerPalette.tertiary).monospacedDigit()
                    }
                }
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(value.days.enumerated()), id: \.offset) { _, day in bar(day) }
                    }
                    if let fraction = value.lineFraction {
                        GeometryReader { proxy in
                            let y = Self.height - CGFloat(fraction) * Self.height
                            Path { path in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y)) }
                                .stroke(PacerPalette.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }.frame(height: Self.height).allowsHitTesting(false)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(Array(value.days.enumerated()), id: \.offset) { _, day in
                        Text(day.label).font(.system(size: 9, weight: day.today ? .semibold : .regular))
                            .foregroundStyle(day.today ? PacerPalette.primary : PacerPalette.tertiary).frame(maxWidth: .infinity)
                    }
                }
            }.accessibilityElement(children: .ignore).accessibilityLabel(value.accessibilityLabel)
        }
    }
    private func bar(_ day: DeepSeekSoloPresentation.Day) -> some View {
        let within = CGFloat(day.withinFraction) * Self.height, over = CGFloat(day.overFraction) * Self.height
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            if over >= 0.5 { RoundedRectangle(cornerRadius: 2).fill(PacerPalette.danger.opacity(day.today ? 0.95 : 0.6)).frame(height: over) }
            if within >= 0.5 { RoundedRectangle(cornerRadius: 2).fill(AgentProvider.deepseek.tint.opacity(day.today ? 1 : 0.5)).frame(height: within) }
        }.frame(width: 22, height: Self.height).frame(maxWidth: .infinity).contentShape(Rectangle()).accessibilityHint(day.help)
    }
}

/// Beside the section title: the balance and runway under the budget dial,
/// and how fresh the reading is.
struct DeepSeekSectionStatus: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wallet = model.deepseekWallet
        HStack(spacing: 4) {
            if model.deepseekShowsBudgetDial, let balance = wallet.balance {
                Text(L10n.text("deepseek.header_balance", DeepSeekDayDial.amount(balance.total))).foregroundStyle(PacerPalette.secondary)
                if let days = wallet.runwayDays, days < 365 {
                    Text("· " + L10n.text("deepseek.runway_short", max(1, Int(days.rounded(.down))))).foregroundStyle(PacerPalette.secondary)
                }
                Text("·").foregroundStyle(PacerPalette.tertiary)
            }
            if wallet.balance != nil { Text(model.deepseekBalanceFreshness).foregroundStyle(PacerPalette.tertiary) }
        }
        .font(.system(size: 10.5)).monospacedDigit().lineLimit(1)
    }
}
