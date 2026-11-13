import Foundation
import PacerCore

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
        let ordered = HarnessRegistry.descriptors.filter { $0.hasQuotaDisplay && enabled.contains($0.id) }.map(\.id)
        let displayed = HarnessRegistry.descriptors.filter { ($0.hasQuotaDisplay || $0.reportsAccountCredits) && enabled.contains($0.id) }.map(\.id)
        split = QuotaDashboardPresentation.layout(providers: displayed, snapshots: snapshots, style: .split, now: now)
        classic = QuotaDashboardPresentation.layout(providers: displayed, snapshots: snapshots, style: .classic, now: now)
        // The panel can give Codex a section of its own, so its bars are ready
        // whenever Codex alone would draw them.
        if enabled.contains(.codex), let snapshot = snapshots[.codex],
           QuotaDashboardPresentation.Style.allCases.contains(where: {
               QuotaDashboardPresentation.usesLegacyCodexDisplay(providers: [.codex], snapshot: snapshot, style: $0)
           }) {
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
