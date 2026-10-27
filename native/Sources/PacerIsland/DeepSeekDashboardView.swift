import PacerCore
import SwiftUI

/// DeepSeek's ring is a day on a 24-hour face rather than a share of a quota
/// window: one segment per local hour, thicker for the hours that cost more,
/// an amber bezel over the doubled-price hours and the white tick for now.
/// The balance sits in the middle with today's spend under it.
struct DeepSeekDayDial: View {
    @ObservedObject var model: IslandModel
    let wallet: DeepSeekWallet
    let size: CGFloat

    private var scale: CGFloat { size / 108 }
    private var connectTitle: String? {
        guard wallet.balance == nil, !model.deepseekRefreshing,
              model.deepseekConnectionNeeded || model.deepseekBalanceMode == nil else { return nil }
        return L10n.text(model.deepseekBalanceMode == .apiKey ? "deepseek.paste_key_short" : "deepseek.sign_in")
    }

    var body: some View {
        ZStack {
            DeepSeekDialFace(hourly: wallet.hourly, peak: wallet.peakToday.map { angle(of: $0.start)...angle(of: $0.end) },
                now: angle(of: model.now), color: segmentColor)
                .opacity(wallet.state == .stale && wallet.balance != nil ? 0.55 : 1)
            centre
        }
        .frame(width: size, height: size)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var centre: some View {
        if let balance = wallet.balance {
            VStack(spacing: 2 * scale) {
                let parts = String(format: "%.2f", max(0, balance.total)).split(separator: ".")
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("¥").font(.system(size: 10 * scale, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                    Text(String(parts.first ?? "0")).font(.system(size: 21 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(wallet.state == .normal ? PacerPalette.primary : DeepSeekWalletColors.balance(wallet.state))
                    Text("." + String(parts.last ?? "00")).font(.system(size: 9 * scale, weight: .semibold, design: .rounded))
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

    private var todayText: String { L10n.text("deepseek.today", Self.amount(wallet.today)) }
    private var subtitle: String {
        switch wallet.state {
        case .exhausted: L10n.text("deepseek.wallet.exhausted")
        case .stale: model.deepseekBalanceFreshness
        default: todayText
        }
    }
    private var subtitleColor: Color {
        switch wallet.state {
        case .exhausted: PacerPalette.danger
        case .stale: PacerPalette.tertiary
        default: wallet.spendingFast ? PacerPalette.attention : PacerPalette.secondary
        }
    }
    private var segmentColor: Color {
        switch wallet.state {
        case .stale where wallet.balance != nil: Color(white: 0.36)
        case .exhausted: PacerPalette.danger
        default: AgentProvider.deepseek.tint
        }
    }

    /// Degrees clockwise from midnight at the top, through the local day.
    private func angle(of date: Date) -> Double {
        let day = wallet.day
        guard day.duration > 0 else { return 0 }
        return min(360, max(0, date.timeIntervalSince(day.start) / day.duration * 360))
    }
    private var help: String {
        var lines = [L10n.text("deepseek.dial_help")]
        if !wallet.peakToday.isEmpty { lines.append(L10n.text("deepseek.peak_hours_help")) }
        lines.append(L10n.text("deepseek.estimate_help"))
        if wallet.balance != nil { lines.append(model.deepseekBalanceFreshness) }
        return lines.joined(separator: "\n")
    }
    private var accessibilityLabel: String {
        let balance = wallet.balance.map { Self.amount($0.total) } ?? L10n.text("common.unknown")
        return L10n.text("deepseek.dial_accessibility", balance, Self.amount(wallet.today),
            L10n.text(wallet.peakNow ? "deepseek.now.peak" : "deepseek.now.offpeak"))
    }

    /// Two decimals in the details: `¥3.12`, `¥86.40`, `¥1.2k` from a thousand.
    static func amount(_ value: Double) -> String {
        value < 1000 ? String(format: "¥%.2f", max(0, value)) : DeepSeekWallet.compactAmount(value)
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
        context.stroke(tick, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: max(1.2, 2.4 * k), lineCap: .round))
        context.stroke(tick, with: .color(.white), style: StrokeStyle(lineWidth: max(1, 1.7 * k), lineCap: .round))
    }
    private func arc(_ centre: CGPoint, _ radius: CGFloat, _ start: Double, _ end: Double) -> Path {
        Path { $0.addArc(center: centre, radius: radius, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false) }
    }
}

/// The dial in a row of providers, named like the other rings.
struct DeepSeekDialCell: View {
    @ObservedObject var model: IslandModel
    let size: CGFloat

    var body: some View {
        let wallet = model.deepseekWallet
        VStack(spacing: 6) {
            VStack(spacing: 8) {
                DeepSeekDayDial(model: model, wallet: wallet, size: size)
                HStack(spacing: 5) {
                    Text(AgentProvider.deepseek.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.primary)
                    DeepSeekWalletChip(wallet: wallet)
                }.frame(height: 15)
            }
            DeepSeekBalanceStatusView(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// "Peak" while prices are doubled; a short runway replaces it.
struct DeepSeekWalletChip: View {
    let wallet: DeepSeekWallet

    var body: some View {
        if wallet.state == .stale, wallet.balance != nil {
            Image(systemName: StatusSymbols.freshness).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PacerPalette.attention).accessibilityLabel(L10n.text("common.not_updated"))
        } else if wallet.state == .low, let days = wallet.runwayDays, days < 3 {
            chip(L10n.text("deepseek.runway_short", max(1, Int(days.rounded(.up)))))
        } else if wallet.peakNow {
            chip(L10n.text("deepseek.peak_chip"))
        }
    }
    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(PacerPalette.attention)
            .padding(.horizontal, 5).frame(height: 15)
            .background(PacerPalette.attention.opacity(0.14), in: Capsule())
    }
}

/// Recovery under the dial. A missing sign-in or key is offered in the dial.
struct DeepSeekBalanceStatusView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let error = model.deepseekBalanceError {
            VStack(spacing: 6) {
                Text(error.errorDescription ?? "").font(.system(size: 11))
                    .foregroundStyle(error.needsConnection ? PacerPalette.secondary : PacerPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                if !error.needsConnection {
                    HStack(spacing: 6) {
                        QuotaLinkButton(title: L10n.text(model.deepseekRefreshing ? "common.retrying" : "common.retry")) {
                            model.refreshDeepSeekBalance(force: true)
                        }.disabled(model.deepseekRefreshing)
                        QuotaLinkButton(title: L10n.text("common.settings")) { model.openSettings(for: .deepseek) }
                    }
                }
            }.multilineTextAlignment(.center)
        }
    }
}

/// DeepSeek alone: the dial, then now, today and balance beside it like the
/// 5h and 7d groups, and the week's spend split by price below.
struct DeepSeekSoloDashboard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wallet = model.deepseekWallet
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                DeepSeekDayDial(model: model, wallet: wallet, size: 132)
                VStack(alignment: .leading, spacing: 9) {
                    nowGroup(wallet)
                    todayGroup(wallet)
                    balanceGroup(wallet)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DeepSeekWeekChart(wallet: wallet, now: model.now)
            DeepSeekBalanceStatusView(model: model)
        }
        .padding(.horizontal, IslandMetrics.rowInset).padding(.bottom, 4)
    }

    private func nowGroup(_ wallet: DeepSeekWallet) -> some View {
        // A countdown only for a change later today; a later day names its moment alone.
        let change = wallet.nextPriceChange.map { change in
            let moment = L10n.moment(change, relativeTo: model.now)
            guard Calendar.current.isDate(change, inSameDayAs: model.now) else {
                return L10n.text(wallet.peakNow ? "deepseek.now.offpeak_at" : "deepseek.now.peak_at", moment)
            }
            return L10n.text(wallet.peakNow ? "deepseek.now.offpeak_from" : "deepseek.now.peak_from",
                moment, CompactDuration.text(change.timeIntervalSince(model.now)))
        }
        return group(L10n.text("deepseek.group.now"), details: change.map { [$0] } ?? []) {
            Text(L10n.text(wallet.peakNow ? "deepseek.now.peak" : "deepseek.now.offpeak"))
                .foregroundStyle(wallet.peakNow ? PacerPalette.attention : PacerPalette.primary)
        }
        .help(L10n.text("deepseek.peak_hours_help"))
    }

    private func todayGroup(_ wallet: DeepSeekWallet) -> some View {
        var details = [L10n.text("deepseek.today.no_history")]
        if let typical = wallet.typicalByNow {
            details = [L10n.text("deepseek.today.typical", DeepSeekDayDial.amount(typical))]
            if wallet.spendingFast, typical > 0 {
                details.append(L10n.text("deepseek.today.faster", String(format: "%.1f", wallet.today / typical)))
            }
        }
        return group(L10n.text("deepseek.group.today"), details: details) {
            Text(DeepSeekDayDial.amount(wallet.today)).foregroundStyle(PacerPalette.primary)
            if wallet.spendingFast { QuotaVerdictChip(verdict: .fast) }
        }
        .help(L10n.text("deepseek.estimate_help"))
    }

    private func balanceGroup(_ wallet: DeepSeekWallet) -> some View {
        var details: [String] = []
        if let average = wallet.averageDaily, average >= 0.005 { details.append(L10n.text("deepseek.daily_average", DeepSeekDayDial.amount(average))) }
        if let tokens = wallet.balance?.tokenEstimation, tokens > 0 {
            details.append(L10n.text("deepseek.token_estimate", tokens.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(L10n.locale))))
        }
        return group(L10n.text("deepseek.group.balance"), details: details) {
            Text(runwayText(wallet)).foregroundStyle(wallet.state == .normal ? PacerPalette.primary : DeepSeekWalletColors.balance(wallet.state))
        }
        .help(L10n.text("deepseek.runway_help"))
    }
    private func runwayText(_ wallet: DeepSeekWallet) -> String {
        guard let balance = wallet.balance else {
            return L10n.text(model.deepseekRefreshing ? "deepseek.reading" : "deepseek.not_connected")
        }
        if wallet.state == .exhausted { return L10n.text("deepseek.wallet.exhausted") }
        guard let days = wallet.runwayDays else { return DeepSeekDayDial.amount(balance.total) }
        return days >= 365 ? L10n.text("deepseek.runway_year") : L10n.text("deepseek.runway_days", max(1, Int(days.rounded(.down))))
    }

    /// The widest group label in the current language, so every value starts at one column.
    private static let labelWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        return ["deepseek.group.now", "deepseek.group.today", "deepseek.group.balance"]
            .map { ceil((L10n.text($0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 30
    }()

    /// Several details wrap only between pieces, never inside one.
    private func detailText(_ details: [String]) -> String? {
        guard details.count > 1 else { return details.first }
        return details.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
    }

    private func group<Value: View>(_ key: String, details: [String], @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(.system(size: 10, weight: .semibold)).foregroundStyle(PacerPalette.tertiary).lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { value() }.font(.system(size: 13, weight: .semibold, design: .rounded))
                if let detail = detailText(details) {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(PacerPalette.secondary).lineLimit(2).minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// One bar a day for the last week: off-peak spend in blue, the doubled-price
/// part above it in amber, the dashed line at the daily average.
struct DeepSeekWeekChart: View {
    let wallet: DeepSeekWallet
    let now: Date
    private static let height: CGFloat = 70

    var body: some View {
        let days = wallet.days
        let peak = days.reduce(0) { $0 + $1.peak }
        VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in draw(in: &context, size: size, days: days) }
                .frame(height: Self.height)
                .accessibilityLabel(L10n.text("deepseek.week_accessibility", DeepSeekDayDial.amount(days.reduce(0) { $0 + $1.total }),
                    DeepSeekDayDial.amount(peak)))
            HStack(spacing: 12) {
                legend(AgentProvider.deepseek.tint, L10n.text("deepseek.offpeak_hours"))
                legend(PacerPalette.attention, L10n.text("deepseek.peak_hours"))
                if peak >= 0.01 {
                    Text(L10n.text("deepseek.week_saving", DeepSeekDayDial.amount(peak), DeepSeekDayDial.amount(peak / 2)))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .font(.system(size: 10)).foregroundStyle(PacerPalette.secondary).monospacedDigit()
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, days: [DeepSeekSpendLedger.Day]) {
        guard !days.isEmpty else { return }
        let average = wallet.averageDaily ?? 0
        // The average's label sits left of its line in a margin measured for this language.
        let averageLabel = L10n.text("deepseek.daily_average", DeepSeekDayDial.amount(average))
        let left: CGFloat = average >= 0.005
            ? ceil((averageLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)]).width) + 10 : 4
        let base = size.height - 14, top: CGFloat = 6
        let largest = max(0.01, days.map(\.total).max() ?? 0, average)
        let scale = (base - top) / CGFloat(largest)
        let step = (size.width - left - 4) / CGFloat(days.count), width = min(28, step * 0.62)
        var axis = Path(); axis.move(to: CGPoint(x: left, y: base)); axis.addLine(to: CGPoint(x: size.width - 4, y: base))
        context.stroke(axis, with: .color(PacerPalette.hairline), lineWidth: 1)
        for (index, day) in days.enumerated() {
            let today = index == days.count - 1
            let x = left + CGFloat(index) * step + (step - width) / 2
            let offPeak = CGFloat(max(0, day.total - day.peak)) * scale, peak = CGFloat(max(0, day.peak)) * scale
            if offPeak >= 0.5 {
                context.fill(Path(roundedRect: CGRect(x: x, y: base - offPeak, width: width, height: offPeak), cornerRadius: 2),
                    with: .color(AgentProvider.deepseek.tint.opacity(today ? 1 : 0.55)))
            }
            if peak >= 0.5 {
                context.fill(Path(roundedRect: CGRect(x: x, y: base - offPeak - peak, width: width, height: peak), cornerRadius: 2),
                    with: .color(PacerPalette.attention.opacity(today ? 0.95 : 0.5)))
            }
            let label = today ? L10n.text("deepseek.today_label")
                : day.start.formatted(Date.FormatStyle().weekday(.narrow).locale(L10n.locale))
            context.draw(Text(label).font(.system(size: 9, weight: today ? .semibold : .regular))
                .foregroundStyle(today ? PacerPalette.primary : PacerPalette.tertiary),
                at: CGPoint(x: x + width / 2, y: base + 8), anchor: .center)
        }
        guard average >= 0.005 else { return }
        let y = base - CGFloat(average) * scale
        var line = Path(); line.move(to: CGPoint(x: left, y: y)); line.addLine(to: CGPoint(x: size.width - 4, y: y))
        context.stroke(line, with: .color(PacerPalette.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        context.draw(Text(averageLabel).font(.system(size: 9))
            .foregroundStyle(PacerPalette.tertiary), at: CGPoint(x: left - 6, y: y), anchor: .trailing)
    }
}
