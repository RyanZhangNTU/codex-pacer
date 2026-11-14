import Foundation

/// A module's last seven days of account credits, drawn with the same week
/// chart as DeepSeek's spend: one bar a day, today last, a daily-average line.
public enum HarnessWeekPresentation {
    /// Nil until two finished days have credits, like DeepSeek's week.
    public static func week(provider: AgentProvider, daily: [HarnessDailyAmount], now: Date,
                            calendar: Calendar = .current) -> DeepSeekSoloPresentation.Week? {
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        guard days.count == 7 else { return nil }
        let totals = days.map { day in daily.filter { calendar.isDate($0.day, inSameDayAs: day) }.reduce(0) { $0 + max(0, $1.amount) } }
        guard totals.dropLast().filter({ $0 >= 0.005 }).count >= 2 else { return nil }
        func amount(_ value: Double) -> String { HarnessAccountCredits.compactAmount(value) }
        let used = totals.filter { $0 >= 0.005 }
        let average = used.isEmpty ? nil : used.reduce(0, +) / Double(used.count)
        let top = max(0.01, totals.max() ?? 0, (average ?? 0) * 1.15)
        let bars = zip(days, totals).enumerated().map { index, pair -> DeepSeekSoloPresentation.Day in
            let (day, total) = pair, isToday = index == days.count - 1
            let help = day.formatted(Date.FormatStyle().weekday(.abbreviated).month(.defaultDigits).day().locale(L10n.locale))
                + " · " + L10n.text("harness.credits_amount", amount(total))
            return .init(timestamp: day.timeIntervalSince1970,
                label: isToday ? L10n.text("deepseek.today_label") : day.formatted(Date.FormatStyle().weekday(.narrow).locale(L10n.locale)),
                today: isToday, withinFraction: total / top, overFraction: 0, help: help)
        }
        // The card above names the module; the chart's own title matches DeepSeek's.
        return .init(title: L10n.text("deepseek.week_title"),
            lineText: average.map { L10n.text("harness.daily_average", amount($0)) }, lineFraction: average.map { $0 / top }, days: bars,
            accessibilityLabel: L10n.text("harness.week_accessibility_total", provider.displayName, amount(totals.reduce(0, +))))
    }
}
