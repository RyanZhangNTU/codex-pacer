import Foundation

/// Both display styles are projected together. Choosing a style never changes
/// the quota source, RPC scheduling, account binding or collapsed selection.
struct EngineQuotaDashboard: Codable, Equatable {
    struct Provider: Codable, Equatable {
        let provider: AgentProvider
        let fiveHour: QuotaDashboardPresentation.Reading
        let weekly: QuotaDashboardPresentation.Reading
        let status: QuotaConnectionPresentation?
        let history: QuotaHistoryPresentation?
    }
    let schemaVersion: Int
    let split: QuotaDashboardPresentation.Layout
    let classic: QuotaDashboardPresentation.Layout
    let providers: [Provider]
    let legacyCodex: QuotaDashboardPresentation.Legacy?

    init(enabled: Set<AgentProvider>, snapshots: [AgentProvider: QuotaSnapshot], failed: Set<AgentProvider> = [],
         refreshing: Set<AgentProvider> = [], sourceText: [AgentProvider: String] = [:], errorText: [AgentProvider: String] = [:],
         history: [AgentProvider: QuotaHistoryPresentation] = [:], at now: Date) {
        schemaVersion = 1
        let ordered = AgentProvider.allCases.filter { enabled.contains($0) }
        split = QuotaDashboardPresentation.layout(providers: ordered, snapshots: snapshots, style: .split, now: now)
        classic = QuotaDashboardPresentation.layout(providers: ordered, snapshots: snapshots, style: .classic, now: now)
        if (split.kind == .legacyCodex || classic.kind == .legacyCodex), let snapshot = snapshots[.codex] {
            legacyCodex = .init(snapshot: snapshot, failed: failed.contains(.codex), now: now)
        } else { legacyCodex = nil }
        providers = ordered.map { provider in
            func reading(_ period: QuotaDashboardPresentation.Period) -> QuotaDashboardPresentation.Reading {
                .init(provider: provider, period: period, snapshot: snapshots[provider], failed: failed.contains(provider),
                    refreshing: refreshing.contains(provider), sourceText: sourceText[provider], now: now)
            }
            return Provider(provider: provider, fiveHour: reading(.fiveHour), weekly: reading(.weekly),
                status: provider == .deepseek ? nil : QuotaConnectionPresentation(provider: provider,
                    snapshot: snapshots[provider], error: errorText[provider], refreshing: refreshing.contains(provider)), history: history[provider])
        }
    }
}
