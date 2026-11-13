import Foundation
import PacerCore

/// The expanded panel's saved blocks and choices, as the Mac stores them.
/// Omitting the group in `configure` keeps the current one.
struct EngineExpandedPanelSettings: Codable, Equatable, Sendable {
    var layout: String?
    var options: String?
    /// DeepSeek's former Content choice; Detailed adds its charts to the automatic layout.
    var deepseekDetailed: Bool?

    var isValid: Bool {
        (layout.map { $0.utf8.count <= ExpandedPanelLayout.byteLimit } ?? true)
            && (options.map { $0.utf8.count <= ExpandedPanelOptions.byteLimit } ?? true)
    }
    var choices: ExpandedPanelOptions { ExpandedPanelOptions.decode(options) }
    func resolvedLayout(providers: Set<AgentProvider>) -> ExpandedPanelLayout {
        ExpandedPanelLayout.resolved(saved: ExpandedPanelLayout.decode(layout), providers: providers, deepseekDetailed: deepseekDetailed ?? true)
    }
}

/// The panel's sections with each quota section's drawing in both styles,
/// so changing the style needs no new snapshot.
struct EngineExpandedPanel: Codable, Equatable {
    struct Section: Codable, Equatable {
        let kind: String
        let providers: [AgentProvider]
        let actions: Bool
        let joined: Bool
        let spendBeside: Bool
        let showsHeader: Bool
        let title: String
        let detail: String?
        let split: QuotaDashboardPresentation.Layout?
        let classic: QuotaDashboardPresentation.Layout?
    }
    let schemaVersion: Int
    let options: ExpandedPanelOptions
    /// DeepSeek's dial shows the budgets.
    let budgetDial: Bool
    let sections: [Section]
    /// The window each enabled quota service's ring draws, in the panel and on Overview.
    let gauges: [ExpandedPanelPresentation.Gauge]

    init(settings: EngineExpandedPanelSettings, enabled: Set<AgentProvider>, snapshots: [AgentProvider: QuotaSnapshot],
         hasBudget: Bool, at now: Date) {
        schemaVersion = 1
        let options = settings.choices
        self.options = options
        budgetDial = options.showsBudgetDial(hasBudget: hasBudget)
        let budgetDial = budgetDial
        sections = ExpandedPanelPresentation.sections(layout: settings.resolvedLayout(providers: enabled), providers: enabled,
            options: options, budgetDial: budgetDial).map { section in
            let header = ExpandedPanelPresentation.header(section, budgetDial: budgetDial)
            let quota = section.kind == .quota
            func layout(_ style: QuotaDashboardPresentation.Style) -> QuotaDashboardPresentation.Layout? {
                quota ? QuotaDashboardPresentation.layout(providers: section.providers, snapshots: snapshots, style: style, now: now,
                    preservingOrder: true, details: options.quotaDetails, periods: options.periods(for:)) : nil
            }
            return Section(kind: section.kind.rawValue, providers: section.providers, actions: section.actions, joined: section.joined,
                spendBeside: section.spendBeside, showsHeader: section.showsHeader, title: header.title, detail: header.detail,
                split: layout(.split), classic: layout(.classic))
        }
        gauges = HarnessRegistry.legacyIDs.filter { enabled.contains($0) && $0 != .deepseek }.map {
            ExpandedPanelPresentation.gauge(provider: $0, snapshot: snapshots[$0], periods: options.periods(for: $0))
        }
    }
}
