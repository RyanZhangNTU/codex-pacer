import Foundation
import PacerCore

/// Formatting hundreds of dates belongs to data changes, not each presentation
/// clock tick. Source/account tokens let the host close an old account's details.
struct EngineQuotaHistory {
    private var sourceHome: URL?
    private var sourcePath = ""
    private var scope: String?
    private var history = QuotaCycleHistory()
    private var warning: String?
    private(set) var accountContext = UUID().uuidString
    struct GroupWeek: Codable, Equatable {
        let id: String, title: String, remaining: String
        let chart: QuotaCycleChartPresentation?
    }
    private var groupCharts: [String: (QuotaChartData, String, QuotaCycleChartPresentation)] = [:]
    mutating func groupWeeks(provider: AgentProvider, snapshot: QuotaSnapshot, at now: Date) -> [GroupWeek] {
        guard let groups = provider.quotaGroups else { return [] }
        let context = [L10n.language.rawValue, L10n.locale.identifier, L10n.timeZone.identifier].joined(separator: "|")
        return snapshot.buckets.map { bucket in
            let week = bucket.windows.first { $0.durationMinutes == 10080 }
            if let scope = snapshot.accountScope, history.accountScope == scope, let cycle = history.currentCycle(for: week, at: now) {
                let data = QuotaChartData(cycle: cycle, resetCredits: snapshot.resetCredits, now: now)
                if groupCharts[bucket.id]?.0 != data || groupCharts[bucket.id]?.1 != context {
                    groupCharts[bucket.id] = (data, context, QuotaCycleChartPresentation(data: data))
                }
            } else { groupCharts[bucket.id] = nil }
            return GroupWeek(id: bucket.id, title: groups.name(bucket.id),
                remaining: week?.remainingPercent.map { L10n.text("harness.weekly_remaining", Int($0.rounded())) } ?? "—",
                chart: groupCharts[bucket.id]?.2)
        }
    }

    private var chartData: QuotaChartData?
    private var chart: QuotaCycleChartPresentation?
    private var formattingContext = ""
    private(set) var chartRevision = 0

    mutating func bind(home: URL, customPath: String) {
        guard sourceHome != home || sourcePath != customPath else { return }
        sourceHome = home; sourcePath = customPath; scope = nil
        accountContext = UUID().uuidString; history = .init(); warning = nil
        chartData = nil; chart = nil; groupCharts.removeAll()
    }
    mutating func receive(snapshot: QuotaSnapshot?, history: QuotaCycleHistory, warning: String?) {
        if scope != snapshot?.accountScope { scope = snapshot?.accountScope; accountContext = UUID().uuidString }
        self.history = history; self.warning = warning
    }
    mutating func prune(at date: Date) { history.prune(at: date) }
    mutating func presentation(provider: AgentProvider, snapshot: QuotaSnapshot?, weekly: QuotaDashboardPresentation.Reading,
                               error: String?, refreshing: Bool, now: Date) -> QuotaHistoryPresentation {
        let window = snapshot?.windows.first { $0.id == weekly.windowID }
        let cycle = snapshot?.accountScope != nil && history.accountScope == snapshot?.accountScope
            ? history.currentCycle(for: window, at: now) : nil
        let data = cycle.map { QuotaChartData(cycle: $0, resetCredits: snapshot?.resetCredits, now: now) }
        let context = [L10n.language.rawValue, L10n.locale.identifier, L10n.timeZone.identifier].joined(separator: "|")
        if data != chartData || context != formattingContext {
            chartData = data; formattingContext = context
            chart = data.map { QuotaCycleChartPresentation(data: $0) }; chartRevision += 1
        }
        return .init(provider: provider, snapshot: snapshot, weekly: weekly, chart: chart,
            error: error, warning: warning, refreshing: refreshing, accountContext: accountContext, now: now)
    }
}
